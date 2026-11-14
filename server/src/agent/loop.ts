import type { Config } from '../config.js';
import { streamChatCompletion, type ChatMessage } from '../deepseek/client.js';
import type { ChatDelta, DpappEvent } from '../deepseek/events.js';
import { mockStream } from '../deepseek/mock.js';

export interface AgentTurnResult {
  thinking: string;
  text: string;
  tokensIn: number;
  tokensOut: number;
  cost: number;
  stopReason: 'end_turn' | 'interrupted';
}

export interface AgentTurnParams {
  config: Config;
  messages: ChatMessage[];
  signal: AbortSignal;
  /** 只发增量类事件;message_start / message_end 由路由层负责。 */
  emit: (event: DpappEvent) => void;
}

/**
 * M0 直通骨架:单轮调用(思考流 + 正文流),不执行工具。
 * M5 在这里接 memory / http_request,循环上限 config.maxToolLoops。
 */
export async function runAgentTurn(params: AgentTurnParams): Promise<AgentTurnResult> {
  const { config, messages, signal, emit } = params;

  let thinking = '';
  let text = '';
  let tokensIn = 0;
  let tokensOut = 0;
  let thinkingClosed = false;
  let stopReason: 'end_turn' | 'interrupted' = 'end_turn';

  const closeThinking = (): void => {
    if (thinkingClosed || thinking === '') return;
    thinkingClosed = true;
    emit({ type: 'thinking_end' });
  };

  const source: AsyncGenerator<ChatDelta> = config.mock
    ? mockStream({ messages, signal, delayMs: config.mockDelayMs })
    : streamChatCompletion({ config, messages, signal });

  try {
    for await (const delta of source) {
      if (signal.aborted) break;

      if (delta.thinking !== undefined) {
        thinking += delta.thinking;
        emit({ type: 'thinking_delta', text: delta.thinking });
      }
      if (delta.text !== undefined) {
        // 正文一开始就结束思考折叠区,客户端不用等 message_end 才收尾
        if (thinking !== '') closeThinking();
        text += delta.text;
        emit({ type: 'text_delta', text: delta.text });
      }
      if (delta.usage !== undefined) {
        tokensIn = delta.usage.tokens_in;
        tokensOut = delta.usage.tokens_out;
      }
    }
  } catch (error) {
    // 中断是正常路径(stop 端点/客户端断开),其余错误交给路由层转成 error 事件
    if (signal.aborted || (error instanceof DOMException && error.name === 'AbortError')) {
      stopReason = 'interrupted';
    } else {
      throw error;
    }
  }

  if (signal.aborted) stopReason = 'interrupted';
  closeThinking();

  const cost =
    (tokensIn * config.priceInCnyPerMtok + tokensOut * config.priceOutCnyPerMtok) / 1_000_000;

  return { thinking, text, tokensIn, tokensOut, cost, stopReason };
}
