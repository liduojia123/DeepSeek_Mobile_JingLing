import type { ChatDelta } from './events.js';

export interface MockStreamParams {
  messages: ReadonlyArray<{ role: string; content: unknown }>;
  signal: AbortSignal;
  delayMs: number;
  /** M5:启用客户端工具时,MOCK 也要能演示 memory 工具调用 */
  toolsEnabled?: boolean;
}

const sleep = (ms: number, signal: AbortSignal): Promise<void> =>
  new Promise((resolve, reject) => {
    if (ms <= 0) {
      if (signal.aborted) reject(new DOMException('aborted', 'AbortError'));
      else resolve();
      return;
    }
    const timer = setTimeout(() => {
      signal.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    const onAbort = (): void => {
      clearTimeout(timer);
      reject(new DOMException('aborted', 'AbortError'));
    };
    signal.addEventListener('abort', onAbort, { once: true });
  });

const chunkText = (text: string, size: number): string[] => {
  const out: string[] = [];
  for (let i = 0; i < text.length; i += size) out.push(text.slice(i, i + size));
  return out;
};

const estimateTokens = (text: string): number => Math.max(1, Math.ceil(text.length / 2));

const textOf = (content: unknown): string => (typeof content === 'string' ? content : JSON.stringify(content));

/**
 * MOCK=1 的等价假流:事件序列与真实流一致(思考 → 工具调用 → 正文 → 引用 → 标题 → usage)。
 * M2 起额外伪造一次搜索结果或读链接结果,让无 key 的前端联调也能看到过程卡片与引用。
 */
export async function* mockStream(params: MockStreamParams): AsyncGenerator<ChatDelta> {
  // M5:MOCK 下演示客户端工具循环(记住/查记忆/列记忆 → 本地执行 → 再回答)
  const hasToolResult = params.messages.some((message) => message.role === 'tool');
  if (params.toolsEnabled === true && !hasToolResult) {
    const userText = textOf(
      [...params.messages].reverse().find((message) => message.role === 'user')?.content,
    ).trim();
    const saveMatch = /^记住[:：]\s*(.+)$/.exec(userText);
    const searchMatch = /^查记忆[:：]\s*(.+)$/.exec(userText);
    let toolName: string | null = null;
    let toolArgs = '';
    if (saveMatch) {
      toolName = 'memory_save';
      toolArgs = JSON.stringify({ content: saveMatch[1].trim() });
    } else if (searchMatch) {
      toolName = 'memory_search';
      toolArgs = JSON.stringify({ query: searchMatch[1].trim() });
    } else if (userText === '列记忆') {
      toolName = 'memory_list';
      toolArgs = JSON.stringify({});
    }
    if (toolName !== null) {
      await sleep(params.delayMs, params.signal);
      yield { thinking: '需要调用记忆工具。' };
      await sleep(params.delayMs, params.signal);
      const callId = 'call_mock_1';
      const pieces = toolArgs.match(/.{1,12}/gs) ?? [toolArgs];
      yield { functionToolCalls: [{ index: 0, id: callId, name: toolName, argumentsDelta: '' }] };
      for (const piece of pieces) {
        await sleep(params.delayMs, params.signal);
        yield { functionToolCalls: [{ index: 0, argumentsDelta: piece }] };
      }
      await sleep(params.delayMs, params.signal);
      yield { usage: { tokens_in: 40, tokens_out: 8, tokens_cached: 0, search_calls: 0, fetch_calls: 0 } };
      return;
    }
  }
  const lastUserMessage = [...params.messages].reverse().find((m) => m.role === 'user');
  const lastUser = textOf(lastUserMessage?.content).trim() || '(空)';
  const quoted = lastUser.length > 60 ? `${lastUser.slice(0, 60)}…` : lastUser;
  const urlMatch = /https?:\/\/\S+/.exec(lastUser);

  const thinking = [
    '先理解用户的问题…',
    `目标:围绕「${quoted}」给出可执行回答。`,
    urlMatch ? '检测到用户给了链接,先读网页。' : '判断是否需要联网:这次用一次搜索演示过程卡片。',
    '组织回答结构…',
  ];
  const answer = [
    '这是**鲸灵 MOCK 模式**的回答。',
    `\n\n你刚才说:「${quoted}」。`,
    '\n\n- 未调用真实 DeepSeek API',
    '\n- 事件序列与真实流一致(thinking → tool → text → citation → title → usage)',
    '\n\n> 填入 `DEEPSEEK_API_KEY` 并设 `MOCK=0` 即可切到真实模型。',
  ].join('');

  for (const piece of thinking) {
    await sleep(params.delayMs, params.signal);
    yield { thinking: piece };
  }

  // 伪工具调用:有 URL 就演示读链接,否则演示一次搜索
  const sources = urlMatch
    ? [{ url: urlMatch[0], title: 'MOCK:用户给的链接', snippet: '假流返回的占位摘要。' }]
    : [
        { url: 'https://example.com/mock-1', title: 'MOCK 搜索结果一', site_name: 'example.com', snippet: '这是假流生成的第一条结果。' },
        { url: 'https://example.com/mock-2', title: 'MOCK 搜索结果二', site_name: 'example.com', snippet: '这是假流生成的第二条结果。' },
      ];
  yield {
    toolCalls: [
      {
        index: 0,
        reasoning_content: '用一次工具调用来演示过程卡片',
        calls: [
          {
            id: 'mock-tool-1',
            type: urlMatch ? 'deepseek_read_url' : 'deepseek_web_search',
            kind: urlMatch ? 'read_link' : 'search',
            action: urlMatch
              ? { type: 'read_link', url: urlMatch[0] }
              : { type: 'search', queries: [quoted.slice(0, 20), 'MOCK 查询二'] },
            status: 'completed',
            sources,
          },
        ],
      },
    ],
  };
  await sleep(params.delayMs, params.signal);

  // 正文按 ~24 字符切片,模拟逐 token 到达
  for (const piece of chunkText(answer, 24)) {
    await sleep(params.delayMs, params.signal);
    yield { text: piece };
  }

  // 引用与标题:客户端据此渲染角标与自动标题
  await sleep(params.delayMs, params.signal);
  yield {
    annotations: [{ url: sources[0]!.url, title: sources[0]!.title, start_index: 0, end_index: 12 }],
  };
  await sleep(params.delayMs, params.signal);
  yield { title: `MOCK:${quoted.slice(0, 14)}` };

  yield {
    usage: {
      tokens_in: estimateTokens(params.messages.map((m) => textOf(m.content)).join('\n')),
      tokens_out: estimateTokens(answer),
      tokens_cached: 0,
      search_calls: urlMatch ? 0 : 2,
      fetch_calls: urlMatch ? 1 : 0,
    },
    finishReason: 'stop',
  };
}
