import assert from 'node:assert/strict';
import { createServer, type ServerResponse } from 'node:http';
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

// ---------- 伪造上游:验证真实 HTTP 客户端路径(断流、错误、上下文装配) ----------

interface FakeRequest {
  messages: Array<{ role: string; content: string }>;
}

interface FakeUpstream {
  baseUrl: string;
  requests: FakeRequest[];
  close: () => Promise<void>;
}

async function startFakeUpstream(
  responder: (body: FakeRequest, res: ServerResponse, index: number) => void,
): Promise<FakeUpstream> {
  const requests: FakeRequest[] = [];
  const server = createServer((req, res) => {
    let raw = '';
    req.on('data', (chunk: Buffer) => {
      raw += chunk.toString('utf8');
    });
    req.on('end', () => {
      const body = raw === '' ? { messages: [] } : (JSON.parse(raw) as FakeRequest);
      requests.push(body);
      responder(body, res, requests.length - 1);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  const port = typeof address === 'object' && address !== null ? address.port : 0;
  return {
    baseUrl: `http://127.0.0.1:${port}`,
    requests,
    close: () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  };
}

const writeSse = (res: ServerResponse, chunks: string[]): void => {
  res.writeHead(200, { 'Content-Type': 'text/event-stream' });
  for (const chunk of chunks) res.write(`data: ${chunk}\n\n`);
  res.end();
};

const happySse = (_body: FakeRequest, res: ServerResponse): void =>
  writeSse(res, [
    '{"choices":[{"delta":{"content":"好"}}]}',
    '{"choices":[{"delta":{"content":"的"}}]}',
    '{"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2}}',
    '[DONE]',
  ]);

function fakeHarness(fake: FakeUpstream): Harness {
  return makeHarness({
    mock: false,
    deepseekApiKey: 'test-key',
    deepseekBaseUrl: fake.baseUrl,
    mockDelayMs: 0,
  });
}

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

// ---------- 协议与失败路径回归 ----------

interface TreeLikeNode {
  id: string;
  role: string;
  blocks: Array<{ type?: string; text?: string }>;
  children: TreeLikeNode[];
}

function findNode(nodes: TreeLikeNode[], id: string): TreeLikeNode | undefined {
  for (const node of nodes) {
    if (node.id === id) return node;
    const found = findNode(node.children, id);
    if (found) return found;
  }
  return undefined;
}

function parseSseEvents(payload: string): Array<Record<string, unknown>> {
  return payload
    .split('\n\n')
    .map((block) => block.trim())
    .filter((block) => block !== '')
    .map((block) => {
      const dataLine = block.split('\n').find((line) => line.startsWith('data: '));
      assert.ok(dataLine, `SSE 块缺少 data 行: ${block.slice(0, 80)}`);
      return JSON.parse(dataLine.slice('data: '.length)) as Record<string, unknown>;
    });
}

test('发出的 SSE 每个事件都通过协议 schema 校验,且以 message_start 开头、message_end 收尾', async (t) => {
  const { app } = makeHarness();
  t.after(() => app.close());
  const headers = auth(await pair(app));

  const convId = (
    (await app.inject({ method: 'POST', url: '/v1/conversations', payload: {}, headers })).json() as {
      id: string;
    }
  ).id;
  const chat = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '校验事件' },
    headers,
  });

  const events = parseSseEvents(chat.payload);
  assert.ok(events.length > 3);
  for (const event of events) {
    const result = DpappEventSchema.safeParse(event);
    assert.equal(result.success, true, `事件不合法: ${JSON.stringify(event)}`);
  }
  assert.equal(events[0].type, 'message_start');
  assert.ok(typeof events[0].user_message_id === 'string', 'message_start 应带 user_message_id');
  assert.equal(events.at(-1)?.type, 'message_end');
});

test('stop 在拿到任何内容前中断:空占位落库(消息不会消失),空回答不进下一轮上下文', async (t) => {
  const fake = await startFakeUpstream((body, res, index) => {
    if (index === 0) {
      // 只回响应头、不吐事件:模型长时间思考期间用户点了 stop
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      return;
    }
    happySse(body, res);
  });
  const { app } = fakeHarness(fake);
  t.after(async () => {
    await app.close();
    await fake.close();
  });
  const headers = auth(await pair(app));

  const convId = (
    (await app.inject({ method: 'POST', url: '/v1/conversations', payload: {}, headers })).json() as {
      id: string;
    }
  ).id;

  const chatPromise = app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '你好' },
    headers,
  });
  await new Promise((resolve) => setTimeout(resolve, 80));
  const stop = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/stop`,
    headers,
  });
  assert.equal(stop.statusCode, 200);

  const chat = await chatPromise;
  assert.match(chat.payload, /"stop_reason":"interrupted"/);

  const detail = (
    await app.inject({ method: 'GET', url: `/v1/conversations/${convId}`, headers })
  ).json() as { path: string[]; tree: TreeLikeNode[] };
  assert.equal(detail.path.length, 2, '用户消息 + 空占位助手消息都应在活跃路径上,消息不能消失');
  assert.equal(detail.tree.length, 1, '不应产生第二个根分支');
  assert.equal(findNode(detail.tree, detail.path[1])?.role, 'assistant');

  // 下一轮:空回答必须被过滤掉,否则部分 OpenAI 兼容实现会拒绝空 content
  const second = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '接着聊' },
    headers,
  });
  assert.equal(second.statusCode, 200);
  const sentMessages = fake.requests[1]?.messages ?? [];
  assert.ok(sentMessages.length >= 2, `上下文应至少含两轮用户消息,实际 ${sentMessages.length}`);
  assert.equal(
    sentMessages.some((message) => message.content === ''),
    false,
    '空助手消息不应发给模型',
  );
});

test('上游中途断流:已收到的部分正文落库 + error 事件 + message_end(error)', async (t) => {
  const fake = await startFakeUpstream((_body, res) => {
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    res.write('data: {"choices":[{"delta":{"content":"半句"}}]}\n\n');
    setTimeout(() => res.destroy(), 20);
  });
  const { app } = fakeHarness(fake);
  t.after(async () => {
    await app.close();
    await fake.close();
  });
  const headers = auth(await pair(app));

  const convId = (
    (await app.inject({ method: 'POST', url: '/v1/conversations', payload: {}, headers })).json() as {
      id: string;
    }
  ).id;

  const chat = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '讲长一点' },
    headers,
  });

  assert.match(chat.payload, /event: error/);
  assert.match(chat.payload, /"stop_reason":"error"/);

  const detail = (
    await app.inject({ method: 'GET', url: `/v1/conversations/${convId}`, headers })
  ).json() as { path: string[]; tree: TreeLikeNode[] };
  assert.equal(detail.path.length, 2);
  const assistant = findNode(detail.tree, detail.path[1]);
  assert.equal(assistant?.blocks[0]?.text, '半句', '用户已经看到的文字不能丢');

  const usage = (
    await app.inject({ method: 'GET', url: '/v1/usage', headers })
  ).json() as { totals: { calls: number; tokens_out: number } };
  assert.equal(usage.totals.calls, 1, '中断也要记用量(估算值)');
  assert.ok(usage.totals.tokens_out > 0);
});

test('设备令牌只存 sha256,库里没有明文', async (t) => {
  const { app, db } = makeHarness();
  t.after(() => app.close());
  const token = await pair(app);

  const row = db.prepare('SELECT token_hash FROM device LIMIT 1').get() as { token_hash: string };
  assert.match(row.token_hash, /^[0-9a-f]{64}$/);
  assert.notEqual(row.token_hash, token);
});

test('删除消息:删掉助手分支后 active_leaf 回退,子树整体消失', async (t) => {
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
    payload: { content: '第一问' },
    headers,
  });
  let detail = (
    await app.inject({ method: 'GET', url: `/v1/conversations/${convId}`, headers })
  ).json() as { path: string[]; active_leaf_id: string | null };
  const userId = detail.path[0];
  const assistantId = detail.path[1];

  // 重新生成制造兄弟分支,再删掉当前活跃的那个助手分支
  await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { regenerate: true, parent_message_id: userId },
    headers,
  });
  const siblings = (
    await app.inject({ method: 'GET', url: `/v1/conversations/${convId}`, headers })
  ).json() as { path: string[]; tree: Array<{ children: TreeLikeNode[] }> };
  assert.equal(siblings.tree[0].children.length, 2);
  const activeAssistantId = siblings.path[1];
  assert.notEqual(activeAssistantId, assistantId);

  const deleted = await app.inject({
    method: 'DELETE',
    url: `/v1/conversations/${convId}/messages/${activeAssistantId}`,
    headers,
  });
  assert.equal(deleted.statusCode, 204);

  detail = (
    await app.inject({ method: 'GET', url: `/v1/conversations/${convId}`, headers })
  ).json() as typeof detail;
  assert.deepEqual(detail.path, [userId], '删掉活跃助手分支后应回退到用户消息');
  assert.equal(detail.active_leaf_id, userId);

  // 旧兄弟分支仍在
  const afterDelete = (
    await app.inject({ method: 'GET', url: `/v1/conversations/${convId}`, headers })
  ).json() as { tree: Array<{ children: TreeLikeNode[] }> };
  assert.equal(afterDelete.tree[0].children.length, 1);

  const missing = await app.inject({
    method: 'DELETE',
    url: `/v1/conversations/${convId}/messages/${activeAssistantId}`,
    headers,
  });
  assert.equal(missing.statusCode, 404);
});

test('dev CORS:SSE 响应在 hijack 后仍带 Access-Control-Allow-Origin;非 dev 不带', async (t) => {
  const mockHarness = makeHarness();
  const mockHeaders = auth(await pair(mockHarness.app));
  const mockConv = (
    (await mockHarness.app.inject({
      method: 'POST',
      url: '/v1/conversations',
      payload: {},
      headers: mockHeaders,
    })).json() as { id: string }
  ).id;
  const chat = await mockHarness.app.inject({
    method: 'POST',
    url: `/v1/conversations/${mockConv}/chat`,
    payload: { content: 'cors' },
    headers: mockHeaders,
  });
  assert.equal(chat.headers['access-control-allow-origin'], '*', 'SSE 响应必须带 CORS 头,否则 Chrome 下整个流被拦');
  await mockHarness.app.close();

  const prodHarness = makeHarness({ mock: false, devCors: false, deepseekApiKey: 'test-key' });
  t.after(() => prodHarness.app.close());
  const prodHeaders = auth(await pair(prodHarness.app));
  const list = await prodHarness.app.inject({
    method: 'GET',
    url: '/v1/conversations',
    headers: prodHeaders,
  });
  assert.equal(list.headers['access-control-allow-origin'], undefined, '非 dev 不应放开 CORS');
});

test('所有受保护路由都要求 Bearer 令牌', async (t) => {
  const { app } = makeHarness();
  t.after(() => app.close());
  const headers = auth(await pair(app));
  const convId = (
    (await app.inject({ method: 'POST', url: '/v1/conversations', payload: {}, headers })).json() as {
      id: string;
    }
  ).id;

  const protectedRoutes: Array<{ method: 'GET' | 'POST' | 'PATCH' | 'DELETE'; url: string }> = [
    { method: 'GET', url: '/v1/conversations' },
    { method: 'POST', url: '/v1/conversations' },
    { method: 'GET', url: `/v1/conversations/${convId}` },
    { method: 'PATCH', url: `/v1/conversations/${convId}` },
    { method: 'DELETE', url: `/v1/conversations/${convId}` },
    { method: 'POST', url: `/v1/conversations/${convId}/chat` },
    { method: 'POST', url: `/v1/conversations/${convId}/stop` },
    { method: 'DELETE', url: `/v1/conversations/${convId}/messages/anything` },
    { method: 'GET', url: '/v1/usage' },
  ];

  for (const route of protectedRoutes) {
    const response = await app.inject({ method: route.method, url: route.url });
    assert.equal(response.statusCode, 401, `${route.method} ${route.url} 应要求令牌`);
  }
});
