/**
 * DPAPP SSE 事件协议 —— 单一来源(zod schema)。
 * 修改本文件必须同步 app/lib/models/events.dart(Flutter 侧逐字段镜像)。
 *
 * 客户端唯一需要理解的格式;DeepSeek 原生事件在 deepseek/client.ts 里归一化成这里的事件。
 * 线上格式:`event: <type>\ndata: <JSON,含 type 字段>\n\n`
 *
 * M2 扩展(真机/真 key 实测确认,见 docs/HANDOFF-M2.md §0.1):
 *  - tool_progress / tool_result 带 action 细节(搜索词、URL、页内查找)
 *  - citation 带正文偏移(start_index/end_index),客户端据此渲染角标
 *  - 新增 title 事件(服务端生成会话标题)
 *  - message_end.usage 增加缓存命中与搜索/抓取计费次数
 */
import { z } from 'zod';

export const MessageStartEvent = z.object({
  type: z.literal('message_start'),
  message_id: z.string().min(1),
  /** 本轮对应的用户消息 id(重新生成时为 null);编辑重发/失败对账需要 */
  user_message_id: z.string().min(1).nullable(),
  model: z.string().min(1),
});

export const ThinkingDeltaEvent = z.object({
  type: z.literal('thinking_delta'),
  text: z.string(),
});

export const ThinkingEndEvent = z.object({
  type: z.literal('thinking_end'),
});

export const ToolProgressEvent = z.object({
  type: z.literal('tool_progress'),
  tool: z.string().min(1),
  phase: z.enum(['searching', 'reading', 'fetching', 'finding', 'tool']),
  action_type: z.string().optional(),
  queries: z.array(z.string()).optional(),
  url: z.string().optional(),
  pattern: z.string().optional(),
  step: z.number().int().nonnegative().optional(),
});

export const ToolResultItem = z.object({
  title: z.string(),
  url: z.string(),
  site_name: z.string().optional(),
  snippet: z.string().optional(),
  published_at: z.string().optional(),
});

export const ToolResultEvent = z.object({
  type: z.literal('tool_result'),
  tool: z.string().min(1),
  call_id: z.string().optional(),
  status: z.string().optional(),
  summary: z.string().default(''),
  results: z.array(ToolResultItem).default([]),
});

export const TextDeltaEvent = z.object({
  type: z.literal('text_delta'),
  text: z.string(),
});

export const CitationEvent = z.object({
  type: z.literal('citation'),
  index: z.number().int().nonnegative(),
  url: z.string(),
  title: z.string(),
  /** 正文里的字符偏移(相对本轮正文),客户端用来插角标 */
  start_index: z.number().int().nonnegative().optional(),
  end_index: z.number().int().nonnegative().optional(),
});

export const FileAttachedEvent = z.object({
  type: z.literal('file_attached'),
  file_id: z.string().min(1),
  name: z.string(),
  status: z.enum(['pending', 'parsed', 'failed']),
});

export const SafetyBlockEvent = z.object({
  type: z.literal('safety_block'),
  reason: z.string(),
});

/** 服务端生成会话标题(开启 title 时);客户端用来更新标题栏与列表 */
export const TitleEvent = z.object({
  type: z.literal('title'),
  title: z.string().min(1),
});

export const MessageEndEvent = z.object({
  type: z.literal('message_end'),
  usage: z.object({
    tokens_in: z.number().int().nonnegative(),
    tokens_out: z.number().int().nonnegative(),
    tokens_cached: z.number().int().nonnegative().default(0),
    search_calls: z.number().int().nonnegative().default(0),
    fetch_calls: z.number().int().nonnegative().default(0),
  }),
  cost_estimate: z.number().nonnegative(),
  /** refusal 仅用于输入被内容审核拦截(M2 spike 结论),输出侧拒答是普通正文 */
  stop_reason: z.enum(['end_turn', 'interrupted', 'error', 'refusal']),
});

export const ErrorEvent = z.object({
  type: z.literal('error'),
  code: z.string().min(1),
  message: z.string(),
});

export const DpappEventSchema = z.discriminatedUnion('type', [
  MessageStartEvent,
  ThinkingDeltaEvent,
  ThinkingEndEvent,
  ToolProgressEvent,
  ToolResultEvent,
  TextDeltaEvent,
  CitationEvent,
  FileAttachedEvent,
  SafetyBlockEvent,
  TitleEvent,
  MessageEndEvent,
  ErrorEvent,
]);

export type DpappEvent = z.infer<typeof DpappEventSchema>;
export type DpappEventType = DpappEvent['type'];
export type CitationPayload = z.infer<typeof CitationEvent>;
export type ToolResultPayload = z.infer<typeof ToolResultEvent>;

export function encodeSse(event: DpappEvent): string {
  return `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`;
}

// ---------- 上游(DeepSeek Chat Completions)归一化 ----------

export interface ToolSource {
  url: string;
  title?: string;
  snippet?: string;
  site_name?: string;
  published_at?: string;
}

export interface ToolCall {
  id?: string;
  type?: string;
  kind?: string;
  action?: { type?: string; queries?: string[]; url?: string; pattern?: string };
  status?: string;
  sources?: ToolSource[];
}

/** delta.server_tool_calls 的一个块:一次工具调用及其结果(整块下发,不分片) */
export interface ToolCallBlock {
  index?: number;
  reasoning_content?: string;
  calls: ToolCall[];
}

export interface CitationDelta {
  url: string;
  title: string;
  start_index?: number;
  end_index?: number;
}

export interface ChatUsage {
  tokens_in: number;
  tokens_out: number;
  tokens_cached: number;
  search_calls: number;
  fetch_calls: number;
}

/** DeepSeek 流的归一化产物。thinking/text 可能单独出现,usage 只出现在末尾块。 */
export interface FunctionToolCallDelta {
  index: number;
  id?: string;
  name?: string;
  argumentsDelta?: string;
}

export interface ChatDelta {
  thinking?: string;
  text?: string;
  usage?: ChatUsage;
  finishReason?: string;
  title?: string;
  annotations?: CitationDelta[];
  toolCalls?: ToolCallBlock[];
  /** 客户端工具的流式分片(按 index 聚合) */
  functionToolCalls?: FunctionToolCallDelta[];
  toolEvent?: { type: string; step?: number };
}

type Json = Record<string, unknown>;

const asObject = (v: unknown): Json | null =>
  typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Json) : null;

const asString = (v: unknown): string | undefined => (typeof v === 'string' ? v : undefined);

const asCount = (v: unknown): number | undefined =>
  typeof v === 'number' && Number.isFinite(v) ? v : undefined;

const asArray = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);

function normalizeAnnotations(raw: unknown): CitationDelta[] {
  const out: CitationDelta[] = [];
  for (const entry of asArray(raw)) {
    const item = asObject(entry);
    if (!item || item.type !== 'url_citation') continue;
    const citation = asObject(item.url_citation);
    if (!citation) continue;
    const url = asString(citation.url);
    if (!url) continue;
    out.push({
      url,
      title: asString(citation.title) ?? '',
      start_index: asCount(citation.start_index),
      end_index: asCount(citation.end_index),
    });
  }
  return out;
}

function normalizeToolSources(raw: unknown): ToolSource[] {
  const out: ToolSource[] = [];
  for (const entry of asArray(raw)) {
    const item = asObject(entry);
    if (!item) continue;
    const url = asString(item.url);
    if (!url) continue;
    out.push({
      url,
      title: asString(item.title),
      snippet: asString(item.snippet),
      site_name: asString(item.site_name),
      published_at: asString(item.published_at),
    });
  }
  return out;
}

function normalizeToolCalls(raw: unknown): ToolCallBlock[] {
  const blocks: ToolCallBlock[] = [];
  for (const entry of asArray(raw)) {
    const block = asObject(entry);
    if (!block) continue;
    const calls: ToolCall[] = [];
    for (const callEntry of asArray(block.calls)) {
      const call = asObject(callEntry);
      if (!call) continue;
      const action = asObject(call.action);
      calls.push({
        id: asString(call.id),
        type: asString(call.type),
        kind: asString(call.kind),
        status: asString(call.status),
        action: action
          ? {
              type: asString(action.type),
              queries: asArray(action.queries).filter((q): q is string => typeof q === 'string'),
              url: asString(action.url),
              pattern: asString(action.pattern),
            }
          : undefined,
        sources: normalizeToolSources(call.sources),
      });
    }
    blocks.push({
      index: asCount(block.index),
      reasoning_content: asString(block.reasoning_content),
      calls,
    });
  }
  return blocks;
}

/**
 * 归一化一个 DeepSeek Chat Completions 流式 chunk。
 * 字段名以真实响应为准(见 HANDOFF-M2 §0.1);未知字段宽容忽略,解析不到返回 null。
 */
export function normalizeDeepSeekChunk(chunk: unknown): ChatDelta | null {
  const root = asObject(chunk);
  if (!root) return null;

  const delta: ChatDelta = {};

  const choices = Array.isArray(root.choices) ? root.choices : [];
  const firstChoice = asObject(choices[0]);
  if (firstChoice) {
    const inner = asObject(firstChoice.delta);
    if (inner) {
      const thinking = asString(inner.reasoning_content);
      if (thinking !== undefined && thinking !== '') delta.thinking = thinking;
      const text = asString(inner.content);
      if (text !== undefined && text !== '') delta.text = text;
      const title = asString(inner.title);
      if (title !== undefined && title !== '') delta.title = title;
      if (Array.isArray(inner.tool_calls)) {
        const deltas: FunctionToolCallDelta[] = [];
        for (const item of inner.tool_calls) {
          const call = asObject(item);
          if (!call) continue;
          const fn = asObject(call.function);
          if (!fn) continue;
          const index = asCount(call.index) ?? 0;
          deltas.push({
            index,
            id: asString(call.id),
            name: asString(fn.name),
            argumentsDelta: asString(fn.arguments),
          });
        }
        if (deltas.length > 0) delta.functionToolCalls = deltas;
      }
      const annotations = normalizeAnnotations(inner.annotations);
      if (annotations.length > 0) delta.annotations = annotations;
      const toolCalls = normalizeToolCalls(inner.server_tool_calls);
      if (toolCalls.length > 0) delta.toolCalls = toolCalls;
    }
    const finishReason = asString(firstChoice.finish_reason);
    if (finishReason !== undefined) delta.finishReason = finishReason;

    const toolEvent = asObject(firstChoice.server_tool_event);
    if (toolEvent) {
      const type = asString(toolEvent.type);
      if (type) delta.toolEvent = { type, step: asCount(toolEvent.step) };
    }
  }

  const usage = asObject(root.usage);
  if (usage) {
    const tokensIn = asCount(usage.prompt_tokens);
    const tokensOut = asCount(usage.completion_tokens);
    const promptDetails = asObject(usage.prompt_tokens_details);
    const completionDetails = asObject(usage.completion_tokens_details);
    const serverToolUse = asObject(usage.server_tool_use);
    if (tokensIn !== undefined || tokensOut !== undefined) {
      delta.usage = {
        tokens_in: tokensIn ?? 0,
        tokens_out: tokensOut ?? 0,
        tokens_cached: asCount(promptDetails?.cached_tokens) ?? 0,
        // tool_search/tool_fetch 是计费次数(图片搜索单独计,本里程碑不展示)
        search_calls: (asCount(serverToolUse?.tool_search) ?? 0) + (asCount(serverToolUse?.tool_image_search) ?? 0),
        fetch_calls: asCount(serverToolUse?.tool_fetch) ?? 0,
      };
      void completionDetails;
    }
  }

  return Object.keys(delta).length === 0 ? null : delta;
}
