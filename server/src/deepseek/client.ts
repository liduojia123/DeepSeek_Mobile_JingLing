import type { Config } from '../config.js';
import { normalizeDeepSeekChunk, type ChatDelta } from './events.js';

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  /** 纯文本、富内容数组(文件引用),或 tool 消息的字符串结果 */
  content: string | Array<Record<string, unknown>>;
  /** M2:上一轮 assistant 的 server_tool_calls 块原样回传,阅读链接的网页才会拼回上下文 */
  server_tool_calls?: unknown[];
  /** M5:客户端工具调用声明(assistant 消息) */
  tool_calls?: Array<{ id: string; type: 'function'; function: { name: string; arguments: string } }>;
  /** M5:tool 消息对应的调用 id */
  tool_call_id?: string;
}

export class UpstreamError extends Error {
  constructor(
    public readonly statusCode: number,
    /** 上游响应体原文。可能回显用户内容,只用于排障,不要写进日志。 */
    public readonly detail: string,
  ) {
    super(`DeepSeek 上游返回 HTTP ${statusCode}`);
    this.name = 'UpstreamError';
  }
}

export interface StreamChatParams {
  config: Config;
  messages: ChatMessage[];
  signal: AbortSignal;
  /** 本次请求是否启用服务端联网工具(默认跟随配置) */
  search?: boolean;
  /** 本次请求是否启用思考(默认启用) */
  thinking?: boolean;
  /** 客户端工具(OpenAI function 格式);为空则不声明 */
  tools?: Array<Record<string, unknown>>;
  /** v1.5.3:用户个人 key(设置页录入);缺省用 config 的默认 key */
  apiKey?: string;
}

/**
 * 调 DeepSeek Chat Completions(stream=true),把原生 SSE 增量归一化成 ChatDelta。
 * 参考:api-docs.deepseek.com/zh-cn/guides/build_a_chatbot
 */
export async function* streamChatCompletion(params: StreamChatParams): AsyncGenerator<ChatDelta> {
  const { config, messages, signal } = params;
  const searchOn = params.search !== false;
  const thinkingOn = params.thinking !== false;
  const url = `${config.deepseekBaseUrl.replace(/\/+$/, '')}/chat/completions`;

  const body: Record<string, unknown> = {
    model: config.model,
    messages,
    stream: true,
    stream_options: { include_usage: true },
    // 思考开启时显式 thinking=on;关闭时不能同时带 thinking(上游会优先 thinking),只用 reasoning_effort=none
    ...(thinkingOn ? { thinking: { type: 'enabled' } } : { reasoning_effort: 'none' }),
  };

  // M2:服务端工具由 DeepSeek 自动执行,我们只声明
  const tools: Array<{ type: string; name: string }> = [];
  if (searchOn && config.enableWebSearch) tools.push({ type: 'deepseek_web_search', name: 'deepseek_web_search' });
  if (searchOn && config.enableReadUrl) tools.push({ type: 'deepseek_read_url', name: 'deepseek_read_url' });
  if (tools.length > 0) body.tools = tools;
  // 客户端工具(memory/http_request):标准 function calling,由我们本地执行
  if (params.tools !== undefined && params.tools.length > 0) {
    body.tools = [...(Array.isArray(body.tools) ? (body.tools as unknown[]) : []), ...params.tools];
  }
  if (config.safetyLevel !== 'off') body.safety_check = { level: config.safetyLevel };
  if (config.titleEnabled) body.title = { enabled: true };

  if (process.env.DEBUG_UPSTREAM === '1') {
    // 排障用:只打印请求体结构,不含密钥
    console.log('[upstream-body]', JSON.stringify(body));
  }
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'text/event-stream',
      Authorization: `Bearer ${params.apiKey ?? config.deepseekApiKey}`,
    },
    body: JSON.stringify(body),
    signal,
  });

  if (!response.ok || !response.body) {
    const detail = await response.text().catch(() => '');
    throw new UpstreamError(response.status, detail.slice(0, 500));
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      for (;;) {
        const match = /\r?\n\r?\n/.exec(buffer);
        if (!match) break;
        const block = buffer.slice(0, match.index);
        buffer = buffer.slice(match.index + match[0].length);

        const delta = parseSseBlock(block);
        if (delta === 'done') return;
        if (delta) yield delta;
      }
    }
  } finally {
    reader.releaseLock();
  }
}

function parseSseBlock(block: string): ChatDelta | 'done' | null {
  const dataLines = block
    .split(/\r?\n/)
    .filter((line) => line.startsWith('data:'))
    .map((line) => line.slice(5).trimStart());

  if (dataLines.length === 0) return null;
  const payload = dataLines.join('\n').trim();
  if (payload === '') return null;
  if (payload === '[DONE]') return 'done';

  try {
    return normalizeDeepSeekChunk(JSON.parse(payload));
  } catch {
    // 半截 JSON / keep-alive 注释块:跳过而不是中断整条流
    return null;
  }
}
