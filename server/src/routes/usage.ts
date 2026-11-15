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

    // M5:今日用量与预算(熔断口径一致:UTC 当天)
    const dayStart = `${new Date().toISOString().slice(0, 10)}T00:00:00.000Z`;
    const todayRow = db
      .prepare(
        `SELECT COALESCE(SUM(cost), 0) AS cost,
                COALESCE(SUM(tokens_in), 0) AS tokens_in,
                COALESCE(SUM(tokens_out), 0) AS tokens_out
           FROM usage_log WHERE ts >= ?`,
      )
      .get(dayStart) as { cost: number; tokens_in: number; tokens_out: number };
    const todayCost = Number(todayRow.cost) || 0;
    const budgetCny = config.dailyBudgetCny;
    const exceeded = budgetCny > 0 && todayCost >= budgetCny;

    // M5:工具调用次数(服务端搜索/阅读 + 客户端 memory/http_request)从消息表统计
    let toolCalls = 0;
    try {
      const row = db
        .prepare(
          `SELECT COALESCE(SUM(json_array_length(tool_traces_json)), 0) AS server_tools,
                  COALESCE(SUM(json_array_length(tool_blocks_json)), 0) AS client_tools
             FROM message`,
        )
        .get() as { server_tools: number; client_tools: number };
      toolCalls = Number(row.server_tools) + Number(row.client_tools);
    } catch {
      toolCalls = 0;
    }

    // M5:按会话 Top 5(费用从高到低)
    const topRows = db
      .prepare(
        `SELECT u.conversation_id AS conversation_id,
                COALESCE(c.title, '') AS title,
                SUM(u.cost) AS cost,
                COUNT(*) AS calls
           FROM usage_log u
           LEFT JOIN conversation c ON c.id = u.conversation_id
          WHERE ${where} AND u.conversation_id IS NOT NULL
          GROUP BY u.conversation_id
          ORDER BY cost DESC
          LIMIT 5`,
      )
      .all(...params) as Array<{ conversation_id: string; title: string; cost: number; calls: number }>;

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
      today: {
        cost: Number(todayCost.toFixed(6)),
        tokens_in: Number(todayRow.tokens_in) || 0,
        tokens_out: Number(todayRow.tokens_out) || 0,
      },
      tool_calls: toolCalls,
      top_conversations: topRows.map((row) => ({
        conversation_id: row.conversation_id,
        title: row.title,
        cost: Number(row.cost.toFixed(6)),
        calls: row.calls,
      })),
      // 预算:M5 起用于熔断,这里同时回显状态供看板展示
      budget: {
        daily_cny: budgetCny,
        used_today: Number(todayCost.toFixed(6)),
        remaining_cny: budgetCny > 0 ? Math.max(0, Number((budgetCny - todayCost).toFixed(6))) : null,
        used_percent: budgetCny > 0 ? Math.min(100, Math.round((todayCost / budgetCny) * 100)) : 0,
        exceeded,
      },
    };
  });
}
