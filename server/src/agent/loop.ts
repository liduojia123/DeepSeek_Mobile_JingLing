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
  /**
   * end_turn = 正常结束;interrupted = 用户 stop/断连;error = 上游失败或超时。
   * 后两种都会把已收到的部分内容返回,由路由层落库(不能丢用户已经看到的文字)。
   */
  stopReason: 'end_turn' | 'interrupted' | 'error';
  /** stopReason='error' 时给客户端看的错误信息 */
  errorMessage?: string;
}

export interface AgentTurnParams {
  config: Config;
  messages: ChatMessage[];
  signal: AbortSignal;
  /** 只发增量类事件;message_start / message_end 由路由层负责。 */
  emit: (event: DpappEvent) => void;
}

/** 中断/失败时上游不会给 usage,按字符数估算,避免用量看板系统性少计。 */
const estimateTokens = (text: string): number => Math.max(1, Math.ceil(text.length / 2));

/**
 * M0 直通骨架:单轮调用(思考流 + 正文流),不执行工具。
 * M5 在这里接 memory / http_request,循环上限 config.maxToolLoops。
 * 本函数不抛异常:失败以 stopReason='error' 返回,路由层负责收尾与落库。
 */
export async function runAgentTurn(params: AgentTurnParams): Promise<AgentTurnResult> {
  const { config, messages, signal, emit } = params;

  let thinking = '';
  let text = '';
  let tokensIn = 0;
  let tokensOut = 0;
  let thinkingClosed = false;
  let stopReason: AgentTurnResult['stopReason'] = 'end_turn';
  let errorMessage: string | undefined;

  const closeThinking = (): void => {
    if (thinkingClosed || thinking === '') return;
    thinkingClosed = true;
    emit({ type: 'thinking_end' });
  };

  // 上游长时间无数据时主动放弃,否则该会话会永久卡在 generation_in_progress
  const timeoutSignal = AbortSignal.timeout(config.upstreamTimeoutMs);
  const combined = AbortSignal.any([signal, timeoutSignal]);

  const source: AsyncGenerator<ChatDelta> = config.mock
    ? mockStream({ messages, signal: combined, delayMs: config.mockDelayMs })
    : streamChatCompletion({ config, messages, signal: combined });

  try {
    for await (const delta of source) {
      if (combined.aborted) break;

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
    if (signal.aborted) {
      stopReason = 'interrupted';
    } else if (timeoutSignal.aborted) {
      stopReason = 'error';
      errorMessage = '模型响应超时,请重试';
    } else if (error instanceof DOMException && error.name === 'AbortError') {
      stopReason = 'interrupted';
    } else {
      stopReason = 'error';
      errorMessage = '模型服务暂时不可用,请稍后重试';
    }
  }

  if (signal.aborted) stopReason = 'interrupted';
  closeThinking();

  if (tokensIn === 0 && tokensOut === 0 && (text !== '' || thinking !== '')) {
    tokensIn = estimateTokens(messages.map((message) => message.content).join('\n'));
    tokensOut = estimateTokens(text + thinking);
  }

  const cost =
    (tokensIn * config.priceInCnyPerMtok + tokensOut * config.priceOutCnyPerMtok) / 1_000_000;

  return { thinking, text, tokensIn, tokensOut, cost, stopReason, errorMessage };
}
