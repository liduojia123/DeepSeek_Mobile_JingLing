import assert from 'node:assert/strict';
import test from 'node:test';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/index.js';
import { loadConfig, type Config } from '../src/config.js';
import { openDb, type Db } from '../src/db.js';
import { clientToolSpecs, executeClientTool } from '../src/agent/tools.js';
import type { DpappEvent } from '../src/deepseek/events.js';
import { formatShanghai, nowShanghaiIso, timeContextLine } from '../src/time.js';

const PAIRING_CODE = 'TESTCODE';

interface Harness {
  app: FastifyInstance;
  db: Db;
  config: Config;
}

function makeHarness(): Harness {
  const config: Config = {
    ...loadConfig({ MOCK: '1', PAIRING_CODE } as unknown as NodeJS.ProcessEnv),
    pairingCodeFixed: false,
    mockDelayMs: 0,
    logRequests: false,
  };
  const db = openDb(':memory:');
  const app = buildApp({ config, db });
  return { app, db, config };
}

function insertConversation(db: Db, id: string): void {
  const ts = new Date().toISOString();
  db.prepare(
    `INSERT INTO conversation (id, title, pinned, ephemeral, active_leaf_id, settings_json, created_at, updated_at)
     VALUES (?, '测试会话', 0, 0, NULL, '{}', ?, ?)`,
  ).run(id, ts, ts);
}

const inMinutes = (minutes: number): string => new Date(Date.now() + minutes * 60_000).toISOString();

async function createReminder(
  config: Config,
  db: Db,
  fireAt: string,
  conversationId = 'c1',
): Promise<{ ok: boolean; content: string; emitted: DpappEvent[] }> {
  const emitted: DpappEvent[] = [];
  const result = await executeClientTool(
    config,
    db,
    {
      id: 'call-create',
      name: 'reminder_create',
      arguments: JSON.stringify({ text: '关火', fire_at: fireAt }),
    },
    { emit: (event) => emitted.push(event), conversationId },
  );
  return { ok: result.ok, content: result.content, emitted };
}

test('M7 reminder_create:落库 + 推 reminder 事件,时间按 UTC 存', async () => {
  const { db, config } = makeHarness();
  insertConversation(db, 'c1');
  const fireAt = inMinutes(30);

  const { ok, content, emitted } = await createReminder(config, db, fireAt);
  assert.equal(ok, true, content);
  assert.equal(emitted.length, 1);
  const event = emitted[0] as Extract<DpappEvent, { type: 'reminder' }>;
  assert.equal(event.type, 'reminder');
  assert.equal(event.text, '关火');
  assert.equal(event.fire_at, new Date(Date.parse(fireAt)).toISOString());

  const row = db.prepare('SELECT text, fire_at, status, conversation_id FROM reminder').get() as {
    text: string;
    fire_at: string;
    status: string;
    conversation_id: string;
  };
  assert.equal(row.text, '关火');
  assert.equal(row.status, 'pending');
  assert.equal(row.conversation_id, 'c1');
  assert.equal(row.fire_at, new Date(Date.parse(fireAt)).toISOString());
});

test('M7 reminder_create:过去时间、缺偏移都被拒且不落库', async () => {
  const { db, config } = makeHarness();
  insertConversation(db, 'c1');

  const past = await createReminder(config, db, inMinutes(-5));
  assert.equal(past.ok, false);
  assert.match(past.content, /已经过去|太近/);
  assert.equal(past.emitted.length, 0);

  const noOffset = await createReminder(config, db, '2026-11-18T08:00:00');
  assert.equal(noOffset.ok, false);
  assert.match(noOffset.content, /时区偏移/);

  const count = (db.prepare('SELECT COUNT(*) AS n FROM reminder').get() as { n: number }).n;
  assert.equal(count, 0);
});

test('M7 reminder_create:同会话同文本同时刻不重复建、不重复推', async () => {
  const { db, config } = makeHarness();
  insertConversation(db, 'c1');
  const fireAt = inMinutes(20);

  const first = await createReminder(config, db, fireAt);
  const second = await createReminder(config, db, fireAt);
  assert.equal(first.ok, true);
  assert.equal(second.ok, true);
  assert.match(second.content, /已经设过/);
  assert.equal(second.emitted.length, 0, '重复创建不应再推事件');

  const count = (db.prepare('SELECT COUNT(*) AS n FROM reminder').get() as { n: number }).n;
  assert.equal(count, 1);
});

test('M7 reminder_cancel:置 cancelled + 推 reminder_cancel;重复取消失败', async () => {
  const { db, config } = makeHarness();
  insertConversation(db, 'c1');
  await createReminder(config, db, inMinutes(15));
  const id = (db.prepare('SELECT id FROM reminder').get() as { id: string }).id;

  const emitted: DpappEvent[] = [];
  const cancelled = await executeClientTool(
    config,
    db,
    { id: 'call-cancel', name: 'reminder_cancel', arguments: JSON.stringify({ reminder_id: id }) },
    { emit: (event) => emitted.push(event) },
  );
  assert.equal(cancelled.ok, true, cancelled.content);
  assert.equal(emitted.length, 1);
  assert.equal((emitted[0] as { type: string }).type, 'reminder_cancel');
  assert.equal((emitted[0] as { reminder_id: string }).reminder_id, id);

  const again = await executeClientTool(config, db, {
    id: 'call-cancel-2',
    name: 'reminder_cancel',
    arguments: JSON.stringify({ reminder_id: id }),
  });
  assert.equal(again.ok, false);
  assert.match(again.content, /已经取消/);
});

test('M7 reminder_list:只返回还没响的', async () => {
  const { db, config } = makeHarness();
  insertConversation(db, 'c1');
  await createReminder(config, db, inMinutes(10));
  // 直接塞一条已过期的 pending(模拟"手机没排上、时间已过"),list 不应返回
  db.prepare(
    "INSERT INTO reminder (id, conversation_id, text, fire_at, status, created_at) VALUES ('old', 'c1', '过期', ?, 'pending', ?)",
  ).run(new Date(Date.now() - 60_000).toISOString(), new Date().toISOString());

  const result = await executeClientTool(config, db, {
    id: 'call-list',
    name: 'reminder_list',
    arguments: '{}',
  });
  assert.equal(result.ok, true);
  assert.match(result.content, /关火/);
  assert.doesNotMatch(result.content, /过期/);
  assert.match(result.summary, /1 条/);
});

test('M7 路由:GET active 同时返回 pending 与未来的 scheduled,ack 支持回写 fire_at', async () => {
  const { app, db } = makeHarness();
  const pair = await app.inject({
    method: 'POST',
    url: '/v1/pair',
    payload: { code: PAIRING_CODE, device_name: '测试机' },
  });
  assert.equal(pair.statusCode, 201, pair.payload);
  const token = (pair.json() as { token: string }).token;
  const headers = { authorization: `Bearer ${token}` };

  insertConversation(db, 'c1');
  const id = 'r-1';
  const future = inMinutes(45);
  db.prepare(
    "INSERT INTO reminder (id, conversation_id, text, fire_at, status, created_at) VALUES (?, 'c1', '关火', ?, 'scheduled', ?)",
  ).run(id, future, new Date().toISOString());

  const listed = await app.inject({ method: 'GET', url: '/v1/reminders?status=active', headers });
  assert.equal(listed.statusCode, 200, listed.payload);
  const body = listed.json() as { reminders: Array<{ id: string; fire_at: string }> };
  assert.equal(body.reminders.length, 1);
  assert.equal(body.reminders[0]?.id, id);

  // 稍后 10 分钟:手机回写新时间
  const snoozedTo = new Date(Date.parse(future) + 10 * 60_000).toISOString();
  const ack = await app.inject({
    method: 'POST',
    url: `/v1/reminders/${id}/ack`,
    headers,
    payload: { status: 'scheduled', native_alarm_id: '12345', fire_at: snoozedTo },
  });
  assert.equal(ack.statusCode, 200, ack.payload);
  const row = db.prepare('SELECT fire_at, native_alarm_id FROM reminder WHERE id = ?').get(id) as {
    fire_at: string;
    native_alarm_id: string;
  };
  assert.equal(row.fire_at, snoozedTo);
  assert.equal(row.native_alarm_id, '12345');

  const missing = await app.inject({
    method: 'POST',
    url: '/v1/reminders/nope/ack',
    headers,
    payload: { status: 'cancelled' },
  });
  assert.equal(missing.statusCode, 404);
});

test('M7 删除会话后提醒仍在(ON DELETE SET NULL)', async () => {
  const { db, config } = makeHarness();
  insertConversation(db, 'c1');
  await createReminder(config, db, inMinutes(30));

  db.prepare('DELETE FROM conversation WHERE id = ?').run('c1');
  const row = db.prepare('SELECT conversation_id, status FROM reminder').get() as {
    conversation_id: string | null;
    status: string;
  };
  assert.equal(row.conversation_id, null);
  assert.equal(row.status, 'pending');
});

test('M7 时间工具:当前时间带 +08:00,格式化按上海时区', () => {
  const iso = nowShanghaiIso(new Date('2026-11-17T13:26:11Z'));
  assert.equal(iso, '2026-11-17T21:26:11+08:00');
  assert.equal(formatShanghai('2026-11-17T12:30:00Z'), '11-17 20:30');
  assert.match(timeContextLine(new Date('2026-11-17T13:26:11Z')), /^当前时间:2026-11-17T21:26:11\+08:00/);
});

test('M7 工具声明:三个提醒工具都在,且 system 时间消息插在最前面', async () => {
  const { config } = makeHarness();
  const names = clientToolSpecs(config).map((spec) => (spec as { function: { name: string } }).function.name);
  for (const name of ['reminder_create', 'reminder_cancel', 'reminder_list']) {
    assert.ok(names.includes(name), `缺少工具 ${name}`);
  }

  const { buildWorkingMessages } = await import('../src/agent/loop.js');
  const messages = [{ role: 'user' as const, content: '你好' }];
  const withTools = buildWorkingMessages(messages, true);
  assert.equal(withTools.length, 2);
  assert.equal(withTools[0]?.role, 'system');
  assert.match(String(withTools[0]?.content), /^当前时间:/);
  assert.deepEqual(withTools[1], messages[0], '原有消息顺序保持不变');

  const withoutTools = buildWorkingMessages(messages, false);
  assert.deepEqual(withoutTools, messages, '关掉工具时不插 system');
});

