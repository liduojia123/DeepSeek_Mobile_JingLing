import type { Config } from '../config.js';
import { normalizeDeepSeekChunk, type ChatDelta } from './events.js';

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
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
}

/**
 * 调 DeepSeek Chat Completions(stream=true),把原生 SSE 增量归一化成 ChatDelta。
 * 参考:api-docs.deepseek.com/zh-cn/guides/build_a_chatbot
 */
export async function* streamChatCompletion(params: StreamChatParams): AsyncGenerator<ChatDelta> {
  const { config, messages, signal } = params;
  const url = `${config.deepseekBaseUrl.replace(/\/+$/, '')}/chat/completions`;

  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'text/event-stream',
      Authorization: `Bearer ${config.deepseekApiKey}`,
    },
    body: JSON.stringify({
      model: config.model,
      messages,
      stream: true,
      stream_options: { include_usage: true },
      thinking: { type: 'enabled' },
    }),
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
