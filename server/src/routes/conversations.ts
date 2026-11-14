import { randomUUID } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { runAgentTurn } from '../agent/loop.js';
import { ApiError } from '../auth.js';
import type { Config } from '../config.js';
import { nowIso, type Db } from '../db.js';
import type { ChatMessage } from '../deepseek/client.js';
import { encodeSse, type DpappEvent } from '../deepseek/events.js';

interface ConversationRow {
  id: string;
  title: string;
  pinned: number;
  ephemeral: number;
  active_leaf_id: string | null;
  settings_json: string;
  created_at: string;
  updated_at: string;
}

interface MessageRow {
  id: string;
  conversation_id: string;
  parent_id: string | null;
  role: 'user' | 'assistant' | 'system';
  blocks_json: string;
  thinking: string;
  citations_json: string;
  tool_traces_json: string;
  tokens_in: number;
  tokens_out: number;
  cost: number;
  stop_reason: string | null;
  created_at: string;
}

interface TreeNode {
  id: string;
  parent_id: string | null;
  role: MessageRow['role'];
  blocks: unknown;
  thinking: string;
  citations: unknown;
  tool_traces: unknown;
  usage: { tokens_in: number; tokens_out: number; cost: number };
  stop_reason: string | null;
  created_at: string;
  children: TreeNode[];
}

const CreateBody = z.object({
  title: z.string().max(200).optional(),
  ephemeral: z.boolean().optional(),
});

const PatchBody = z.object({
  title: z.string().max(200).optional(),
  pinned: z.boolean().optional(),
  ephemeral: z.boolean().optional(),
  active_leaf_id: z.string().min(1).nullable().optional(),
});

const ChatBody = z.object({
  content: z.string().optional(),
  parent_message_id: z.string().min(1).nullable().optional(),
  regenerate: z.boolean().optional(),
});

const ListQuery = z.object({
  include_ephemeral: z.enum(['0', '1']).optional(),
});

const DONE_EVENT_TYPES = new Set(['end_turn', 'interrupted', 'error']);

export function registerConversationRoutes(
  app: FastifyInstance,
  ctx: { db: Db; config: Config },
): void {
  const { db, config } = ctx;

  /** 进行中的生成:conversation_id → AbortController(stop 端点与断连共用)。 */
  const activeGenerations = new Map<string, AbortController>();

  app.get('/v1/conversations', async (request) => {
    const parsed = ListQuery.safeParse(request.query);
    if (!parsed.success) throw new ApiError(400, 'validation_error', 'include_ephemeral 只能是 0 或 1');
    const includeEphemeral = parsed.data.include_ephemeral === '1';

    const rows = db
      .prepare(
        `SELECT * FROM conversation
          ${includeEphemeral ? '' : 'WHERE ephemeral = 0'}
          ORDER BY pinned DESC, updated_at DESC`,
      )
      .all() as ConversationRow[];

    const messagesStmt = db.prepare(
      'SELECT * FROM message WHERE conversation_id = ? ORDER BY created_at ASC',
    );

    return {
      conversations: rows.map((row) => {
        const messages = messagesStmt.all(row.id) as MessageRow[];
        return { ...toConversation(row), preview: previewOf(messages, row.active_leaf_id) };
      }),
    };
  });

  app.post('/v1/conversations', async (request, reply) => {
    const parsed = CreateBody.safeParse(request.body ?? {});
    if (!parsed.success) throw new ApiError(400, 'validation_error', '请求体格式错误');

    const id = randomUUID();
    const ts = nowIso();
    db.prepare(
      `INSERT INTO conversation (id, title, pinned, ephemeral, active_leaf_id, settings_json, created_at, updated_at)
       VALUES (?, ?, 0, ?, NULL, '{}', ?, ?)`,
    ).run(id, parsed.data.title?.trim() ?? '', parsed.data.ephemeral === true ? 1 : 0, ts, ts);

    const row = getConversationOrThrow(db, id);
    return reply.code(201).send(toConversation(row));
  });

  app.get('/v1/conversations/:id', async (request) => {
    const { id } = request.params as { id: string };
    const conv = getConversationOrThrow(db, id);
    const rows = allMessages(db, conv.id);
    return {
      ...toConversation(conv),
      tree: buildTree(rows),
      path: activePath(rows, conv.active_leaf_id).map((message) => message.id),
    };
  });

  app.delete('/v1/conversations/:id', async (request, reply) => {
    const { id } = request.params as { id: string };
    getConversationOrThrow(db, id);
    activeGenerations.get(id)?.abort();
    db.prepare('DELETE FROM conversation WHERE id = ?').run(id);
    return reply.code(204).send();
  });

  app.patch('/v1/conversations/:id', async (request) => {
    const { id } = request.params as { id: string };
    const parsed = PatchBody.safeParse(request.body ?? {});
    if (!parsed.success) throw new ApiError(400, 'validation_error', '请求体格式错误');

    const conv = getConversationOrThrow(db, id);
    const patch = parsed.data;
    if (
      patch.title === undefined &&
      patch.pinned === undefined &&
      patch.ephemeral === undefined &&
      patch.active_leaf_id === undefined
    ) {
      throw new ApiError(400, 'validation_error', 'PATCH 至少需要一个字段');
    }

    if (patch.active_leaf_id !== undefined && patch.active_leaf_id !== null) {
      const leaf = getMessage(db, conv.id, patch.active_leaf_id);
      if (!leaf) throw new ApiError(400, 'invalid_active_leaf', 'active_leaf_id 不属于该会话');
    }

    db.prepare(
      `UPDATE conversation SET
         title = COALESCE(?, title),
         pinned = COALESCE(?, pinned),
         ephemeral = COALESCE(?, ephemeral),
         active_leaf_id = CASE WHEN ? THEN ? ELSE active_leaf_id END,
         updated_at = ?
       WHERE id = ?`,
    ).run(
      patch.title === undefined ? null : patch.title.trim(),
      patch.pinned === undefined ? null : patch.pinned ? 1 : 0,
      patch.ephemeral === undefined ? null : patch.ephemeral ? 1 : 0,
      patch.active_leaf_id === undefined ? 0 : 1,
      patch.active_leaf_id === undefined ? null : patch.active_leaf_id,
      nowIso(),
      id,
    );

    return toConversation(getConversationOrThrow(db, conv.id));
  });

  app.post('/v1/conversations/:id/stop', async (request) => {
    const { id } = request.params as { id: string };
    getConversationOrThrow(db, id);
    const controller = activeGenerations.get(id);
    if (!controller) throw new ApiError(409, 'not_generating', '当前没有进行中的生成');
    controller.abort();
    return { stopped: true };
  });

  /**
   * 核心 SSE 端点,三种入参共用:
   *  - 普通发送        {content}                          → 挂在 active_leaf_id 下
   *  - 编辑重发        {content, parent_message_id}        → 在指定父节点下新建兄弟用户分支
   *  - 重新生成        {regenerate:true, parent_message_id} → 在指定用户消息下新建兄弟助手分支
   * 消息树语义见 docs/HANDOFF-M0-M1.md「消息分支设计」。
   */
  app.post('/v1/conversations/:id/chat', async (request, reply) => {
    const { id } = request.params as { id: string };
    const conv = getConversationOrThrow(db, id);

    const parsed = ChatBody.safeParse(request.body ?? {});
    if (!parsed.success) throw new ApiError(400, 'validation_error', '请求体格式错误');
    const body = parsed.data;
    const regenerate = body.regenerate === true;

    if (activeGenerations.has(conv.id)) {
      throw new ApiError(409, 'generation_in_progress', '该会话已有进行中的生成,请先停止');
    }

    let userContent = '';
    if (regenerate) {
      if (!body.parent_message_id) {
        throw new ApiError(400, 'validation_error', '重新生成需要 parent_message_id(指向该用户消息)');
      }
      if (body.content !== undefined && body.content.trim() !== '') {
        throw new ApiError(400, 'validation_error', '重新生成不需要 content');
      }
    } else {
      userContent = body.content?.trim() ?? '';
      if (userContent === '') throw new ApiError(400, 'validation_error', 'content 不能为空');
      if (userContent.length > config.maxContentChars) {
        throw new ApiError(413, 'content_too_long', `消息长度超过 ${config.maxContentChars} 字符上限`);
      }
    }

    // parent_message_id 为 undefined = 未指定(挂到活跃叶子);显式 null = 挂在根节点
    const parentId: string | null =
      body.parent_message_id === undefined ? conv.active_leaf_id : body.parent_message_id;
    let parentRow: MessageRow | undefined;
    if (parentId !== null && parentId !== undefined) {
      parentRow = getMessage(db, conv.id, parentId);
      if (!parentRow) throw new ApiError(400, 'invalid_parent', 'parent_message_id 不属于该会话');
    }
    if (regenerate && parentRow && parentRow.role !== 'user') {
      throw new ApiError(400, 'invalid_parent', '重新生成的 parent_message_id 必须指向用户消息');
    }

    // 1) 落库用户消息(重新生成除外)
    let userMessageId: string | null = null;
    if (!regenerate) {
      userMessageId = randomUUID();
      insertMessage(db, {
        id: userMessageId,
        conversationId: conv.id,
        parentId: parentId ?? null,
        role: 'user',
        blocks: [{ type: 'text', text: userContent }],
      });
    }

    const assistantParentId = regenerate ? (parentId ?? null) : userMessageId;
    const contextRows = activePath(allMessages(db, conv.id), assistantParentId);
    const messages: ChatMessage[] = contextRows
      .filter((row) => row.role === 'user' || row.role === 'assistant')
      .map((row) => ({ role: row.role as 'user' | 'assistant', content: blocksToText(row.blocks_json) }));

    // 2) 开流
    reply.hijack();
    const raw = reply.raw;
    raw.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    });

    const assistantId = randomUUID();
    const controller = new AbortController();
    activeGenerations.set(conv.id, controller);

    let finished = false;
    raw.on('close', () => {
      if (!finished) controller.abort();
    });

    const writeEvent = (event: DpappEvent): void => {
      if (raw.writableEnded) return;
      raw.write(encodeSse(event));
    };

    // 心跳注释行:避免思考阶段长时间无字节被中间层判定空闲超时
    const heartbeat = setInterval(() => {
      if (!raw.writableEnded) raw.write(': ping\n\n');
    }, 15_000);
    heartbeat.unref();

    const finish = (): void => {
      clearInterval(heartbeat);
      activeGenerations.delete(conv.id);
      finished = true;
      if (!raw.writableEnded) raw.end();
    };

    writeEvent({ type: 'message_start', message_id: assistantId, model: config.model });

    let result;
    try {
      result = await runAgentTurn({ config, messages, signal: controller.signal, emit: writeEvent });
    } catch (error) {
      app.log.error({ err: error }, 'agent turn failed');
      writeEvent({ type: 'error', code: 'upstream_error', message: '模型服务暂时不可用,请稍后重试' });
      finish();
      return reply;
    }

    // 3) 一次性落库助手消息 + 用量,再发 message_end。
    // 收尾放在 finally:生成期间会话被删除时(落库会撞外键约束)也不能漏掉 finish,否则 SSE 连接悬着。
    try {
      const stillExists = db.prepare('SELECT 1 AS ok FROM conversation WHERE id = ?').get(conv.id);
      if (!stillExists) {
        writeEvent({
          type: 'error',
          code: 'conversation_deleted',
          message: '会话已被删除,本轮回答不再保存',
        });
      } else {
        const hasContent = result.text !== '' || result.thinking !== '';
        if (hasContent) {
          insertMessage(db, {
            id: assistantId,
            conversationId: conv.id,
            parentId: assistantParentId,
            role: 'assistant',
            blocks: [{ type: 'text', text: result.text }],
            thinking: result.thinking,
            tokensIn: result.tokensIn,
            tokensOut: result.tokensOut,
            cost: result.cost,
            stopReason: result.stopReason,
          });
          db.prepare(
            'UPDATE conversation SET active_leaf_id = ?, updated_at = ? WHERE id = ?',
          ).run(assistantId, nowIso(), conv.id);
        }

        if (userMessageId !== null && conv.title.trim() === '') {
          db.prepare('UPDATE conversation SET title = ? WHERE id = ?').run(
            userContent.replace(/\s+/g, ' ').slice(0, 30),
            conv.id,
          );
        }

        // 中断在拿到 usage 之前发生时不会有 token 数,这种空账不记
        if (result.tokensIn + result.tokensOut > 0) {
          db.prepare(
            `INSERT INTO usage_log (id, ts, kind, quantity, cost, tokens_in, tokens_out, conversation_id, message_id)
             VALUES (?, ?, 'model', ?, ?, ?, ?, ?, ?)`,
          ).run(
            randomUUID(),
            nowIso(),
            result.tokensIn + result.tokensOut,
            result.cost,
            result.tokensIn,
            result.tokensOut,
            conv.id,
            hasContent ? assistantId : null,
          );
        }

        writeEvent({
          type: 'message_end',
          usage: { tokens_in: result.tokensIn, tokens_out: result.tokensOut },
          cost_estimate: Number(result.cost.toFixed(6)),
          stop_reason: DONE_EVENT_TYPES.has(result.stopReason)
            ? (result.stopReason as 'end_turn' | 'interrupted' | 'error')
            : 'end_turn',
        });
      }
    } catch (error) {
      app.log.error({ err: error }, '回答落库失败');
      writeEvent({ type: 'error', code: 'persist_failed', message: '回答保存失败' });
    } finally {
      finish();
    }
    return reply;
  });
}

// ---------- 存储辅助 ----------

interface InsertMessageParams {
  id: string;
  conversationId: string;
  parentId: string | null;
  role: MessageRow['role'];
  blocks: unknown;
  thinking?: string;
  citations?: unknown;
  toolTraces?: unknown;
  tokensIn?: number;
  tokensOut?: number;
  cost?: number;
  stopReason?: string | null;
}

function insertMessage(db: Db, params: InsertMessageParams): void {
  db.prepare(
    `INSERT INTO message
       (id, conversation_id, parent_id, role, blocks_json, thinking, citations_json,
        tool_traces_json, tokens_in, tokens_out, cost, stop_reason, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    params.id,
    params.conversationId,
    params.parentId,
    params.role,
    JSON.stringify(params.blocks),
    params.thinking ?? '',
    JSON.stringify(params.citations ?? []),
    JSON.stringify(params.toolTraces ?? []),
    params.tokensIn ?? 0,
    params.tokensOut ?? 0,
    params.cost ?? 0,
    params.stopReason ?? null,
    nowIso(),
  );
}

function getConversationOrThrow(db: Db, id: string): ConversationRow {
  const row = db.prepare('SELECT * FROM conversation WHERE id = ?').get(id) as
    | ConversationRow
    | undefined;
  if (!row) throw new ApiError(404, 'conversation_not_found', '会话不存在');
  return row;
}

function getMessage(db: Db, conversationId: string, messageId: string): MessageRow | undefined {
  return db
    .prepare('SELECT * FROM message WHERE id = ? AND conversation_id = ?')
    .get(messageId, conversationId) as MessageRow | undefined;
}

function allMessages(db: Db, conversationId: string): MessageRow[] {
  return db
    .prepare('SELECT * FROM message WHERE conversation_id = ? ORDER BY created_at ASC')
    .all(conversationId) as MessageRow[];
}

function parseJson<T>(raw: string, fallback: T): T {
  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

function blocksToText(blocksJson: string): string {
  const blocks = parseJson<Array<{ type?: string; text?: string }>>(blocksJson, []);
  return blocks
    .filter((block) => block.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text ?? '')
    .join('');
}

/** 从叶子沿 parent 回溯,得到根→叶的展示路径。 */
function activePath(rows: MessageRow[], leafId: string | null): MessageRow[] {
  if (leafId === null) return [];
  const byId = new Map(rows.map((row) => [row.id, row]));
  const path: MessageRow[] = [];
  const seen = new Set<string>();
  let current = byId.get(leafId);
  while (current && !seen.has(current.id)) {
    seen.add(current.id);
    path.push(current);
    current = current.parent_id === null ? undefined : byId.get(current.parent_id);
  }
  return path.reverse();
}

function buildTree(rows: MessageRow[]): TreeNode[] {
  const nodes = new Map<string, TreeNode>();
  for (const row of rows) {
    nodes.set(row.id, {
      id: row.id,
      parent_id: row.parent_id,
      role: row.role,
      blocks: parseJson(row.blocks_json, []),
      thinking: row.thinking,
      citations: parseJson(row.citations_json, []),
      tool_traces: parseJson(row.tool_traces_json, []),
      usage: { tokens_in: row.tokens_in, tokens_out: row.tokens_out, cost: row.cost },
      stop_reason: row.stop_reason,
      created_at: row.created_at,
      children: [],
    });
  }
  const roots: TreeNode[] = [];
  for (const node of nodes.values()) {
    if (node.parent_id === null) roots.push(node);
    else nodes.get(node.parent_id)?.children.push(node);
  }
  return roots;
}

function previewOf(rows: MessageRow[], leafId: string | null): string {
  const path = activePath(rows, leafId);
  for (let i = path.length - 1; i >= 0; i--) {
    const text = blocksToText(path[i].blocks_json).replace(/\s+/g, ' ').trim();
    if (text !== '') return text.length > 80 ? `${text.slice(0, 80)}…` : text;
  }
  return '';
}

function toConversation(row: ConversationRow) {
  return {
    id: row.id,
    title: row.title,
    pinned: row.pinned === 1,
    ephemeral: row.ephemeral === 1,
    active_leaf_id: row.active_leaf_id,
    settings: parseJson<Record<string, unknown>>(row.settings_json, {}),
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}
