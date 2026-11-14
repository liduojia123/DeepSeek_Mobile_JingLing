import type { ChatDelta } from './events.js';

export interface MockStreamParams {
  messages: ReadonlyArray<{ role: string; content: string }>;
  signal: AbortSignal;
  delayMs: number;
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

/**
 * MOCK=1 的等价假流:事件序列与真实流一致(思考增量 → 正文增量 → usage),
 * 让无 key 的开发与测试走通完整链路。
 */
export async function* mockStream(params: MockStreamParams): AsyncGenerator<ChatDelta> {
  const lastUser =
    [...params.messages].reverse().find((m) => m.role === 'user')?.content.trim() ?? '(空)';
  const quoted = lastUser.length > 60 ? `${lastUser.slice(0, 60)}…` : lastUser;

  const thinking = [
    '先理解用户的问题…',
    `目标:围绕「${quoted}」给出可执行回答。`,
    '检查是否需要联网/工具 —— MOCK 模式不调用任何外部能力。',
    '组织回答结构…',
  ];
  const answer = [
    '这是**鲸灵 MOCK 模式**的回答。',
    `\n\n你刚才说:「${quoted}」。`,
    '\n\n- 未调用真实 DeepSeek API',
    '\n- 事件序列与真实流一致(thinking → text → usage)',
    '\n\n> 填入 `DEEPSEEK_API_KEY` 并设 `MOCK=0` 即可切到真实模型。',
  ].join('');

  for (const piece of thinking) {
    await sleep(params.delayMs, params.signal);
    yield { thinking: piece };
  }

  // 正文按 ~24 字符切片,模拟逐 token 到达
  for (const piece of chunkText(answer, 24)) {
    await sleep(params.delayMs, params.signal);
    yield { text: piece };
  }

  yield {
    usage: {
      tokens_in: estimateTokens(params.messages.map((m) => m.content).join('\n')),
      tokens_out: estimateTokens(answer),
    },
    finishReason: 'stop',
  };
}
