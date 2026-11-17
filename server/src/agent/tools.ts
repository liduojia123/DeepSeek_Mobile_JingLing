import { randomUUID } from 'node:crypto';
import type { Config } from '../config.js';
import type { DpappEvent } from '../deepseek/events.js';
import { nowIso, type Db } from '../db.js';
import { formatShanghai, nowShanghaiIso, toUtcIso } from '../time.js';

/** 一次客户端工具调用(已从流式分片拼好) */
export interface ClientToolCall {
  id: string;
  name: string;
  arguments: string;
}

/** 一次客户端工具执行结果 */
export interface ClientToolResult {
  callId: string;
  name: string;
  ok: boolean;
  /** 回给模型的文本(tool 消息 content) */
  content: string;
  /** 给手机端展示的一句话摘要 */
  summary: string;
}

interface MemoryRow {
  id: string;
  content: string;
  tags: string;
  created_at: string;
  updated_at: string;
}

/** M7:提醒(手机本地精确闹钟)。 */
interface ReminderRow {
  id: string;
  text: string;
  fire_at: string;
  status: string;
}

const MAX_HTTP_RESPONSE_CHARS = 8000;
const HTTP_TIMEOUT_MS = 10_000;

/** OpenAI function 格式的工具声明。 */
export const CLIENT_TOOL_SPECS: Array<Record<string, unknown>> = [
  {
    type: 'function',
    function: {
      name: 'memory_save',
      description:
        '保存一条关于用户的长期记忆(偏好、事实、约定)。当用户明确要求记住某事,或表达了稳定的偏好/个人信息时调用。',
      parameters: {
        type: 'object',
        properties: {
          content: { type: 'string', description: '要记住的内容,一句完整的话' },
          tags: { type: 'array', items: { type: 'string' }, description: '可选标签,如 ["偏好","项目"]' },
        },
        required: ['content'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'memory_search',
      description: '按关键词搜索已保存的用户记忆。回答涉及用户偏好/历史事实前先查一次。',
      parameters: {
        type: 'object',
        properties: {
          query: { type: 'string', description: '关键词' },
          limit: { type: 'number', description: '返回条数,默认 5,最大 20' },
        },
        required: ['query'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'memory_list',
      description: '列出最近保存的用户记忆(不传关键词时使用)。',
      parameters: {
        type: 'object',
        properties: { limit: { type: 'number', description: '返回条数,默认 10,最大 50' } },
      },
    },
  },
];

/** http_request 仅在配置了白名单时才声明给模型。 */
export const HTTP_TOOL_SPEC: Record<string, unknown> = {
  type: 'function',
  function: {
    name: 'http_request',
    description:
      '调用用户允许的域名上的 HTTP 接口(只读优先)。仅当 URL 域名在服务端白名单内时可用;不在白名单会被拒绝。',
    parameters: {
      type: 'object',
      properties: {
        url: { type: 'string', description: '完整 URL(http/https)' },
        method: { type: 'string', enum: ['GET', 'POST'], description: '默认 GET' },
        headers: { type: 'object', description: '可选请求头(键值均为字符串)' },
        body: { type: 'string', description: 'POST 的请求体(字符串)' },
      },
      required: ['url'],
    },
  },
};

/**
 * M7:提醒三件套。服务器不"响",只负责把话说清楚并落库;
 * 真正到点响的是手机端 AlarmManager(见 docs/HANDOFF-M7.md)。
 */
export const REMINDER_TOOL_SPECS: Array<Record<string, unknown>> = [
  {
    type: 'function',
    function: {
      name: 'reminder_create',
      description:
        '为用户设置到点提醒(手机本地精确闹钟 + 系统通知)。用户说「提醒我…」「X 分钟后叫我」「明天 8 点提醒我」时调用。fire_at 必须是把相对时间换算后的、带时区偏移的 ISO8601(如 2026-11-17T20:30:00+08:00);拿不准具体时间就先问用户,不要猜。',
      parameters: {
        type: 'object',
        properties: {
          text: { type: 'string', description: '提醒内容,简短一句,如「关火」' },
          fire_at: { type: 'string', description: '触发时间,ISO8601 带偏移' },
        },
        required: ['text', 'fire_at'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'reminder_cancel',
      description:
        '取消一个还没响的提醒。用户说「取消提醒」「别提醒了」时用;先用 reminder_list 查 id,只有一条匹配就直接取消。',
      parameters: {
        type: 'object',
        properties: {
          reminder_id: { type: 'string', description: 'reminder_list 返回的 reminder_id' },
        },
        required: ['reminder_id'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'reminder_list',
      description: '列出用户还没响的提醒(取消之前先查这个)。',
      parameters: {
        type: 'object',
        properties: { limit: { type: 'number', description: '返回条数,默认 10,最大 50' } },
      },
    },
  },
];

export function clientToolSpecs(config: Config): Array<Record<string, unknown>> {
  const specs = [...CLIENT_TOOL_SPECS, ...REMINDER_TOOL_SPECS];
  return config.httpAllowlist.length > 0 ? [...specs, HTTP_TOOL_SPEC] : specs;
}

/** 域名白名单匹配:允许精确域名与其子域。 */
export function hostAllowed(host: string, allowlist: readonly string[]): boolean {
  const normalized = host.toLowerCase();
  return allowlist.some((entry) => {
    const rule = entry.toLowerCase().trim();
    if (rule === '') return false;
    return normalized === rule || normalized.endsWith(`.${rule}`);
  });
}

function parseTags(raw: unknown): string[] {
  if (Array.isArray(raw)) return raw.filter((tag): tag is string => typeof tag === 'string');
  return [];
}

function parseArgs(raw: string): Record<string, unknown> {
  if (raw.trim() === '') return {};
  try {
    const parsed = JSON.parse(raw) as unknown;
    return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : {};
  } catch {
    return {};
  }
}

const clampLimit = (value: unknown, fallback: number, max: number): number => {
  const parsed = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return Math.min(Math.floor(parsed), max);
};

export interface ClientToolOptions {
  /** 把"需要手机配合"的事件(reminder / reminder_cancel)推给当前 SSE 流 */
  emit?: (event: DpappEvent) => void;
  /** 当前会话;提醒落库时用来关联(删会话不删提醒) */
  conversationId?: string;
}

/** 执行一次客户端工具调用。永不抛异常:失败也返回内容,让模型知道发生了什么。 */
export async function executeClientTool(
  config: Config,
  db: Db,
  call: ClientToolCall,
  options: ClientToolOptions = {},
): Promise<ClientToolResult> {
  const { emit, conversationId } = options;
  const args = parseArgs(call.arguments);
  const fail = (content: string): ClientToolResult => ({
    callId: call.id,
    name: call.name,
    ok: false,
    content,
    summary: content.slice(0, 80),
  });

  switch (call.name) {
    case 'memory_save': {
      const content = typeof args.content === 'string' ? args.content.trim() : '';
      if (content === '') return fail('content 不能为空');
      const tags = parseTags(args.tags);
      const timestamp = nowIso();
      db.prepare(
        'INSERT INTO memory_note (id, content, tags, created_at, updated_at) VALUES (?, ?, ?, ?, ?)',
      ).run(randomUUID(), content.slice(0, 2000), JSON.stringify(tags), timestamp, timestamp);
      return {
        callId: call.id,
        name: call.name,
        ok: true,
        content: `已记住:${content}`,
        summary: `记住「${content.slice(0, 40)}」`,
      };
    }
    case 'memory_search': {
      const query = typeof args.query === 'string' ? args.query.trim() : '';
      if (query === '') return fail('query 不能为空');
      const limit = clampLimit(args.limit, 5, 20);
      const rows = db
        .prepare(
          'SELECT id, content, tags, created_at, updated_at FROM memory_note WHERE content LIKE ? OR tags LIKE ? ORDER BY updated_at DESC LIMIT ?',
        )
        .all(`%${query}%`, `%${query}%`, limit) as MemoryRow[];
      const content =
        rows.length === 0
          ? `没有找到与「${query}」相关的记忆`
          : JSON.stringify(
              rows.map((row) => ({ content: row.content, tags: JSON.parse(row.tags) as string[], updated_at: row.updated_at })),
            );
      return {
        callId: call.id,
        name: call.name,
        ok: true,
        content,
        summary: `搜索记忆「${query}」→ ${rows.length} 条`,
      };
    }
    case 'memory_list': {
      const limit = clampLimit(args.limit, 10, 50);
      const rows = db
        .prepare('SELECT content, tags, updated_at FROM memory_note ORDER BY updated_at DESC LIMIT ?')
        .all(limit) as MemoryRow[];
      return {
        callId: call.id,
        name: call.name,
        ok: true,
        content:
          rows.length === 0
            ? '还没有保存任何记忆'
            : JSON.stringify(
                rows.map((row) => ({ content: row.content, tags: JSON.parse(row.tags) as string[], updated_at: row.updated_at })),
              ),
        summary: `列出记忆 ${rows.length} 条`,
      };
    }
    case 'http_request': {
      const rawUrl = typeof args.url === 'string' ? args.url.trim() : '';
      if (rawUrl === '') return fail('url 不能为空');
      let parsed: URL;
      try {
        parsed = new URL(rawUrl);
      } catch {
        return fail('url 不是合法的绝对地址');
      }
      if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
        return fail('只允许 http/https');
      }
      if (!hostAllowed(parsed.hostname, config.httpAllowlist)) {
        return fail(`域名 ${parsed.hostname} 不在白名单内,已拒绝请求`);
      }
      const method = args.method === 'POST' ? 'POST' : 'GET';
      const headers: Record<string, string> = {};
      if (args.headers !== null && typeof args.headers === 'object' && !Array.isArray(args.headers)) {
        for (const [key, value] of Object.entries(args.headers as Record<string, unknown>)) {
          if (typeof value === 'string') headers[key] = value;
        }
      }
      try {
        const response = await fetch(parsed, {
          method,
          headers,
          body: method === 'POST' && typeof args.body === 'string' ? args.body : undefined,
          signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
          redirect: 'follow',
        });
        const text = await response.text();
        const truncated = text.length > MAX_HTTP_RESPONSE_CHARS ? `${text.slice(0, MAX_HTTP_RESPONSE_CHARS)}\n…(已截断)` : text;
        return {
          callId: call.id,
          name: call.name,
          ok: response.ok,
          content: `HTTP ${response.status}\n${truncated}`,
          summary: `${method} ${parsed.hostname}${parsed.pathname} → ${response.status}`,
        };
      } catch (error) {
        return fail(`请求失败:${error instanceof Error ? error.message : String(error)}`);
      }
    }
    case 'reminder_create': {
      const text = typeof args.text === 'string' ? args.text.trim() : '';
      if (text === '') return fail('text 不能为空');
      const raw = typeof args.fire_at === 'string' ? args.fire_at.trim() : '';
      if (raw === '') return fail('fire_at 不能为空');
      // 必须带偏移:否则 Date.parse 会按服务器时区猜,同一句话在不同机器上算出不同时刻
      if (!/(?:Z|[+-]\d{2}:\d{2})$/.test(raw)) {
        return fail('fire_at 必须带时区偏移,例如 2026-11-17T20:30:00+08:00');
      }
      const fireAt = toUtcIso(raw);
      if (fireAt === null) return fail('fire_at 不是合法时间');
      const fireMs = Date.parse(fireAt);
      const now = Date.now();
      if (fireMs < now + 10_000) {
        return fail(
          `这个时间已经过去或太近(${formatShanghai(fireAt)}),现在是 ${formatShanghai(new Date(now).toISOString())}。请确认是今天还是明天,给出未来时间。`,
        );
      }
      // 幂等:同一会话里同样的文本与时刻,不重复建、不重复推事件(防"重新生成"建两条)
      const dup = db
        .prepare(
          `SELECT id FROM reminder
            WHERE text = ? AND fire_at = ? AND status != 'cancelled'
              AND ((conversation_id IS NULL AND ? IS NULL) OR conversation_id = ?)
            LIMIT 1`,
        )
        .get(text, fireAt, conversationId ?? null, conversationId ?? null) as { id: string } | undefined;
      if (dup !== undefined) {
        return {
          callId: call.id,
          name: call.name,
          ok: true,
          content: `这条提醒已经设过了:${formatShanghai(fireAt)} ${text}`,
          summary: `提醒已存在 ${formatShanghai(fireAt)}`,
        };
      }
      const id = randomUUID();
      db.prepare(
        'INSERT INTO reminder (id, conversation_id, text, fire_at, status, created_at) VALUES (?, ?, ?, ?, ?, ?)',
      ).run(id, conversationId ?? null, text.slice(0, 200), fireAt, 'pending', nowIso());
      emit?.({ type: 'reminder', reminder_id: id, text, fire_at: fireAt });
      const minutes = Math.round((fireMs - now) / 60_000);
      return {
        callId: call.id,
        name: call.name,
        ok: true,
        content: `已设置提醒 ${formatShanghai(fireAt)} ${text}(约 ${minutes} 分钟后)`,
        summary: `设置提醒 ${formatShanghai(fireAt)} ${text}`,
      };
    }
    case 'reminder_cancel': {
      const reminderId = typeof args.reminder_id === 'string' ? args.reminder_id.trim() : '';
      if (reminderId === '') return fail('reminder_id 不能为空');
      const row = db
        .prepare('SELECT id, text, fire_at, status FROM reminder WHERE id = ?')
        .get(reminderId) as ReminderRow | undefined;
      if (row === undefined) return fail('没有这条提醒(可能已删除),可以先用 reminder_list 查一下');
      if (row.status === 'cancelled') return fail('这条提醒已经取消过了');
      if (row.status === 'fired') return fail('这条提醒已经响过了,取消不了');
      db.prepare("UPDATE reminder SET status = 'cancelled' WHERE id = ?").run(reminderId);
      emit?.({ type: 'reminder_cancel', reminder_id: reminderId });
      return {
        callId: call.id,
        name: call.name,
        ok: true,
        content: `已取消提醒:${formatShanghai(row.fire_at)} ${row.text}`,
        summary: `取消提醒 ${formatShanghai(row.fire_at)}`,
      };
    }
    case 'reminder_list': {
      const limit = clampLimit(args.limit, 10, 50);
      const rows = db
        .prepare(
          `SELECT id, text, fire_at, status FROM reminder
            WHERE status IN ('pending','scheduled') AND fire_at > ?
            ORDER BY fire_at ASC LIMIT ?`,
        )
        .all(new Date().toISOString(), limit) as ReminderRow[];
      return {
        callId: call.id,
        name: call.name,
        ok: true,
        content:
          rows.length === 0
            ? '当前没有待响的提醒'
            : JSON.stringify(
                rows.map((row) => ({
                  reminder_id: row.id,
                  text: row.text,
                  fire_at: formatShanghai(row.fire_at),
                  status: row.status,
                })),
              ),
        summary: `列出提醒 ${rows.length} 条`,
      };
    }
    default:
      return fail(`未知工具:${call.name}`);
  }
}

/** 今日(UTC)已花费金额。 */
export function todayCostCny(db: Db): number {
  const dayStart = `${new Date().toISOString().slice(0, 10)}T00:00:00.000Z`;
  const row = db.prepare('SELECT COALESCE(SUM(cost), 0) AS total FROM usage_log WHERE ts >= ?').get(dayStart) as {
    total: number;
  };
  return Number(row.total) || 0;
}

/** 预算状态;budget <= 0 表示不限制。 */
export function budgetState(
  config: Config,
  db: Db,
): { used: number; budget: number; exceeded: boolean } {
  const used = todayCostCny(db);
  const budget = config.dailyBudgetCny;
  return { used, budget, exceeded: budget > 0 && used >= budget };
}
