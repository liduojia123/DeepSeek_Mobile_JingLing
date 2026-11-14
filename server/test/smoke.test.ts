import assert from 'node:assert/strict';
import test from 'node:test';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/index.js';
import { loadConfig, type Config } from '../src/config.js';
import { openDb, purgeEphemeral, type Db } from '../src/db.js';
import { DpappEventSchema, normalizeDeepSeekChunk } from '../src/deepseek/events.js';

interface Harness {
  app: FastifyInstance;
  db: Db;
  config: Config;
}

const PAIRING_CODE = 'TESTCODE';

function makeHarness(overrides: Partial<Config> = {}): Harness {
  const config: Config = {
    ...loadConfig({ MOCK: '1', PAIRING_CODE } as unknown as NodeJS.ProcessEnv),
    mockDelayMs: 0,
    logRequests: false,
    ...overrides,
  };
  const db = openDb(':memory:');
  const app = buildApp({ config, db });
  return { app, db, config };
}

async function pair(app: FastifyInstance): Promise<string> {
  const response = await app.inject({
    method: 'POST',
    url: '/v1/pair',
    payload: { code: PAIRING_CODE, device_name: '测试机' },
  });
  assert.equal(response.statusCode, 201, response.payload);
  const body = response.json() as { token: string };
  return body.token;
}

const auth = (token: string) => ({ authorization: `Bearer ${token}` });

test('DeepSeek 流式 chunk 归一化为 DPAPP 增量', () => {
  assert.deepEqual(
    normalizeDeepSeekChunk({ choices: [{ index: 0, delta: { reasoning_content: '想一想' } }] }),
    { thinking: '想一想' },
  );
  assert.deepEqual(normalizeDeepSeekChunk({ choices: [{ delta: { content: '你好' } }] }), {
    text: '你好',
  });
  assert.deepEqual(
    normalizeDeepSeekChunk({ choices: [], usage: { prompt_tokens: 10, completion_tokens: 20 } }),
    { usage: { tokens_in: 10, tokens_out: 20 } },
  );
  assert.equal(normalizeDeepSeekChunk({ choices: [{ delta: {} }] }), null);
  assert.equal(normalizeDeepSeekChunk(null), null);
  assert.equal(normalizeDeepSeekChunk({ unexpected: true }), null);
});

test('事件协议 schema:合法事件通过,非法负费用被拒', () => {
  const ok = DpappEventSchema.safeParse({
    type: 'message_end',
    usage: { tokens_in: 1, tokens_out: 2 },
    cost_estimate: 0.0001,
    stop_reason: 'end_turn',
  });
  assert.equal(ok.success, true);

  const bad = DpappEventSchema.safeParse({
    type: 'message_end',
    usage: { tokens_in: 1, tokens_out: 2 },
    cost_estimate: -1,
    stop_reason: 'end_turn',
  });
  assert.equal(bad.success, false);

  assert.equal(DpappEventSchema.safeParse({ type: 'unknown_event' }).success, false);
});

test('配对与令牌:错误码 401、成功后令牌可用、旧码一次性作废', async (t) => {
  const { app } = makeHarness();
  t.after(() => app.close());

  const wrong = await app.inject({
    method: 'POST',
    url: '/v1/pair',
    payload: { code: 'WRONGCODE', device_name: '测试机' },
  });
  assert.equal(wrong.statusCode, 401);

  const token = await pair(app);
  assert.ok(token.length > 20);

  const reuse = await app.inject({
    method: 'POST',
    url: '/v1/pair',
    payload: { code: PAIRING_CODE, device_name: '第二台' },
  });
  assert.equal(reuse.statusCode, 401, '旧配对码应一次性作废');

  const noToken = await app.inject({ method: 'GET', url: '/v1/conversations' });
  assert.equal(noToken.statusCode, 401);

  const badToken = await app.inject({
    method: 'GET',
    url: '/v1/conversations',
    headers: auth('not-a-real-token'),
  });
  assert.equal(badToken.statusCode, 401);

  const withToken = await app.inject({
    method: 'GET',
    url: '/v1/conversations',
    headers: auth(token),
  });
  assert.equal(withToken.statusCode, 200);
  assert.deepEqual(withToken.json(), { conversations: [] });
});

test('消息树:MOCK 全链路 → 编辑重发产生兄弟分支 → 切叶子后路径正确', async (t) => {
  const { app } = makeHarness();
  t.after(() => app.close());
  const token = await pair(app);
  const headers = auth(token);

  const created = await app.inject({
    method: 'POST',
    url: '/v1/conversations',
    payload: {},
    headers,
  });
  assert.equal(created.statusCode, 201);
  const convId = (created.json() as { id: string }).id;

  // 第一轮:核对 SSE 事件序列
  const first = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '鲸灵是什么' },
    headers,
  });
  assert.equal(first.statusCode, 200);
  assert.match(first.headers['content-type'] as string, /text\/event-stream/);
  for (const eventName of [
    'message_start',
    'thinking_delta',
    'thinking_end',
    'text_delta',
    'message_end',
  ]) {
    assert.match(first.payload, new RegExp(`event: ${eventName}\\n`), `缺少 ${eventName} 事件`);
  }
  assert.match(first.payload, /"stop_reason":"end_turn"/);

  let detail = (
    await app.inject({ method: 'GET', url: `/v1/conversations/${convId}`, headers })
  ).json() as { path: string[]; tree: Array<{ id: string; children: unknown[] }> };
  assert.equal(detail.path.length, 2);
  const firstUserId = detail.path[0];
  const firstAssistantId = detail.path[1];

  // 编辑重发:parent_message_id 指向原用户消息的父节点(根),产生兄弟用户分支
  const second = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '鲸灵是什么(改)', parent_message_id: null },
    headers,
  });
  assert.equal(second.statusCode, 200, second.payload);

  detail = (
    await app.inject({ method: 'GET', url: `/v1/conversations/${convId}`, headers })
  ).json() as typeof detail;
  assert.equal(detail.tree.length, 2, '根下应有两个用户消息,即兄弟分支');
  assert.equal(detail.path.length, 2);
  assert.notEqual(detail.path[0], firstUserId);
  const secondAssistantId = detail.path[1];
  assert.notEqual(secondAssistantId, firstAssistantId);

  // 切回旧分支
  const patched = await app.inject({
    method: 'PATCH',
    url: `/v1/conversations/${convId}`,
    payload: { active_leaf_id: firstAssistantId },
    headers,
  });
  assert.equal(patched.statusCode, 200);

  detail = (
    await app.inject({ method: 'GET', url: `/v1/conversations/${convId}`, headers })
  ).json() as typeof detail;
  assert.deepEqual(detail.path, [firstUserId, firstAssistantId], '切换后应沿旧分支回溯');

  // 切回新分支,并在其上继续追问
  await app.inject({
    method: 'PATCH',
    url: `/v1/conversations/${convId}`,
    payload: { active_leaf_id: secondAssistantId },
    headers,
  });
  const third = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '继续问一句' },
    headers,
  });
  assert.equal(third.statusCode, 200);

  detail = (
    await app.inject({ method: 'GET', url: `/v1/conversations/${convId}`, headers })
  ).json() as typeof detail;
  assert.equal(detail.path.length, 4, '新消息应接在新活跃路径末尾');

  // 自动标题
  const list = (
    await app.inject({ method: 'GET', url: '/v1/conversations', headers })
  ).json() as { conversations: Array<{ id: string; title: string; preview: string }> };
  assert.equal(list.conversations.length, 1);
  assert.ok(list.conversations[0].title.length > 0, '首条消息应自动生成标题');
  assert.equal(list.conversations[0].id, convId);
});

test('重新生成:同一用户消息下新建兄弟助手分支', async (t) => {
  const { app } = makeHarness();
  t.after(() => app.close());
  const headers = auth(await pair(app));

  const convId = (
    (await app.inject({ method: 'POST', url: '/v1/conversations', payload: {}, headers })).json() as {
      id: string;
    }
  ).id;

  await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '讲个笑话' },
    headers,
  });
  let detail = (
    await app.inject({ method: 'GET', url: `/v1/conversations/${convId}`, headers })
  ).json() as { path: string[]; tree: Array<{ children: unknown[] }> };
  const userId = detail.path[0];
  const firstAssistantId = detail.path[1];

  const regen = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { regenerate: true, parent_message_id: userId },
    headers,
  });
  assert.equal(regen.statusCode, 200, regen.payload);

  detail = (
    await app.inject({ method: 'GET', url: `/v1/conversations/${convId}`, headers })
  ).json() as typeof detail;
  assert.equal(detail.path[0], userId, '重新生成不应新增用户消息');
  assert.notEqual(detail.path[1], firstAssistantId);
  assert.equal(detail.tree.length, 1, '只有一个根节点(用户消息)');
  assert.equal(detail.tree[0].children.length, 2, '用户消息下应有两个助手兄弟分支');
});

test('临时会话:默认列表不可见,include_ephemeral=1 可见,启动清扫删除', async (t) => {
  const { app, db } = makeHarness();
  t.after(() => app.close());
  const headers = auth(await pair(app));

  const created = await app.inject({
    method: 'POST',
    url: '/v1/conversations',
    payload: { ephemeral: true },
    headers,
  });
  assert.equal(created.statusCode, 201);

  const list = (
    await app.inject({ method: 'GET', url: '/v1/conversations', headers })
  ).json() as { conversations: unknown[] };
  assert.equal(list.conversations.length, 0, '临时会话不出现在默认列表');

  const listAll = (
    await app.inject({
      method: 'GET',
      url: '/v1/conversations?include_ephemeral=1',
      headers,
    })
  ).json() as { conversations: unknown[] };
  assert.equal(listAll.conversations.length, 1);

  assert.equal(purgeEphemeral(db), 1, '清扫应删除临时会话');
  const afterPurge = (
    await app.inject({
      method: 'GET',
      url: '/v1/conversations?include_ephemeral=1',
      headers,
    })
  ).json() as { conversations: unknown[] };
  assert.equal(afterPurge.conversations.length, 0);
});

test('用量统计:chat 后按天汇总 tokens 与费用', async (t) => {
  const { app } = makeHarness();
  t.after(() => app.close());
  const headers = auth(await pair(app));

  const convId = (
    (await app.inject({ method: 'POST', url: '/v1/conversations', payload: {}, headers })).json() as {
      id: string;
    }
  ).id;
  await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '统计一下' },
    headers,
  });

  const usage = (
    await app.inject({ method: 'GET', url: '/v1/usage', headers })
  ).json() as {
    days: Array<{ date: string; calls: number; tokens_in: number; tokens_out: number; cost: number }>;
    totals: { calls: number; tokens_in: number; tokens_out: number; cost: number };
    budget: { daily_cny: number };
  };

  assert.equal(usage.totals.calls, 1);
  assert.ok(usage.totals.tokens_out > 0);
  assert.equal(usage.days.length, 1);
  assert.equal(usage.days[0].calls, 1);
  assert.equal(usage.budget.daily_cny, 20);
});

test('框架客户端错误透出原状态码:不支持的 Content-Type 是 415 而不是 500', async (t) => {
  const { app } = makeHarness();
  t.after(() => app.close());

  const response = await app.inject({
    method: 'POST',
    url: '/v1/pair',
    payload: '<code>whatever</code>',
    headers: { 'content-type': 'application/xml' },
  });
  assert.equal(response.statusCode, 415);
  assert.equal((response.json() as { error: { code: string } }).error.code, 'FST_ERR_CTP_INVALID_MEDIA_TYPE');
});

test('生成过程中删除会话:SSE 正常收尾,不泄漏连接也不落坏数据', async (t) => {
  const { app } = makeHarness({ mockDelayMs: 50 });
  t.after(() => app.close());
  const headers = auth(await pair(app));

  const convId = (
    (await app.inject({ method: 'POST', url: '/v1/conversations', payload: {}, headers })).json() as {
      id: string;
    }
  ).id;

  const chatPromise = app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '慢慢回答' },
    headers,
  });
  // 让生成进入流式阶段后再删会话
  await new Promise((resolve) => setTimeout(resolve, 40));

  const deleted = await app.inject({
    method: 'DELETE',
    url: `/v1/conversations/${convId}`,
    headers,
  });
  assert.equal(deleted.statusCode, 204);

  const chat = await chatPromise;
  assert.equal(chat.statusCode, 200, '流仍应正常收尾');
  assert.match(chat.payload, /event: (message_end|error)/, '断流必须有终止事件');

  const gone = await app.inject({ method: 'GET', url: `/v1/conversations/${convId}`, headers });
  assert.equal(gone.statusCode, 404);
});

test('stop:无进行中生成返回 409;不存在的会话返回 404', async (t) => {
  const { app } = makeHarness();
  t.after(() => app.close());
  const headers = auth(await pair(app));

  const convId = (
    (await app.inject({ method: 'POST', url: '/v1/conversations', payload: {}, headers })).json() as {
      id: string;
    }
  ).id;

  const stop = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/stop`,
    headers,
  });
  assert.equal(stop.statusCode, 409);

  const missing = await app.inject({
    method: 'GET',
    url: `/v1/conversations/${'0'.repeat(32)}`,
    headers,
  });
  assert.equal(missing.statusCode, 404);
});
