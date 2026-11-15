import type { Config } from '../config.js';
import { streamChatCompletion, UpstreamError, type ChatMessage } from '../deepseek/client.js';
import type { ChatDelta, CitationPayload, DpappEvent, ToolCall, ToolCallBlock } from '../deepseek/events.js';
import { mockStream } from '../deepseek/mock.js';
import type { Db } from '../db.js';
import { clientToolSpecs, executeClientTool, type ClientToolCall } from './tools.js';

export interface ToolTrace {
  tool: string;
  summary: string;
  call_id?: string;
  status?: string;
  results: Array<{ title: string; url: string; site_name?: string; snippet?: string; published_at?: string }>;
}

/** M5:一次客户端工具调用的完整记录(落库用于历史回放) */
export interface ClientToolBlock {
  callId: string;
  name: string;
  arguments: string;
  result: string;
  ok: boolean;
}

export interface AgentTurnResult {
  thinking: string;
  text: string;
  tokensIn: number;
  tokensOut: number;
  tokensCached: number;
  searchCalls: number;
  fetchCalls: number;
  /** M5:客户端工具调用次数(memory / http_request) */
  clientToolCalls: number;
  cost: number;
  stopReason: 'end_turn' | 'interrupted' | 'error' | 'refusal';
  errorMessage?: string;
  safetyBlocked: boolean;
  title?: string;
  citations: CitationPayload[];
  toolTraces: ToolTrace[];
  /** server_tool_calls 原样保留,供下一轮回传 */
  serverBlocks: ToolCallBlock[];
  /** M5:客户端工具调用记录(落库并参与历史回放) */
  toolBlocks: ClientToolBlock[];
}

export interface AgentTurnParams {
  config: Config;
  db: Db;
  messages: ChatMessage[];
  signal: AbortSignal;
  emit: (event: DpappEvent) => void;
  search?: boolean;
  thinking?: boolean;
  /** 本次请求是否启用客户端工具(默认启用) */
  toolsEnabled?: boolean;
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
      return `搜索 ${(action.queries ?? []).map((q) => `「${q}」`).join(' ')} → ${sources.length} 条结果`;
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

interface RoundOutput {
  text: string;
  toolCalls: ClientToolCall[];
  usage: { tokensIn: number; tokensOut: number; tokensCached: number; searchCalls: number; fetchCalls: number };
  title?: string;
  citations: CitationPayload[];
  serverBlocks: ToolCallBlock[];
  toolTraces: ToolTrace[];
}

/**
 * M0 直通骨架 + M2 服务端联网工具 + M5 客户端工具循环(memory/http_request)。
 * 本函数不抛异常:失败以 stopReason 返回,路由层负责收尾与落库。
 */
export async function runAgentTurn(params: AgentTurnParams): Promise<AgentTurnResult> {
  const { config, db, signal, emit } = params;
  const workingMessages: ChatMessage[] = [...params.messages];
  const tools = params.toolsEnabled === false ? [] : clientToolSpecs(config);

  let thinking = '';
  let text = '';
  let tokensIn = 0;
  let tokensOut = 0;
  let tokensCached = 0;
  let searchCalls = 0;
  let fetchCalls = 0;
  let clientToolCalls = 0;
  let thinkingClosed = false;
  let stopReason: AgentTurnResult['stopReason'] = 'end_turn';
  let errorMessage: string | undefined;
  let safetyBlocked = false;
  let title: string | undefined;

  const citations: CitationPayload[] = [];
  const citedUrls = new Set<string>();
  const toolTraces: ToolTrace[] = [];
  const serverBlocks: ToolCallBlock[] = [];
  const toolBlocks: ClientToolBlock[] = [];

  const closeThinking = (): void => {
    if (thinkingClosed || thinking === '') return;
    thinkingClosed = true;
    emit({ type: 'thinking_end' });
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

  const streamRound = async (roundMessages: ChatMessage[], roundIndex: number): Promise<RoundOutput> => {
    const output: RoundOutput = {
      text: '',
      toolCalls: [],
      usage: { tokensIn: 0, tokensOut: 0, tokensCached: 0, searchCalls: 0, fetchCalls: 0 },
      citations: [],
      serverBlocks: [],
      toolTraces: [],
    };
    const pending = new Map<number, { id?: string; name?: string; arguments: string }>();

    const source: AsyncGenerator<ChatDelta> = config.mock
      ? mockStream({ messages: roundMessages, signal: combined, delayMs: config.mockDelayMs, toolsEnabled: tools.length > 0 })
      : streamChatCompletion({
          config,
          messages: roundMessages,
          signal: combined,
          search: params.search,
          thinking: params.thinking,
          tools,
        });

    try {
      for await (const delta of source) {
        if (combined.aborted) break;

        if (delta.thinking !== undefined) {
          thinking += delta.thinking;
          emit({ type: 'thinking_delta', text: delta.thinking });
        }
        if (delta.text !== undefined) {
          if (thinking !== '') closeThinking();
          text += delta.text;
          output.text += delta.text;
          emit({ type: 'text_delta', text: delta.text });
        }
        if (delta.annotations !== undefined) emitCitations(delta.annotations);
        if (delta.toolCalls !== undefined) {
          for (const block of delta.toolCalls) {
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
              output.toolTraces.push({
                tool: call.type ?? 'deepseek_web_search',
                summary,
                call_id: call.id,
                status: call.status,
                results,
              });
            }
            output.serverBlocks.push(block);
          }
        }
        if (delta.functionToolCalls !== undefined) {
          for (const piece of delta.functionToolCalls) {
            const entry = pending.get(piece.index) ?? { arguments: '' };
            if (piece.id !== undefined) entry.id = piece.id;
            if (piece.name !== undefined) entry.name = piece.name;
            if (piece.argumentsDelta !== undefined) entry.arguments += piece.argumentsDelta;
            pending.set(piece.index, entry);
          }
        }
        if (delta.title !== undefined && delta.title !== '') {
          title = delta.title;
          emit({ type: 'title', title: delta.title });
        }
        if (delta.usage !== undefined) {
          output.usage.tokensIn += delta.usage.tokens_in;
          output.usage.tokensOut += delta.usage.tokens_out;
          output.usage.tokensCached += delta.usage.tokens_cached;
          output.usage.searchCalls += delta.usage.search_calls;
          output.usage.fetchCalls += delta.usage.fetch_calls;
        }
      }
    } catch (error) {
      if (signal.aborted) {
        stopReason = 'interrupted';
      } else if (timeoutSignal.aborted) {
        stopReason = 'error';
        errorMessage = '模型响应超时,请重试';
      } else if (error instanceof UpstreamError && error.statusCode === 400 && /Content Exists Risk/i.test(error.detail)) {
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

    for (const [index, entry] of [...pending.entries()].sort((a, b) => a[0] - b[0])) {
      if (entry.name === undefined || entry.name === '') continue;
      output.toolCalls.push({
        id: entry.id ?? `call_${roundIndex}_${index}`,
        name: entry.name,
        arguments: entry.arguments,
      });
    }
    return output;
  };

  // 最多 3 轮:模型请求工具 → 本地执行 → 再请求
  for (let round = 1; round <= 3; round += 1) {
    if (combined.aborted) break;
    const output = await streamRound(workingMessages, round);
    tokensIn += output.usage.tokensIn;
    tokensOut += output.usage.tokensOut;
    tokensCached += output.usage.tokensCached;
    searchCalls += output.usage.searchCalls;
    fetchCalls += output.usage.fetchCalls;
    citations.push(...output.citations);
    toolTraces.push(...output.toolTraces);
    serverBlocks.push(...output.serverBlocks);

    if (stopReason !== 'end_turn') break;
    if (output.toolCalls.length === 0) break;
    if (round === 3) {
      // 防死循环:最后一轮仍要调工具,就不再执行
      break;
    }

    workingMessages.push({
      role: 'assistant',
      content: output.text,
      tool_calls: output.toolCalls.map((call) => ({
        id: call.id,
        type: 'function',
        function: { name: call.name, arguments: call.arguments },
      })),
    });

    for (const call of output.toolCalls) {
      clientToolCalls += 1;
      emit({
        type: 'tool_progress',
        tool: call.name,
        phase: 'tool',
        action_type: call.name,
      });
      const result = await executeClientTool(config, db, call);
      emit({
        type: 'tool_result',
        tool: call.name,
        call_id: call.id,
        status: result.ok ? 'completed' : 'failed',
        summary: result.summary,
        results: [],
      });
      toolBlocks.push({
        callId: call.id,
        name: call.name,
        arguments: call.arguments,
        result: result.content,
        ok: result.ok,
      });
      workingMessages.push({
        role: 'tool',
        content: result.content.slice(0, 8000),
        tool_call_id: call.id,
      });
    }
  }

  if (tokensIn + tokensOut === 0 && (text !== '' || thinking !== '')) {
    tokensIn = estimateTokens(thinking);
    tokensOut = estimateTokens(text);
  }

  closeThinking();

  return {
    thinking,
    text,
    tokensIn,
    tokensOut,
    tokensCached,
    searchCalls,
    fetchCalls,
    clientToolCalls,
    cost: 0,
    stopReason,
    errorMessage,
    safetyBlocked,
    title,
    citations,
    toolTraces,
    serverBlocks,
    toolBlocks,
  };
}
