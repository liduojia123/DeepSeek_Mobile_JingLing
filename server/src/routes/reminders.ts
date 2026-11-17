import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { ApiError } from '../auth.js';
import type { Db } from '../db.js';
import { nowIso } from '../db.js';

const ListQuery = z.object({
  status: z.enum(['active']).optional(),
});

const AckBody = z.object({
  status: z.enum(['scheduled', 'cancelled', 'fired']),
  native_alarm_id: z.string().max(100).optional(),
  /** 稍后提醒时手机回写的新时间(ISO8601) */
  fire_at: z.string().optional(),
});

interface ReminderRow {
  id: string;
  conversation_id: string | null;
  text: string;
  fire_at: string;
  status: string;
  native_alarm_id: string | null;
  created_at: string;
}

const toDto = (row: ReminderRow) => ({
  id: row.id,
  text: row.text,
  fire_at: row.fire_at,
  status: row.status,
  conversation_id: row.conversation_id,
  native_alarm_id: row.native_alarm_id,
});

/**
 * M7 提醒接口。
 *
 * 服务端只是"记住这件事",真正响的是手机本地闹钟,所以:
 *  - GET 返回 pending(还没排进手机)和未来的 scheduled(排过但可能被强停清掉),
 *    同 id 重排是幂等的,所以手机可以无脑重发;
 *  - ack 由手机回传,支持带 fire_at 回写(稍后提醒)。
 */
export function registerReminderRoutes(app: FastifyInstance, ctx: { db: Db }): void {
  const { db } = ctx;

  app.get('/v1/reminders', async (request) => {
    const parsed = ListQuery.safeParse(request.query);
    if (!parsed.success) throw new ApiError(400, 'validation_error', 'status 只支持 active');
    const now = nowIso();
    const rows = db
      .prepare(
        `SELECT id, conversation_id, text, fire_at, status, native_alarm_id, created_at
           FROM reminder
          WHERE status IN ('pending','scheduled') AND fire_at > ?
          ORDER BY fire_at ASC`,
      )
      .all(now) as ReminderRow[];
    return { reminders: rows.map(toDto) };
  });

  app.post('/v1/reminders/:id/ack', async (request) => {
    const { id } = request.params as { id: string };
    const parsed = AckBody.safeParse(request.body ?? {});
    if (!parsed.success) throw new ApiError(400, 'validation_error', '请求体需要 {status}');
    const { status, native_alarm_id: nativeAlarmId, fire_at: fireAt } = parsed.data;

    const row = db.prepare('SELECT id FROM reminder WHERE id = ?').get(id) as { id: string } | undefined;
    if (row === undefined) throw new ApiError(404, 'reminder_not_found', '这条提醒不存在');

    let nextFireAt: string | null = null;
    if (fireAt !== undefined) {
      const ms = Date.parse(fireAt);
      if (!Number.isFinite(ms)) throw new ApiError(400, 'validation_error', 'fire_at 不是合法时间');
      nextFireAt = new Date(ms).toISOString();
    }

    db.prepare(
      `UPDATE reminder
          SET status = ?,
              native_alarm_id = COALESCE(?, native_alarm_id),
              fire_at = COALESCE(?, fire_at)
        WHERE id = ?`,
    ).run(status, nativeAlarmId ?? null, nextFireAt, id);

    return { ok: true };
  });
}
