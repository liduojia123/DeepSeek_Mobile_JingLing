import assert from 'node:assert/strict';
import test from 'node:test';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/index.js';
import { loadConfig, type Config } from '../src/config.js';
import { openDb, type Db } from '../src/db.js';
import { snippetAround } from '../src/routes/search.js';

const PAIRING_CODE = 'TESTCODE';

interface Harness {
  app: FastifyInstance;
  db: Db;
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
  return { app, db };
}

async function pair(app: FastifyInstance): Promise<string> {
  const response = await app.inject({
    method: 'POST',
    url: '/v1/pair',
    payload: { code: PAIRING_CODE, device_name: '测试机' },
  });
  return (response.json() as { token: string }).token;
}

const auth = (token: string) => ({ authorization: `Bearer ${token}` });

function insertConversation(
  db: Db,
  id: string,
  options: { title?: string; ephemeral?: boolean; activeLeafId?: string | null; updatedAt?: string } = {},
): void {
  const ts = options.updatedAt ?? new Date().toISOString();
  db.prepare(
    `INSERT INTO conversation (id, title, pinned, ephemeral, active_leaf_id, settings_json, created_at, updated_at)
     VALUES (?, ?, 0, ?, ?, '{}', ?, ?)`,
  ).run(id, options.title ?? '测试会话', options.ephemeral === true ? 1 : 0, options.activeLeafId ?? null, ts, ts);
}

function insertMessage(
  db: Db,
  message: {
    id: string;
    conversationId: string;
    parentId?: string | null;
    role?: 'user' | 'assistant' | 'system';
    text: string;
    createdAt: string;
  },
): void {
  db.prepare(
    `INSERT INTO message (id, conversation_id, parent_id, role, blocks_json, created_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
  ).run(
    message.id,
    message.conversationId,
    message.parentId ?? null,
    message.role ?? 'user',
    JSON.stringify([{ type: 'text', text: message.text }]),
    message.createdAt,
  );
}

async function search(app: FastifyInstance, headers: Record<string, string>, query: string, extra = '') {
  const response = await app.inject({ method: 'GET', url: `/v1/search?q=${encodeURIComponent(query)}${extra}`, headers });
  return response;
}

test('搜索:标题命中只给 title 命中,不带 message_id', async () => {
  const { app, db } = makeHarness();
  insertConversation(db, 'c1', { title: '买菜清单' });
  insertMessage(db, { id: 'm1', conversationId: 'c1', text: '牛奶和鸡蛋', createdAt: '2026-01-01T00:00:00.000Z' });
  const headers = auth(await pair(app));

  const response = await search(app, headers, '买菜');
  assert.equal(response.statusCode, 200);
  const body = response.json() as {
    query: string;
    groups: Array<{ conversation: { id: string }; hits: Array<Record<string, unknown>> }>;
  };
  assert.equal(body.query, '买菜');
  assert.equal(body.groups.length, 1);
  assert.equal(body.groups[0].conversation.id, 'c1');
  assert.equal(body.groups[0].hits.length, 1);
  assert.equal(body.groups[0].hits[0].field, 'title');
  assert.equal(body.groups[0].hits[0].message_id, null);
});

test('搜索:正文命中带 snippet 窗口与消息元数据', async () => {
  const { app, db } = makeHarness();
  insertConversation(db, 'c1', { title: '长文', activeLeafId: 'm1' });
  const text = `${'前'.repeat(50)}鲸灵关键词${'后'.repeat(50)}`;
  insertMessage(db, { id: 'm1', conversationId: 'c1', role: 'assistant', text, createdAt: '2026-01-02T00:00:00.000Z' });
  const headers = auth(await pair(app));

  const body = (await search(app, headers, '鲸灵关键词')).json() as {
    groups: Array<{ hits: Array<{ field: string; message_id: string; role: string; created_at: string; snippet: string }> }>;
  };
  const hit = body.groups[0].hits[0];
  assert.equal(hit.field, 'message');
  assert.equal(hit.message_id, 'm1');
  assert.equal(hit.role, 'assistant');
  assert.equal(hit.created_at, '2026-01-02T00:00:00.000Z');
  assert.ok(hit.snippet.startsWith('…'));
  assert.ok(hit.snippet.endsWith('…'));
  assert.ok(hit.snippet.includes('鲸灵关键词'));
  assert.ok(hit.snippet.length <= 32 * 2 + '鲸灵关键词'.length + 2, `snippet 太长:${hit.snippet.length}`);
});

test('搜索:大小写不敏感,且 SQL LIKE 特殊字符是普通字符', async () => {
  const { app, db } = makeHarness();
  insertConversation(db, 'c1', { title: '折扣', activeLeafId: 'm1' });
  insertMessage(db, { id: 'm1', conversationId: 'c1', text: '今日折扣 50% off "test" _x_ 完', createdAt: '2026-01-03T00:00:00.000Z' });
  const headers = auth(await pair(app));

  const upper = (await search(app, headers, 'OFF')).json() as { groups: unknown[] };
  assert.equal(upper.groups.length, 1);

  const percent = (await search(app, headers, '50%')).json() as { groups: unknown[] };
  assert.equal(percent.groups.length, 1);

  const quote = (await search(app, headers, '"test"')).json() as { groups: unknown[] };
  assert.equal(quote.groups.length, 1);

  const underscore = (await search(app, headers, '_x_')).json() as { groups: unknown[] };
  assert.equal(underscore.groups.length, 1);
});

test('搜索:只搜活跃路径,旧分支正文搜不到', async () => {
  const { app, db } = makeHarness();
  insertConversation(db, 'c1', { title: '分支', activeLeafId: 'm2' });
  insertMessage(db, { id: 'm1', conversationId: 'c1', text: '用户提问', createdAt: '2026-01-01T00:00:00.000Z' });
  insertMessage(db, {
    id: 'm2',
    conversationId: 'c1',
    parentId: 'm1',
    role: 'assistant',
    text: '新版回答里有甲乙丙',
    createdAt: '2026-01-02T00:00:00.000Z',
  });
  insertMessage(db, {
    id: 'm3',
    conversationId: 'c1',
    parentId: 'm1',
    role: 'assistant',
    text: '旧版回答里有丁戊己',
    createdAt: '2026-01-03T00:00:00.000Z',
  });
  const headers = auth(await pair(app));

  const fresh = (await search(app, headers, '甲乙丙')).json() as { groups: Array<{ hits: Array<{ message_id: string }> }> };
  assert.equal(fresh.groups.length, 1);
  assert.equal(fresh.groups[0].hits[0].message_id, 'm2');

  const stale = await search(app, headers, '丁戊己');
  assert.equal((stale.json() as { groups: unknown[] }).groups.length, 0);
});

test('搜索:临时会话不进结果', async () => {
  const { app, db } = makeHarness();
  insertConversation(db, 'c1', { title: '临时的', ephemeral: true, activeLeafId: 'm1' });
  insertMessage(db, { id: 'm1', conversationId: 'c1', text: '临时内容秘密词', createdAt: '2026-01-01T00:00:00.000Z' });
  const headers = auth(await pair(app));

  const body = (await search(app, headers, '秘密词')).json() as { groups: unknown[] };
  assert.equal(body.groups.length, 0);
});

test('搜索:空 q 与缺 q 都是 400', async () => {
  const { app } = makeHarness();
  const headers = auth(await pair(app));
  assert.equal((await search(app, headers, '')).statusCode, 400);
  assert.equal((await search(app, headers, '   ')).statusCode, 400);
  const missing = await app.inject({ method: 'GET', url: '/v1/search', headers });
  assert.equal(missing.statusCode, 400);
});

test('搜索:limit 限制组数,每组正文命中最多 5 条', async () => {
  const { app, db } = makeHarness();
  for (let i = 1; i <= 3; i++) {
    insertConversation(db, `c${i}`, { title: `会话${i}`, activeLeafId: `m${i}-7` });
    for (let j = 1; j <= 7; j++) {
      insertMessage(db, {
        id: `m${i}-${j}`,
        conversationId: `c${i}`,
        parentId: j === 1 ? null : `m${i}-${j - 1}`,
        text: `第${j}条含共同词`,
        createdAt: `2026-01-0${i}T0${j}:00:00.000Z`,
      });
    }
  }
  const headers = auth(await pair(app));

  const limited = (await search(app, headers, '共同词', '&limit=2')).json() as {
    groups: Array<{ hits: unknown[] }>;
  };
  assert.equal(limited.groups.length, 2);
  assert.equal(limited.groups[0].hits.length, 5, '每组正文命中最多 5 条');
  assert.equal(limited.groups[1].hits.length, 5);

  const all = (await search(app, headers, '共同词')).json() as { groups: Array<{ hits: unknown[] }> };
  assert.equal(all.groups.length, 3);
});

test('搜索:命中正文按时间倒序,组间按最新命中倒序', async () => {
  const { app, db } = makeHarness();
  insertConversation(db, 'c1', { title: '旧会话', activeLeafId: 'm1' });
  insertMessage(db, { id: 'm1', conversationId: 'c1', text: '关键词甲', createdAt: '2026-01-01T00:00:00.000Z' });
  insertConversation(db, 'c2', { title: '新会话', activeLeafId: 'm3' });
  insertMessage(db, { id: 'm2', conversationId: 'c2', text: '关键词乙', createdAt: '2026-02-01T00:00:00.000Z' });
  insertMessage(db, { id: 'm3', conversationId: 'c2', parentId: 'm2', text: '关键词丙', createdAt: '2026-03-01T00:00:00.000Z' });
  const headers = auth(await pair(app));

  const body = (await search(app, headers, '关键词')).json() as {
    groups: Array<{ conversation: { id: string }; hits: Array<{ message_id: string }> }>;
  };
  assert.deepEqual(
    body.groups.map((group) => group.conversation.id),
    ['c2', 'c1'],
  );
  assert.deepEqual(
    body.groups[0].hits.map((hit) => hit.message_id),
    ['m3', 'm2'],
  );
});

test('snippetAround:窗口与省略号', () => {
  const text = 'a'.repeat(100);
  const middle = snippetAround(text, 50, 2);
  assert.ok(middle.startsWith('…') && middle.endsWith('…'));
  assert.equal(middle.length, 2 + 32 + 2 + 32);
  assert.equal(snippetAround(text, 0, 2), `${text.slice(0, 34)}…`);
  assert.equal(snippetAround(text, 98, 2), `…${text.slice(66)}`);
});
