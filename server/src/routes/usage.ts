import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { ApiError } from '../auth.js';
import type { Config } from '../config.js';
import type { Db } from '../db.js';

const QuerySchema = z.object({
  days: z.coerce.number().int().min(1).max(365).default(30),
  conversation_id: z.string().min(1).optional(),
});

interface UsageRow {
  date: string;
  tokens_in: number;
  tokens_out: number;
  cost: number;
  calls: number;
}

/**
 * 用量统计:按天汇总 token 与费用(F9 的 M0 阶段)。
 * ts 以 UTC ISO 存储,这里按 UTC 日期分桶;客户端展示时可不再转换。
 */
export function registerUsageRoutes(app: FastifyInstance, ctx: { db: Db; config: Config }): void {
  const { db, config } = ctx;

  app.get('/v1/usage', async (request) => {
    const parsed = QuerySchema.safeParse(request.query);
    if (!parsed.success) {
      throw new ApiError(400, 'validation_error', '查询参数 days 需为 1..365 的整数');
    }
    const { days, conversation_id: conversationId } = parsed.data;

    const since = new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
    const params: unknown[] = [since];
    let where = 'ts >= ?';
    if (conversationId !== undefined) {
      where += ' AND conversation_id = ?';
      params.push(conversationId);
    }

    const rows = db
      .prepare(
        `SELECT substr(ts, 1, 10) AS date,
                SUM(tokens_in)  AS tokens_in,
                SUM(tokens_out) AS tokens_out,
                SUM(cost)       AS cost,
                COUNT(*)        AS calls
           FROM usage_log
          WHERE ${where}
          GROUP BY date
          ORDER BY date ASC`,
      )
      .all(...params) as UsageRow[];

    const totals = rows.reduce(
      (acc, row) => ({
        calls: acc.calls + row.calls,
        tokens_in: acc.tokens_in + row.tokens_in,
        tokens_out: acc.tokens_out + row.tokens_out,
        cost: acc.cost + row.cost,
      }),
      { calls: 0, tokens_in: 0, tokens_out: 0, cost: 0 },
    );

    // M2:按 kind(模型/搜索/抓取/OCR…)拆开,便于核对工具调用费用
    const byKindRows = db
      .prepare(
        `SELECT kind, COUNT(*) AS calls, SUM(quantity) AS quantity, SUM(cost) AS cost
           FROM usage_log
          WHERE ${where}
          GROUP BY kind
          ORDER BY kind ASC`,
      )
      .all(...params) as Array<{ kind: string; calls: number; quantity: number; cost: number }>;

    return {
      days: rows.map((row) => ({
        date: row.date,
        calls: row.calls,
        tokens_in: row.tokens_in,
        tokens_out: row.tokens_out,
        cost: Number(row.cost.toFixed(6)),
      })),
      totals: { ...totals, cost: Number(totals.cost.toFixed(6)) },
      by_kind: byKindRows.map((row) => ({
        kind: row.kind,
        calls: row.calls,
        quantity: row.quantity,
        cost: Number(row.cost.toFixed(6)),
      })),
      // 预算字段 M5 启用熔断,M0 只回显配置值
      budget: { daily_cny: config.dailyBudgetCny },
    };
  });
}
