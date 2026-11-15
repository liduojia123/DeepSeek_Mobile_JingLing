import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { ApiError } from '../auth.js';
import type { Db } from '../db.js';

const QuerySchema = z.object({
  query: z.string().max(200).optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50),
});

interface MemoryRow {
  id: string;
  content: string;
  tags: string;
  created_at: string;
  updated_at: string;
}

const toDto = (row: MemoryRow) => ({
  id: row.id,
  content: row.content,
  tags: JSON.parse(row.tags) as string[],
  created_at: row.created_at,
  updated_at: row.updated_at,
});

/**
 * M5 记忆管理接口(v1.5 G2 的 UI 依赖它):列出/搜索/删除 memory 工具沉淀的记忆。
 * 与手机端「记忆」页对应,让用户对「AI 记住了什么」可见、可控。
 */
export function registerMemoryRoutes(app: FastifyInstance, ctx: { db: Db }): void {
  const { db } = ctx;

  app.get('/v1/memories', async (request) => {
    const parsed = QuerySchema.safeParse(request.query);
    if (!parsed.success) throw new ApiError(400, 'validation_error', '查询参数不合法');
    const { query, limit } = parsed.data;
    const like = query === undefined || query.trim() === '' ? null : `%${query.trim()}%`;
    const rows = (
      like === null
        ? db
            .prepare('SELECT id, content, tags, created_at, updated_at FROM memory_note ORDER BY updated_at DESC LIMIT ?')
            .all(limit)
        : db
            .prepare(
              'SELECT id, content, tags, created_at, updated_at FROM memory_note WHERE content LIKE ? OR tags LIKE ? ORDER BY updated_at DESC LIMIT ?',
            )
            .all(like, like, limit)
    ) as MemoryRow[];
    const total = (db.prepare('SELECT COUNT(*) AS n FROM memory_note').get() as { n: number }).n;
    return { total, items: rows.map(toDto) };
  });

  app.delete('/v1/memories/:id', async (request) => {
    const { id } = request.params as { id: string };
    const result = db.prepare('DELETE FROM memory_note WHERE id = ?').run(id);
    if (result.changes === 0) throw new ApiError(404, 'memory_not_found', '这条记忆不存在或已删除');
    return { ok: true };
  });
}
