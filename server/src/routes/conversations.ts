import { randomUUID } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { runAgentTurn } from '../agent/loop.js';
import { ApiError } from '../auth.js';
import type { Config } from '../config.js';
import { DEV_CORS_HEADERS } from '../cors.js';
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
  server_blocks_json: string;
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
  /** M2:已上传文件的 id 列表(服务端自己的 file.id),会作为 file 块一起发给模型 */
  file_ids: z.array(z.string().min(1)).max(20).optional(),
  /** 本次请求是否联网搜索(缺省=启用) */
  search: z.boolean().optional(),
  /** 本次请求是否深度思考(缺省=启用) */
  thinking: z.boolean().optional(),
});

const ListQuery = z.object({
  include_ephemeral: z.enum(['0', '1']).optional(),
});

/**
 * 进行中的生成登记表。stop 端点、客户端断连、会话删除、进程关停都通过它中止,
 * 保证每个 SSE 连接最终都会 finish(否则连接与 AbortController 永久泄漏)。
 */
export class GenerationRegistry {
  private readonly active = new Map<string, AbortController>();

  has(conversationId: string): boolean {
    return this.active.has(conversationId);
  }

  add(conversationId: string, controller: AbortController): void {
    this.active.set(conversationId, controller);
  }

  remove(conversationId: string): void {
    this.active.delete(conversationId);
  }

  abort(conversationId: string): void {
    this.active.get(conversationId)?.abort();
  }

  abortAll(): void {
    for (const controller of this.active.values()) controller.abort();
  }
}

export function registerConversationRoutes(
  app: FastifyInstance,
  ctx: { db: Db; config: Config },
  registry: GenerationRegistry,
): void {
  const { db, config } = ctx;

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
    registry.abort(id);
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
    if (!registry.has(id)) throw new ApiError(409, 'not_generating', '当前没有进行中的生成');
    registry.abort(id);
    return { stopped: true };
  });

  /**
   * 删除一条消息及其整个子树(分支点删除 = 丢弃该分支)。
   * 若被删子树包含 active_leaf_id,活跃叶子回退到被删节点的父节点。
   */
  app.delete('/v1/conversations/:id/messages/:messageId', async (request, reply) => {
    const { id, messageId } = request.params as { id: string; messageId: string };
    const conv = getConversationOrThrow(db, id);
    const target = getMessage(db, conv.id, messageId);
    if (!target) throw new ApiError(404, 'message_not_found', '消息不存在');
    if (registry.has(conv.id)) {
      throw new ApiError(409, 'generation_in_progress', '生成中不能删除消息,请先停止');
    }

    db.transaction(() => {
      const ids = collectSubtree(db, conv.id, messageId);
      const remove = db.prepare('DELETE FROM message WHERE id = ?');
      for (const mid of ids) remove.run(mid);

      const leafLost =
        conv.active_leaf_id !== null && ids.some((mid) => mid === conv.active_leaf_id);
      db.prepare(
        `UPDATE conversation SET active_leaf_id = ?, updated_at = ? WHERE id = ?`,
      ).run(leafLost ? target.parent_id : conv.active_leaf_id, nowIso(), conv.id);
    })();

    return reply.code(204).send();
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

    if (registry.has(conv.id)) {
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

    // 1) 落库用户消息(重新生成除外)。附件以 file 块存进 blocks_json,
    //    同时把 provider_file_id 一起记下,组装上下文时不用再查库。
    let userMessageId: string | null = null;
    const attachedFiles = regenerate ? [] : attachFiles(db, body.file_ids ?? []);
    if (!regenerate) {
      userMessageId = randomUUID();
      insertMessage(db, {
        id: userMessageId,
        conversationId: conv.id,
        parentId: parentId ?? null,
        role: 'user',
        blocks: [
          ...attachedFiles.map((file) => ({
            type: 'file',
            file_id: file.id,
            provider_file_id: file.provider_file_id,
            name: file.name,
          })),
          { type: 'text', text: userContent },
        ],
      });
    }

    const assistantParentId = regenerate ? (parentId ?? null) : userMessageId;
    const contextRows = activePath(allMessages(db, conv.id), assistantParentId);
    const messages: ChatMessage[] = buildChatMessages(contextRows);

    // 2) 开流
    reply.hijack();
    const raw = reply.raw;
    raw.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
      // hijack 之后 Fastify 的 CORS 钩子头不会再被写入,开发期必须自己带上
      ...(config.devCors ? DEV_CORS_HEADERS : {}),
    });

    const assistantId = randomUUID();
    const controller = new AbortController();
    registry.add(conv.id, controller);

    let finished = false;
    raw.on('close', () => {
      if (!finished) controller.abort();
    });
    raw.on('error', () => {
      if (!finished) controller.abort();
    });

    const writeEvent = (event: DpappEvent): void => {
      if (raw.destroyed || raw.writableEnded) return;
      raw.write(encodeSse(event));
    };

    // 心跳注释行:避免思考阶段长时间无字节被中间层判定空闲超时
    const heartbeat = setInterval(() => {
      if (!raw.destroyed && !raw.writableEnded) raw.write(': ping\n\n');
    }, 15_000);
    heartbeat.unref();

    const finish = (): void => {
      clearInterval(heartbeat);
      registry.remove(conv.id);
      finished = true;
      if (!raw.writableEnded) raw.end();
    };

    writeEvent({
      type: 'message_start',
      message_id: assistantId,
      user_message_id: userMessageId,
      model: config.model,
    });
    for (const file of attachedFiles) {
      writeEvent({ type: 'file_attached', file_id: file.id, name: file.name, status: 'parsed' });
    }

    let result: Awaited<ReturnType<typeof runAgentTurn>>;
    try {
      result = await runAgentTurn({
        config,
        messages,
        signal: controller.signal,
        emit: writeEvent,
        search: body.search,
        thinking: body.thinking,
      });
    } catch (error) {
      app.log.error({ err: error }, 'agent turn failed');
      result = {
        thinking: '',
        text: '',
        tokensIn: 0,
        tokensOut: 0,
        tokensCached: 0,
        searchCalls: 0,
        fetchCalls: 0,
        cost: 0,
        stopReason: 'error',
        errorMessage: '模型服务暂时不可用,请稍后重试',
        safetyBlocked: false,
        citations: [],
        toolTraces: [],
        serverBlocks: [],
      };
    }

    // 3) 一次性落库助手消息 + 用量,再发 message_end。
    // 无论有没有内容都落库并推进 active_leaf:否则用户消息会成为不在展示路径上的悬挂节点,
    // 客户端刷新后「消息消失」。收尾放 finally,任何异常都不能漏掉 finish。
    try {
      const stillExists = db.prepare('SELECT 1 AS ok FROM conversation WHERE id = ?').get(conv.id);
      if (!stillExists) {
        writeEvent({
          type: 'error',
          code: 'conversation_deleted',
          message: '会话已被删除,本轮回答不再保存',
        });
      } else {
        if (result.stopReason === 'error') {
          writeEvent({
            type: 'error',
            code: 'upstream_error',
            message: result.errorMessage ?? '模型服务暂时不可用,请稍后重试',
          });
        }
        if (result.safetyBlocked) {
          writeEvent({
            type: 'safety_block',
            reason: result.errorMessage ?? '输入内容未通过安全审核',
          });
        }

        // 回答、active_leaf、标题、用量必须原子写入,否则崩溃会留下不在路径上的孤儿消息
        db.transaction(() => {
          insertMessage(db, {
            id: assistantId,
            conversationId: conv.id,
            parentId: assistantParentId,
            role: 'assistant',
            blocks: [{ type: 'text', text: result.text }],
            thinking: result.thinking,
            citations: result.citations,
            toolTraces: result.toolTraces,
            serverBlocks: result.serverBlocks,
            tokensIn: result.tokensIn,
            tokensOut: result.tokensOut,
            cost: result.cost,
            stopReason: result.stopReason,
          });
          db.prepare('UPDATE conversation SET active_leaf_id = ?, updated_at = ? WHERE id = ?').run(
            assistantId,
            nowIso(),
            conv.id,
          );

          // M2:优先用服务端生成的标题;关掉 title 或没生成时回退到首条消息截断
          const generatedTitle = result.title?.trim();
          if (generatedTitle !== undefined && generatedTitle !== '') {
            db.prepare('UPDATE conversation SET title = ? WHERE id = ? AND title = ?').run(
              generatedTitle.slice(0, 200),
              conv.id,
              '',
            );
          } else if (userMessageId !== null && conv.title.trim() === '') {
            db.prepare('UPDATE conversation SET title = ? WHERE id = ?').run(
              userContent.replace(/\s+/g, ' ').slice(0, 30),
              conv.id,
            );
          }

          if (result.tokensIn + result.tokensOut > 0) {
            db.prepare(
              `INSERT INTO usage_log (id, ts, kind, quantity, cost, tokens_in, tokens_out, conversation_id, message_id)
               VALUES (?, ?, 'model', ?, ?, ?, ?, ?, ?)`,
            ).run(
              randomUUID(),
              nowIso(),
              result.tokensIn + result.tokensOut,
              // 只记 token 费用;搜索/抓取单独按次记账,避免同一笔费用被重复累计
              (result.tokensIn * config.priceInCnyPerMtok + result.tokensOut * config.priceOutCnyPerMtok) / 1_000_000,
              result.tokensIn,
              result.tokensOut,
              conv.id,
              assistantId,
            );
          }

          // M2:工具调用按次计费(搜索/抓取)
          const insertUsage = db.prepare(
            `INSERT INTO usage_log (id, ts, kind, quantity, cost, conversation_id, message_id)
             VALUES (?, ?, ?, ?, ?, ?, ?)`,
          );
          if (result.searchCalls > 0) {
            insertUsage.run(
              randomUUID(),
              nowIso(),
              'search',
              result.searchCalls,
              result.searchCalls * config.searchPriceCnyPerCall,
              conv.id,
              assistantId,
            );
          }
          if (result.fetchCalls > 0) {
            insertUsage.run(
              randomUUID(),
              nowIso(),
              'fetch',
              result.fetchCalls,
              result.fetchCalls * config.fetchPriceCnyPerCall,
              conv.id,
              assistantId,
            );
          }
        })();

        writeEvent({
          type: 'message_end',
          usage: {
            tokens_in: result.tokensIn,
            tokens_out: result.tokensOut,
            tokens_cached: result.tokensCached,
            search_calls: result.searchCalls,
            fetch_calls: result.fetchCalls,
          },
          cost_estimate: Number(result.cost.toFixed(6)),
          stop_reason: result.stopReason,
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
  serverBlocks?: unknown;
  tokensIn?: number;
  tokensOut?: number;
  cost?: number;
  stopReason?: string | null;
}

function insertMessage(db: Db, params: InsertMessageParams): void {
  db.prepare(
    `INSERT INTO message
       (id, conversation_id, parent_id, role, blocks_json, thinking, citations_json,
        tool_traces_json, server_blocks_json, tokens_in, tokens_out, cost, stop_reason, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    params.id,
    params.conversationId,
    params.parentId,
    params.role,
    JSON.stringify(params.blocks),
    params.thinking ?? '',
    JSON.stringify(params.citations ?? []),
    JSON.stringify(params.toolTraces ?? []),
    JSON.stringify(params.serverBlocks ?? []),
    params.tokensIn ?? 0,
    params.tokensOut ?? 0,
    params.cost ?? 0,
    params.stopReason ?? null,
    nowIso(),
  );
}

interface AttachedFile {
  id: string;
  provider_file_id: string;
  name: string;
}

/** 校验并解析 file_ids:必须是我们库里已解析成功的文件。 */
function attachFiles(db: Db, fileIds: string[]): AttachedFile[] {
  if (fileIds.length === 0) return [];
  const lookup = db.prepare('SELECT id, provider_file_id, name, parse_status FROM file WHERE id = ?');
  const attached: AttachedFile[] = [];
  for (const id of fileIds) {
    const row = lookup.get(id) as
      | { id: string; provider_file_id: string; name: string; parse_status: string }
      | undefined;
    if (!row) throw new ApiError(400, 'invalid_file', `文件不存在: ${id}`);
    if (row.parse_status !== 'parsed') {
      throw new ApiError(400, 'file_not_ready', `文件尚未解析完成: ${row.name}`);
    }
    attached.push({ id: row.id, provider_file_id: row.provider_file_id, name: row.name });
  }
  return attached;
}

/**
 * 把消息树路径装配成上游 messages。
 * M2 三件事:用户消息里的 file 块转成 {type:"file",file_id};assistant 的 server_tool_calls 原样回传
 * (阅读链接的网页靠它拼回上下文);空正文助手消息跳过。
 */
function buildChatMessages(rows: MessageRow[]): ChatMessage[] {
  const messages: ChatMessage[] = [];
  for (const row of rows) {
    if (row.role !== 'user' && row.role !== 'assistant') continue;
    const blocks = parseJson<Array<{ type?: string; text?: string; provider_file_id?: string }>>(
      row.blocks_json,
      [],
    );
    const text = blocks
      .filter((block) => block.type === 'text')
      .map((block) => block.text ?? '')
      .join('');
    const files = blocks.filter(
      (block) => block.type === 'file' && typeof block.provider_file_id === 'string',
    );

    if (row.role === 'assistant') {
      if (text === '') continue;
      const message: ChatMessage = { role: 'assistant', content: text };
      const serverBlocks = parseJson<unknown[]>(row.server_blocks_json, []);
      if (serverBlocks.length > 0) message.server_tool_calls = serverBlocks;
      messages.push(message);
      continue;
    }

    if (files.length > 0) {
      messages.push({
        role: 'user',
        content: [
          ...files.map((file) => ({ type: 'file', file_id: file.provider_file_id as string })),
          { type: 'text', text },
        ],
      });
      continue;
    }
    if (text !== '') messages.push({ role: 'user', content: text });
  }
  return messages;
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
    .prepare(
      // rowid 作次级键:同一毫秒创建的兄弟分支排序才不会跳动
      'SELECT * FROM message WHERE conversation_id = ? ORDER BY created_at ASC, rowid ASC',
    )
    .all(conversationId) as MessageRow[];
}

/** 删除分支点时要连同整棵子树一起删,这里收集含自身在内的全部后代 id。 */
function collectSubtree(db: Db, conversationId: string, rootId: string): string[] {
  const childrenOf = new Map<string, string[]>();
  for (const row of allMessages(db, conversationId)) {
    if (row.parent_id === null) continue;
    const siblings = childrenOf.get(row.parent_id) ?? [];
    siblings.push(row.id);
    childrenOf.set(row.parent_id, siblings);
  }
  const ids: string[] = [];
  const stack: string[] = [rootId];
  while (stack.length > 0) {
    const current = stack.pop();
    if (current === undefined) break;
    ids.push(current);
    stack.push(...(childrenOf.get(current) ?? []));
  }
  return ids;
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

/** 从叶子沿 parent 回溯,得到根→叶的展示路径。 */function activePath(rows: MessageRow[], leafId: string | null): MessageRow[] {
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
