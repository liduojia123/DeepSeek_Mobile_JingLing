/**
 * DPAPP SSE 事件协议 —— 单一来源(zod schema)。
 * 修改本文件必须同步 app/lib/models/events.dart(Flutter 侧逐字段镜像)。
 *
 * 客户端唯一需要理解的格式;DeepSeek 原生事件在 deepseek/client.ts 里归一化成这里的事件。
 * 线上格式:`event: <type>\ndata: <JSON,含 type 字段>\n\n`
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
  phase: z.enum(['searching', 'reading']),
  query: z.string().optional(),
});

export const ToolResultEvent = z.object({
  type: z.literal('tool_result'),
  tool: z.string().min(1),
  summary: z.string(),
  results: z
    .array(z.object({ title: z.string(), url: z.string(), site: z.string().optional() }))
    .default([]),
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

export const MessageEndEvent = z.object({
  type: z.literal('message_end'),
  usage: z.object({
    tokens_in: z.number().int().nonnegative(),
    tokens_out: z.number().int().nonnegative(),
  }),
  cost_estimate: z.number().nonnegative(),
  stop_reason: z.enum(['end_turn', 'interrupted', 'error']),
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
  MessageEndEvent,
  ErrorEvent,
]);

export type DpappEvent = z.infer<typeof DpappEventSchema>;
export type DpappEventType = DpappEvent['type'];

export function encodeSse(event: DpappEvent): string {
  return `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`;
}

/** DeepSeek 流的归一化产物。thinking/text 可能单独出现,usage 只出现在末尾块。 */
export interface ChatDelta {
  thinking?: string;
  text?: string;
  usage?: { tokens_in: number; tokens_out: number };
  finishReason?: string;
}

type Json = Record<string, unknown>;

const asObject = (v: unknown): Json | null =>
  typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Json) : null;

const asString = (v: unknown): string | undefined => (typeof v === 'string' ? v : undefined);

const asCount = (v: unknown): number | undefined =>
  typeof v === 'number' && Number.isFinite(v) ? v : undefined;

/**
 * 归一化一个 DeepSeek Chat Completions 流式 chunk。
 * 思考内容在 Chat Completions 下是 `reasoning_content` 增量 —— 与文档若有出入,
 * 以真实响应为准(这里对未知字段宽容,解析不到就返回 null)。
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
    }
    const finishReason = asString(firstChoice.finish_reason);
    if (finishReason !== undefined) delta.finishReason = finishReason;
  }

  const usage = asObject(root.usage);
  if (usage) {
    const tokensIn = asCount(usage.prompt_tokens);
    const tokensOut = asCount(usage.completion_tokens);
    if (tokensIn !== undefined || tokensOut !== undefined) {
      delta.usage = { tokens_in: tokensIn ?? 0, tokens_out: tokensOut ?? 0 };
    }
  }

  return delta.thinking === undefined &&
    delta.text === undefined &&
    delta.usage === undefined &&
    delta.finishReason === undefined
    ? null
    : delta;
}
