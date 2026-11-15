import type { Config } from '../config.js';
import { streamChatCompletion, UpstreamError, type ChatMessage } from '../deepseek/client.js';
import type { ChatDelta, CitationPayload, DpappEvent, ToolCall, ToolCallBlock } from '../deepseek/events.js';
import { mockStream } from '../deepseek/mock.js';

export interface ToolTrace {
  tool: string;
  summary: string;
  call_id?: string;
  status?: string;
  results: Array<{ title: string; url: string; site_name?: string; snippet?: string; published_at?: string }>;
}

export interface AgentTurnResult {
  thinking: string;
  text: string;
  tokensIn: number;
  tokensOut: number;
  tokensCached: number;
  searchCalls: number;
  fetchCalls: number;
  cost: number;
  /**
   * end_turn = 正常结束;interrupted = 用户 stop/断连;error = 上游失败或超时;
   * refusal = 输入被内容审核拦截(上游 400 Content Exists Risk,M2 实测结论)。
   */
  stopReason: 'end_turn' | 'interrupted' | 'error' | 'refusal';
  errorMessage?: string;
  safetyBlocked: boolean;
  /** 服务端生成的会话标题(开启 title 时) */
  title?: string;
  citations: CitationPayload[];
  toolTraces: ToolTrace[];
  /** server_tool_calls 原样保留,供下一轮回传(阅读链接的网页靠它拼回上下文) */
  serverBlocks: ToolCallBlock[];
}

export interface AgentTurnParams {
  config: Config;
  messages: ChatMessage[];
  signal: AbortSignal;
  /** 只发增量类事件;message_start / message_end 由路由层负责。 */
  emit: (event: DpappEvent) => void;
  /** 本次请求是否启用联网搜索/读链接(默认启用) */
  search?: boolean;
  /** 本次请求是否启用思考(默认启用) */
  thinking?: boolean;
}

/** 中断/失败时上游不会给 usage,按字符数估算,避免用量看板系统性少计。 */
const estimateTokens = (text: string): number => Math.max(1, Math.ceil(text.length / 2));

const phaseOf = (actionType: string | undefined): 'searching' | 'reading' | 'fetching' | 'finding' => {
  switch (actionType) {
    case 'read_link':
      return 'reading';
    case 'open_page':
      return 'fetching';
    case 'find_in_page':
      return 'finding';
    default:
      return 'searching';
  }
};

const summarizeCall = (call: ToolCall): string => {
  const action = call.action ?? {};
  const sources = call.sources ?? [];
  switch (action.type) {
    case 'search':
      return `搜索 ${ (action.queries ?? []).map((q) => `「${q}」`).join(' ') } → ${sources.length} 条结果`;
    case 'read_link':
      return `阅读链接 ${action.url ?? ''}`;
    case 'open_page':
      return `打开网页 ${action.url ?? ''}`;
    case 'find_in_page':
      return `页内查找 ${action.pattern ?? ''} @ ${action.url ?? ''}`;
    default:
      return `${call.type ?? 'tool'} ${action.type ?? ''}`.trim();
  }
};

/**
 * M0 直通骨架 + M2 联网工具。
 * 本函数不抛异常:失败以 stopReason 返回,路由层负责收尾与落库。
 */
export async function runAgentTurn(params: AgentTurnParams): Promise<AgentTurnResult> {
  const { config, messages, signal, emit } = params;

  let thinking = '';
  let text = '';
  let tokensIn = 0;
  let tokensOut = 0;
  let tokensCached = 0;
  let searchCalls = 0;
  let fetchCalls = 0;
  let thinkingClosed = false;
  let stopReason: AgentTurnResult['stopReason'] = 'end_turn';
  let errorMessage: string | undefined;
  let safetyBlocked = false;
  let title: string | undefined;

  const citations: CitationPayload[] = [];
  const citedUrls = new Set<string>();
  const toolTraces: ToolTrace[] = [];
  const serverBlocks: ToolCallBlock[] = [];

  const closeThinking = (): void => {
    if (thinkingClosed || thinking === '') return;
    thinkingClosed = true;
    emit({ type: 'thinking_end' });
  };

  const emitToolCall = (block: ToolCallBlock): void => {
    for (const call of block.calls ?? []) {
      const action = call.action ?? {};
      emit({
        type: 'tool_progress',
        tool: call.type ?? 'deepseek_web_search',
        phase: phaseOf(action.type),
        action_type: action.type,
        queries: action.queries && action.queries.length > 0 ? action.queries : undefined,
        url: action.url,
        pattern: action.pattern,
        step: block.index,
      });

      const summary = summarizeCall(call);
      const results = (call.sources ?? []).map((source) => ({
        title: source.title ?? source.url,
        url: source.url,
        site_name: source.site_name,
        snippet: source.snippet,
        published_at: source.published_at,
      }));
      emit({
        type: 'tool_result',
        tool: call.type ?? 'deepseek_web_search',
        call_id: call.id,
        status: call.status,
        summary,
        results,
      });
      toolTraces.push({
        tool: call.type ?? 'deepseek_web_search',
        summary,
        call_id: call.id,
        status: call.status,
        results,
      });
    }
    serverBlocks.push(block);
  };

  const emitCitations = (deltas: NonNullable<ChatDelta['annotations']>): void => {
    for (const annotation of deltas) {
      const key = `${annotation.url}#${annotation.start_index ?? ''}`;
      if (citedUrls.has(key)) continue;
      citedUrls.add(key);
      const citation: CitationPayload = {
        type: 'citation',
        index: citations.length + 1,
        url: annotation.url,
        title: annotation.title,
        start_index: annotation.start_index,
        end_index: annotation.end_index,
      };
      citations.push(citation);
      emit(citation);
    }
  };

  // 上游长时间无数据时主动放弃,否则该会话会永久卡在 generation_in_progress
  const timeoutSignal = AbortSignal.timeout(config.upstreamTimeoutMs);
  const combined = AbortSignal.any([signal, timeoutSignal]);

  const source: AsyncGenerator<ChatDelta> = config.mock
    ? mockStream({ messages, signal: combined, delayMs: config.mockDelayMs })
    : streamChatCompletion({
        config,
        messages,
        signal: combined,
        search: params.search,
        thinking: params.thinking,
      });

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
      if (delta.annotations !== undefined) emitCitations(delta.annotations);
      if (delta.toolCalls !== undefined) {
        for (const block of delta.toolCalls) emitToolCall(block);
      }
      if (delta.title !== undefined && delta.title !== '') {
        title = delta.title;
        emit({ type: 'title', title: delta.title });
      }
      if (delta.usage !== undefined) {
        tokensIn = delta.usage.tokens_in;
        tokensOut = delta.usage.tokens_out;
        tokensCached = delta.usage.tokens_cached;
        searchCalls = delta.usage.search_calls;
        fetchCalls = delta.usage.fetch_calls;
      }
    }
  } catch (error) {
    if (signal.aborted) {
      stopReason = 'interrupted';
    } else if (timeoutSignal.aborted) {
      stopReason = 'error';
      errorMessage = '模型响应超时,请重试';
    } else if (error instanceof UpstreamError && error.statusCode === 400 && /Content Exists Risk/i.test(error.detail)) {
      // M2 spike 结论:输入命中内容审核时上游返回 400 Content Exists Risk
      stopReason = 'refusal';
      safetyBlocked = true;
      errorMessage = '输入内容未通过安全审核';
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
    tokensIn = estimateTokens(messages.map((message) => (typeof message.content === 'string' ? message.content : JSON.stringify(message.content))).join('\n'));
    tokensOut = estimateTokens(text + thinking);
  }

  const tokenCost =
    (tokensIn * config.priceInCnyPerMtok + tokensOut * config.priceOutCnyPerMtok) / 1_000_000;
  const toolCost = searchCalls * config.searchPriceCnyPerCall + fetchCalls * config.fetchPriceCnyPerCall;
  const cost = tokenCost + toolCost;

  return {
    thinking,
    text,
    tokensIn,
    tokensOut,
    tokensCached,
    searchCalls,
    fetchCalls,
    cost,
    stopReason,
    errorMessage,
    safetyBlocked,
    title,
    citations,
    toolTraces,
    serverBlocks,
  };
}
