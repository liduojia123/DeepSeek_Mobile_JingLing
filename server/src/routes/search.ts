import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { ApiError } from '../auth.js';
import type { Db } from '../db.js';
import { activePath, blocksToText, type MessageRow } from './conversations.js';

const SearchQuery = z.object({
  q: z.string().max(200).optional(),
  limit: z.coerce.number().int().min(1).max(50).default(20),
});

/** 每个会话组最多返回几条正文命中(标题命中恒 1 条,不占这个额度)。 */
const HITS_PER_GROUP = 5;
/** snippet 窗口:命中前后各留多少字符。 */
const SNIPPET_CONTEXT = 32;

interface ConversationBrief {
  id: string;
  title: string;
  pinned: number;
  active_leaf_id: string | null;
  updated_at: string;
}

interface SearchHit {
  message_id: string | null;
  field: 'title' | 'message';
  role: 'user' | 'assistant' | 'system' | null;
  created_at: string;
  snippet: string;
}

/** 命中处开 ±SNIPPET_CONTEXT 的纯文本窗口;高亮记号由客户端按关键词自己做,服务端只给纯文本。 */
export function snippetAround(text: string, index: number, needleLength: number): string {
  const start = Math.max(0, index - SNIPPET_CONTEXT);
  const end = Math.min(text.length, index + needleLength + SNIPPET_CONTEXT);
  return `${start > 0 ? '…' : ''}${text.slice(start, end)}${end < text.length ? '…' : ''}`;
}

/**
 * 全局搜索(HANDOFF-SEARCH):搜会话标题 + 活跃路径消息正文,按会话分组返回。
 * 全表扫描 + JS 匹配(个人量级与列表 preview 同一性能口径;SQL LIKE 会被 JSON 转义坑到,
 * 且 "%_\" 等关键词行为不可预期,所以不走 LIKE)。量大后再上 search_text 列或 FTS5。
 */
export function registerSearchRoutes(app: FastifyInstance, ctx: { db: Db }): void {
  const { db } = ctx;

  app.get('/v1/search', async (request) => {
    const parsed = SearchQuery.safeParse(request.query);
    if (!parsed.success) throw new ApiError(400, 'validation_error', '查询参数不合法');
    const q = (parsed.data.q ?? '').trim();
    if (q.length === 0 || q.length > 100) {
      throw new ApiError(400, 'validation_error', 'q 必须是 1-100 个字符');
    }
    const limit = parsed.data.limit;
    const needle = q.toLowerCase();

    const conversations = db
      .prepare('SELECT id, title, pinned, active_leaf_id, updated_at FROM conversation WHERE ephemeral = 0')
      .all() as ConversationBrief[];
    const messages = db
      .prepare('SELECT * FROM message ORDER BY created_at ASC, rowid ASC')
      .all() as MessageRow[];
    const byConversation = new Map<string, MessageRow[]>();
    for (const row of messages) {
      const bucket = byConversation.get(row.conversation_id);
      if (bucket === undefined) byConversation.set(row.conversation_id, [row]);
      else bucket.push(row);
    }

    const groups: Array<{ conversation: object; hits: SearchHit[]; sortKey: string }> = [];
    for (const conv of conversations) {
      const hits: SearchHit[] = [];
      if (conv.title.toLowerCase().includes(needle)) {
        hits.push({
          message_id: null,
          field: 'title',
          role: null,
          created_at: conv.updated_at,
          snippet: '',
        });
      }

      const bodyHits: Array<{ row: MessageRow; snippet: string }> = [];
      for (const row of activePath(byConversation.get(conv.id) ?? [], conv.active_leaf_id)) {
        const text = blocksToText(row.blocks_json).replace(/\s+/g, ' ').trim();
        const index = text.toLowerCase().indexOf(needle);
        if (index >= 0) bodyHits.push({ row, snippet: snippetAround(text, index, q.length) });
      }
      bodyHits.sort((a, b) => b.row.created_at.localeCompare(a.row.created_at));
      for (const hit of bodyHits.slice(0, HITS_PER_GROUP)) {
        hits.push({
          message_id: hit.row.id,
          field: 'message',
          role: hit.row.role,
          created_at: hit.row.created_at,
          snippet: hit.snippet,
        });
      }

      if (hits.length === 0) continue;
      groups.push({
        conversation: {
          id: conv.id,
          title: conv.title,
          pinned: conv.pinned === 1,
          updated_at: conv.updated_at,
        },
        hits,
        sortKey: hits.reduce((latest, hit) => (hit.created_at > latest ? hit.created_at : latest), ''),
      });
    }

    groups.sort((a, b) => b.sortKey.localeCompare(a.sortKey));
    return {
      query: q,
      groups: groups.slice(0, limit).map((group) => ({ conversation: group.conversation, hits: group.hits })),
    };
  });
}
