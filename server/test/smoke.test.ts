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
    // 默认按「一次性码」测试轮换行为;固定码模式单独用用例覆盖
    pairingCodeFixed: false,
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
  messages: Array<{
    role: string;
    content: unknown;
    server_tool_calls?: unknown[];
  }>;
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
    // /files 是文件上传转发:直接回一个 file id,不参与 chat 断言
    if ((req.url ?? '').includes('/files')) {
      let size = 0;
      req.on('data', (chunk: Buffer) => {
        size += chunk.length;
      });
      req.on('end', () => {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ id: 'file-api-test-1', object: 'file', bytes: size, purpose: 'text_recognition' }));
      });
      return;
    }

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
    { usage: { tokens_in: 10, tokens_out: 20, tokens_cached: 0, search_calls: 0, fetch_calls: 0 } },
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
    by_kind: Array<{ kind: string; calls: number; quantity: number; cost: number }>;
    budget: { daily_cny: number };
  };

  // M2 起 MOCK 假流会演示一次搜索:model 一条 + search 一条
  assert.equal(usage.totals.calls, 2, JSON.stringify(usage.by_kind));
  assert.ok(usage.totals.tokens_out > 0);
  assert.equal(usage.days.length, 1);
  assert.equal(usage.days[0].calls, 2);
  const modelKind = usage.by_kind.find((entry) => entry.kind === 'model');
  const searchKind = usage.by_kind.find((entry) => entry.kind === 'search');
  assert.ok(modelKind, '应有 model 用量');
  assert.ok(searchKind, 'M2 MOCK 应记录 search 用量');
  assert.equal(searchKind.quantity, 2, '搜索按查询词条数计次');
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
  citations?: unknown[];
  tool_traces?: unknown[];
  safety?: { source?: string; reason?: string } | null;
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

test('固定配对码:同码可重复配对且不轮换;连续失败触发 429', async (t) => {
  const { app } = makeHarness({ pairingCodeFixed: true });
  t.after(() => app.close());

  for (const name of ['固定设备A', '固定设备B']) {
    const res = await app.inject({
      method: 'POST',
      url: '/v1/pair',
      payload: { code: PAIRING_CODE, device_name: name },
    });
    assert.equal(res.statusCode, 201, `固定码应可重复配对: ${res.payload}`);
  }

  let lastStatus = 0;
  for (let attempt = 0; attempt < 6; attempt++) {
    const res = await app.inject({
      method: 'POST',
      url: '/v1/pair',
      payload: { code: 'WRONGCODE', device_name: 'x' },
    });
    lastStatus = res.statusCode;
  }
  assert.equal(lastStatus, 429, '连续错误应被限速');
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

// ---------- M2:联网工具 / 引用 / 标题 / 多轮回传 / 文件 ----------

const M2_TOOL_CHUNKS = [
  '{"choices":[{"delta":{"reasoning_content":"先想想"}}]}',
  JSON.stringify({
    choices: [{
      delta: {
        server_tool_calls: [{
          index: 0,
          reasoning_content: '查一下',
          calls: [{
            id: 'call-1',
            type: 'deepseek_web_search',
            kind: 'search',
            action: { type: 'search', queries: ['鲸灵是什么', 'JingLing'] },
            status: 'completed',
            sources: [{ type: 'url', url: 'https://example.com/a', title: '结果A', site_name: 'example.com', snippet: '摘要A' }],
          }],
        }],
      },
    }],
  }),
  '{"choices":[{"delta":{"content":"基于搜索的回答"}}]}',
  JSON.stringify({
    choices: [{
      delta: {
        annotations: [{ type: 'url_citation', url_citation: { url: 'https://example.com/a', title: '结果A', start_index: 0, end_index: 8 } }],
      },
    }],
  }),
  JSON.stringify({ choices: [{ delta: { title: '鲸灵与搜索' } }] }),
  JSON.stringify({
    choices: [],
    usage: {
      prompt_tokens: 100,
      completion_tokens: 20,
      prompt_tokens_details: { cached_tokens: 40 },
      server_tool_use: { tool_search: 3, tool_fetch: 1 },
    },
  }),
  '[DONE]',
];

function multipartUpload(filename: string, mime: string, data: Buffer) {
  const boundary = '----dshTestBoundary';
  const head = Buffer.from(
    `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${filename}"\r\nContent-Type: ${mime}\r\n\r\n`,
  );
  const tail = Buffer.from(`\r\n--${boundary}--\r\n`);
  return {
    payload: Buffer.concat([head, data, tail]),
    headers: { 'content-type': `multipart/form-data; boundary=${boundary}` },
  };
}

test('M2:工具调用/引用/标题事件与落库,以及下一轮回传 server_tool_calls', async (t) => {
  const fake = await startFakeUpstream((_body, res) => writeSse(res, M2_TOOL_CHUNKS));
  const { app } = fakeHarness(fake);
  t.after(async () => {
    await app.close();
    await fake.close();
  });
  const headers = auth(await pair(app));

  const convId = (
    (await app.inject({ method: 'POST', url: '/v1/conversations', payload: {}, headers })).json() as { id: string }
  ).id;

  const chat = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '鲸灵是什么' },
    headers,
  });
  assert.equal(chat.statusCode, 200);

  const events = parseSseEvents(chat.payload);
  for (const event of events) {
    assert.equal(DpappEventSchema.safeParse(event).success, true, `事件不合法: ${JSON.stringify(event)}`);
  }
  const toolResult = events.find((event) => event.type === 'tool_result');
  assert.ok(toolResult, '应有 tool_result 事件');
  assert.equal((toolResult.results as unknown[]).length, 1);
  assert.ok(events.some((event) => event.type === 'tool_progress'));
  const citation = events.find((event) => event.type === 'citation');
  assert.ok(citation, '应有 citation 事件');
  assert.equal(citation.start_index, 0);
  assert.ok(events.some((event) => event.type === 'title' && event.title === '鲸灵与搜索'));

  const end = events.find((event) => event.type === 'message_end');
  assert.ok(end, '应有 message_end');
  const usage = end.usage as Record<string, number>;
  assert.equal(usage.tokens_cached, 40);
  assert.equal(usage.search_calls, 3);
  assert.equal(usage.fetch_calls, 1);

  // 落库:标题、引用、工具留痕
  const detail = (
    await app.inject({ method: 'GET', url: `/v1/conversations/${convId}`, headers })
  ).json() as {
    title: string;
    path: string[];
    tree: TreeLikeNode[];
  };
  assert.equal(detail.title, '鲸灵与搜索', '应使用服务端生成的标题');
  const assistant = findNode(detail.tree, detail.path[1]);
  assert.equal((assistant?.citations as unknown[] | undefined)?.length, 1);
  assert.equal((assistant?.tool_traces as unknown[] | undefined)?.length, 1);

  // 第二轮:历史里的 assistant 必须原样回传 server_tool_calls(阅读链接靠它拼回上下文)
  await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '再问一句' },
    headers,
  });
  const secondRequest = fake.requests[1];
  assert.ok(secondRequest, '应有第二次上游请求');
  const replayedAssistant = secondRequest.messages.find((message) => message.role === 'assistant');
  assert.ok(replayedAssistant, '上下文里应有 assistant 消息');
  assert.equal((replayedAssistant.server_tool_calls as unknown[] | undefined)?.length, 1);
});

test('M2:文件上传(multipart)后可在对话里以 file 块引用', async (t) => {
  const fake = await startFakeUpstream((_body, res) => writeSse(res, M2_TOOL_CHUNKS));
  const { app } = fakeHarness(fake);
  t.after(async () => {
    await app.close();
    await fake.close();
  });
  const headers = auth(await pair(app));

  const upload = multipartUpload('report.pdf', 'application/pdf', Buffer.from('%PDF-1.4 test'));
  const uploaded = await app.inject({
    method: 'POST',
    url: '/v1/files?purpose=text_recognition',
    payload: upload.payload,
    headers: { ...headers, ...upload.headers },
  });
  assert.equal(uploaded.statusCode, 201, uploaded.payload);
  const fileId = (uploaded.json() as { file_id: string }).file_id;
  assert.ok(fileId);

  const convId = (
    (await app.inject({ method: 'POST', url: '/v1/conversations', payload: {}, headers })).json() as { id: string }
  ).id;
  await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '总结这份文档', file_ids: [fileId] },
    headers,
  });

  const sent = fake.requests[0];
  assert.ok(sent, '应有上游请求');
  const userMessage = sent.messages.find((message) => message.role === 'user');
  assert.ok(Array.isArray(userMessage?.content), '带文件时 content 应为数组');
  const parts = userMessage.content as Array<Record<string, unknown>>;
  const filePart = parts.find((part) => part.type === 'file');
  assert.ok(filePart, '应有 file 块');
  assert.equal(filePart.file_id, 'file-api-test-1', '应使用上游 provider file id');
});

test('M2:文件不存在时返回 400;输入命中审核时发 safety_block 且 stop_reason=refusal', async (t) => {
  const fake = await startFakeUpstream((_body, res) => {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: { message: 'Content Exists Risk', type: 'invalid_request_error' } }));
  });
  const { app } = fakeHarness(fake);
  t.after(async () => {
    await app.close();
    await fake.close();
  });
  const headers = auth(await pair(app));

  const convId = (
    (await app.inject({ method: 'POST', url: '/v1/conversations', payload: {}, headers })).json() as { id: string }
  ).id;

  const badFile = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '带个不存在的文件', file_ids: ['not-a-file'] },
    headers,
  });
  assert.equal(badFile.statusCode, 400);
  assert.equal((badFile.json() as { error: { code: string } }).error.code, 'invalid_file');

  const chat = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '一段会被审核拦截的输入' },
    headers,
  });
  assert.equal(chat.statusCode, 200);
  assert.match(chat.payload, /event: safety_block/);
  assert.match(chat.payload, /"stop_reason":"refusal"/);
});

// ---------- M4 语音:ASR / TTS(MOCK) ----------

test('M4 语音:MOCK ASR 接受 WAV 上传并返回文本,记录 asr 用量', async () => {
  const { app, db } = makeHarness();
  const headers = auth(await pair(app));

  const boundary = '----jinglingtest';
  const wav = Buffer.alloc(400);
  wav.write('RIFF', 0);
  const payload = Buffer.concat([
    Buffer.from(
      `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="speech.wav"\r\nContent-Type: audio/wav\r\n\r\n`,
    ),
    wav,
    Buffer.from(`\r\n--${boundary}--\r\n`),
  ]);

  const response = await app.inject({
    method: 'POST',
    url: '/v1/asr',
    payload,
    headers: { ...headers, 'content-type': `multipart/form-data; boundary=${boundary}` },
  });
  assert.equal(response.statusCode, 200);
  const json = response.json() as { text: string; duration_ms: number };
  assert.ok(json.text.length > 0, 'MOCK ASR 应返回文本');
  assert.ok(json.duration_ms > 0, 'MOCK ASR 应返回时长');

  const rows = db.prepare("SELECT COUNT(*) AS n FROM usage_log WHERE kind = 'asr'").get() as { n: number };
  assert.equal(rows.n, 1, '应记录一条 asr 用量');
});

test('M4 语音:MOCK TTS 返回 wav 音频并记录 tts 用量(汉字按 2 计费字符)', async () => {
  const { app, db } = makeHarness();
  const headers = auth(await pair(app));

  const response = await app.inject({
    method: 'POST',
    url: '/v1/tts',
    payload: { text: '你好' },
    headers,
  });
  assert.equal(response.statusCode, 200);
  assert.match(String(response.headers['content-type']), /audio\/wav/);
  assert.equal(response.rawPayload.subarray(0, 4).toString('ascii'), 'RIFF');

  const row = db
    .prepare("SELECT quantity, cost FROM usage_log WHERE kind = 'tts' ORDER BY ts DESC LIMIT 1")
    .get() as { quantity: number; cost: number } | undefined;
  assert.ok(row, '应记录 tts 用量');
  assert.equal(row!.quantity, 4, '「你好」两个汉字 = 4 计费字符');
  assert.ok(row!.cost > 0);
});
// ---------- M5 工具与用量 ----------

test('M5 memory:MOCK「记住」落库,「查记忆」触发 memory_search 工具', async () => {
  const { app, db } = makeHarness();
  const headers = auth(await pair(app));
  const convId = (
    (await app.inject({ method: 'POST', url: '/v1/conversations', payload: {}, headers })).json() as { id: string }
  ).id;

  const save = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '记住:我喜欢喝美式' },
    headers,
  });
  assert.equal(save.statusCode, 200);
  assert.match(save.payload, /event: tool_result/);
  assert.match(save.payload, /memory_save/);
  const rows = db.prepare('SELECT content FROM memory_note').all() as Array<{ content: string }>;
  assert.equal(rows.length, 1, '应写入一条记忆');
  assert.match(rows[0]!.content, /美式/);

  // 新会话里查记忆(同一会话的历史里已有 tool 结果,MOCK 启发式不会再发工具调用)
  const convId2 = (
    (await app.inject({ method: 'POST', url: '/v1/conversations', payload: {}, headers })).json() as { id: string }
  ).id;
  const search = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId2}/chat`,
    payload: { content: '查记忆:美式' },
    headers,
  });
  assert.equal(search.statusCode, 200);
  assert.match(search.payload, /memory_search/);
  const after = db.prepare('SELECT COUNT(*) AS n FROM memory_note').get() as { n: number };
  assert.equal(after.n, 1, '查询不应新增记忆');
});

test('M5 预算熔断:今日花费达到预算 → 402 budget_exceeded', async () => {
  const { app, db } = makeHarness({ dailyBudgetCny: 0.01 });
  const headers = auth(await pair(app));
  const convId = (
    (await app.inject({ method: 'POST', url: '/v1/conversations', payload: {}, headers })).json() as { id: string }
  ).id;
  db.prepare(
    "INSERT INTO usage_log (id, ts, kind, quantity, cost) VALUES ('budget-1', ?, 'model', 1, 0.02)",
  ).run(new Date().toISOString());

  const response = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '你好' },
    headers,
  });
  assert.equal(response.statusCode, 402);
  const body = response.json() as { error: { code: string; message: string } };
  assert.equal(body.error.code, 'budget_exceeded');
  assert.match(body.error.message, /预算/);
});

test('M5 http_request:白名单外拒绝,白名单内真实调用', async () => {
  const server = createServer((_req, res: ServerResponse) => {
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('hello from local service');
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  const port = typeof address === 'object' && address !== null ? address.port : 0;
  try {
    const { db, config } = makeHarness({ httpAllowlist: ['127.0.0.1'] });
    const { executeClientTool } = await import('../src/agent/tools.js');

    const allowed = await executeClientTool(config, db, {
      id: 'call-a',
      name: 'http_request',
      arguments: JSON.stringify({ url: `http://127.0.0.1:${port}/status` }),
    });
    assert.equal(allowed.ok, true, allowed.content);
    assert.match(allowed.content, /hello from local service/);

    const blocked = await executeClientTool(config, db, {
      id: 'call-b',
      name: 'http_request',
      arguments: JSON.stringify({ url: 'https://example.com/' }),
    });
    assert.equal(blocked.ok, false);
    assert.match(blocked.content, /白名单/);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});
test('M5 记忆管理接口:列表/搜索/删除', async () => {
  const { app, db } = makeHarness();
  const headers = auth(await pair(app));
  db.prepare(
    "INSERT INTO memory_note (id, content, tags, created_at, updated_at) VALUES ('m1', '用户喜欢美式咖啡', '[\"偏好\"]', ?, ?)",
  ).run(new Date().toISOString(), new Date().toISOString());

  const list = await app.inject({ method: 'GET', url: '/v1/memories', headers });
  assert.equal(list.statusCode, 200);
  const listBody = list.json() as { total: number; items: Array<{ id: string; content: string; tags: string[] }> };
  assert.equal(listBody.total, 1);
  assert.match(listBody.items[0]!.content, /美式/);
  assert.deepEqual(listBody.items[0]!.tags, ['偏好']);

  const search = await app.inject({ method: 'GET', url: '/v1/memories?query=美式', headers });
  assert.equal((search.json() as { total: number }).total, 1);

  const removed = await app.inject({ method: 'DELETE', url: '/v1/memories/m1', headers });
  assert.equal(removed.statusCode, 200);
  const after = await app.inject({ method: 'GET', url: '/v1/memories', headers });
  assert.equal((after.json() as { total: number }).total, 0);
});

// ---------- M3.5:会话级桥接(手机与电脑共用同一个会话) ----------

interface FakePlugin {
  ws: {
    send: (data: string) => void;
    close: () => void;
    addEventListener: (type: string, cb: (event: { data?: unknown }) => void) => void;
  };
  rpcCalls: Array<{ method: string; params: Record<string, unknown> }>;
  emit: (message: Record<string, unknown>) => void;
  waitFor: (method: string, timeoutMs?: number) => Promise<Record<string, unknown>>;
  /** 等服务端确认 hello(节点注册完成) */
  ready: Promise<void>;
  close: () => Promise<void>;
}

/** 用 Node 自带的 WebSocket 客户端假装成 dsh 插件,验证服务端的会话级中继。 */
async function startFakePlugin(
  port: number,
  token: string,
  options: { outdated?: boolean } = {},
): Promise<FakePlugin> {
  const WS = (globalThis as unknown as { WebSocket: new (url: string) => FakePlugin['ws'] }).WebSocket;
  const ws = new WS(`ws://127.0.0.1:${port}/v1/harness/bridge?token=${token}`);
  const rpcCalls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const waiters: Array<{ method: string; resolve: (params: Record<string, unknown>) => void }> = [];
  let markReady: () => void = () => {};
  const ready = new Promise<void>((resolve) => {
    markReady = resolve;
  });
  /** 假插件记住权限预设,好让 session.state 返回切换后的值 */
  let permission = 'workspace-write';

  ws.addEventListener('open', () => {
    ws.send(
      JSON.stringify({
        type: 'hello',
        node: { name: 'test-node', platform: 'test', capabilities: ['v2', 'session-stream'], startedAt: Date.now() },
      }),
    );
  });

  ws.addEventListener('message', (event) => {
    const message = JSON.parse(String(event.data)) as Record<string, unknown>;
    if (message.type === 'hello_ok') {
      markReady();
      return;
    }
    if (message.type !== 'rpc') return;
    const method = String(message.method);
    const params = (message.params ?? {}) as Record<string, unknown>;
    rpcCalls.push({ method, params });
    for (const waiter of [...waiters]) {
      if (waiter.method !== method) continue;
      waiters.splice(waiters.indexOf(waiter), 1);
      waiter.resolve(params);
    }
    // outdated:模拟"电脑上还没重启 dsh、插件是旧版"的行为(不认会话级方法)
    const sessionLevel = method.startsWith('session.') || method === 'input.send' || method === 'session.create';
    if (options.outdated === true && sessionLevel) {
      ws.send(
        JSON.stringify({ type: 'rpc-result', id: message.id, ok: false, error: `未知方法: ${method}` }),
      );
      return;
    }
    let result: Record<string, unknown> = {};
    switch (method) {
      case 'session.events':
        result = {
          captured_through_seq: 2,
          events: [
            { seq: 1, type: 'user_message', data: { text: '电脑上问的话', source: 'user' } },
            { seq: 2, type: 'assistant_message', data: { text: '电脑上的回答' } },
          ],
        };
        break;
      case 'session.state':
        result = { status: 'idle', permission, model: 'deepseek/deepseek-chat' };
        break;
      case 'session.permission':
        permission = String(params.mode ?? permission);
        result = { session_id: params.session_id, mode: permission };
        break;
      case 'input.send':
        result = { mode: params.mode === 'steer' ? 'steer' : 'followup', status: 'running' };
        break;
      case 'session.create':
        result = { session_id: 'session-new-1', agent_preset: 'standard', permission: 'workspace-write' };
        break;
      default:
        result = { ok: true };
    }
    ws.send(JSON.stringify({ type: 'rpc-result', id: message.id, ok: true, result }));
  });

  return {
    ws,
    rpcCalls,
    emit: (message) => ws.send(JSON.stringify(message)),
    ready,
    waitFor: (method, timeoutMs = 4000) =>
      new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`等待 RPC 超时:${method}`)), timeoutMs);
        waiters.push({
          method,
          resolve: (params) => {
            clearTimeout(timer);
            resolve(params);
          },
        });
      }),
    close: async () => {
      ws.close();
      await new Promise((resolve) => setTimeout(resolve, 50));
    },
  };
}

interface SseCollector {
  events: Array<{ kind: string; data: Record<string, unknown> }>;
  reader: ReadableStreamDefaultReader<Uint8Array>;
  controller: AbortController;
}

/** 读 SSE:收集到满足条件或超时为止(后续仍可继续 read)。 */
async function openSse(url: string, headers: Record<string, string>): Promise<SseCollector> {
  const controller = new AbortController();
  const response = await fetch(url, { headers, signal: controller.signal });
  assert.equal(response.status, 200);
  const reader = (response.body as ReadableStream<Uint8Array>).getReader();
  return { events: [], reader, controller };
}

async function readSseUntil(
  collector: SseCollector,
  done: (events: SseCollector['events']) => boolean,
  timeoutMs = 5000,
): Promise<SseCollector['events']> {
  const decoder = new TextDecoder();
  let buffer = '';
  const deadline = Date.now() + timeoutMs;
  while (!done(collector.events) && Date.now() < deadline) {
    const chunk = await new Promise<{ value?: Uint8Array }>((resolve) => {
      const timer = setTimeout(() => resolve({}), 100);
      timer.unref();
      void collector.reader.read().then((result) => {
        clearTimeout(timer);
        resolve(result.value === undefined ? {} : { value: result.value });
      });
    });
    if (chunk.value) buffer += decoder.decode(chunk.value, { stream: true });
    for (;;) {
      const index = buffer.indexOf('\n\n');
      if (index < 0) break;
      const block = buffer.slice(0, index);
      buffer = buffer.slice(index + 2);
      const kindLine = block.split('\n').find((line) => line.startsWith('event: '));
      const dataLine = block.split('\n').find((line) => line.startsWith('data: '));
      if (!kindLine || !dataLine) continue;
      collector.events.push({
        kind: kindLine.slice('event: '.length),
        data: JSON.parse(dataLine.slice('data: '.length)) as Record<string, unknown>,
      });
    }
  }
  return collector.events;
}

test('M3.5 会话级流:bootstrap 历史 → 实时事件去重 → 断线按 after_seq 续传', async (t) => {
  const { app, config } = makeHarness({ bridgeToken: 'test-bridge-token' });
  await app.listen({ port: 0, host: '127.0.0.1' });
  const port = (app.server.address() as { port: number }).port;
  const plugin = await startFakePlugin(port, 'test-bridge-token');
  await plugin.ready;
  t.after(async () => {
    await plugin.close();
    // WS / SSE 是长连接,Fastify 的 close 会等它们;测试里强制断开避免挂住
    app.server.closeAllConnections();
    await app.close();
  });

  const headers = { ...auth(await pair(app)) };
  const base = `http://127.0.0.1:${port}`;

  // 首次连接:先补发历史(插件 session.events),再 ready
  const first = await openSse(`${base}/v1/harness/sessions/session-a/stream?after_seq=0`, headers);
  const initial = await readSseUntil(first, (events) => events.some((event) => event.kind === 'harness_session_ready'));
  const ready = initial.find((event) => event.kind === 'harness_session_ready')!;
  assert.equal(ready.data.session_id, 'session-a');
  assert.equal(ready.data.last_seq, 2, '历史两条事件应各占一个 seq');
  assert.deepEqual(
    initial.filter((event) => event.kind === 'harness_session_event').map((event) => event.data.kind),
    ['user_message', 'assistant_message'],
  );
  // 打开会话 = 让插件订阅该会话
  assert.ok(plugin.rpcCalls.some((call) => call.method === 'session.watch.start' && call.params.session_id === 'session-a'));

  // 插件上行持久事件:分配 seq=3
  plugin.emit({
    type: 'session_event',
    session_id: 'session-a',
    dsh_seq: 3,
    kind: 'user_message',
    payload: { text: '电脑上刚说的话', source: 'user' },
  });
  let events = await readSseUntil(first, (list) => list.filter((event) => event.kind === 'harness_session_event').length >= 3);
  let durable = events.filter((event) => event.kind === 'harness_session_event');
  assert.deepEqual(durable.map((event) => event.data.seq), [1, 2, 3]);
  assert.equal((durable[2].data.payload as Record<string, unknown>).text, '电脑上刚说的话');

  // 同一 dsh_seq 重发(插件重连补发)不应重复插入
  plugin.emit({
    type: 'session_event',
    session_id: 'session-a',
    dsh_seq: 3,
    kind: 'user_message',
    payload: { text: '电脑上刚说的话', source: 'user' },
  });
  plugin.emit({ type: 'live', session_id: 'session-a', kind: 'status', status: 'running' });
  events = await readSseUntil(first, (list) => list.some((event) => event.kind === 'harness_session_live'));
  const live = events.find((event) => event.kind === 'harness_session_live')!;
  assert.equal(live.data.kind, 'status');
  assert.equal(live.data.status, 'running');
  assert.equal(events.filter((event) => event.kind === 'harness_session_event').length, 3, '重复 dsh_seq 不能产生第 4 条');

  // 手机输入:auto 由插件判定,服务端回显 input_echo
  const input = await app.inject({
    method: 'POST',
    url: '/v1/harness/sessions/session-a/input',
    payload: { text: '帮我看下测试', mode: 'auto' },
    headers,
  });
  assert.equal(input.statusCode, 200, input.payload);
  assert.equal((input.json() as { mode: string }).mode, 'followup');
  const inputCall = plugin.rpcCalls.find((call) => call.method === 'input.send');
  assert.ok(inputCall, '应把输入转发给插件');
  assert.equal(inputCall.params.text, '帮我看下测试');

  first.controller.abort();

  // 断线重连:after_seq=2 只补发 seq>2 的,不重复历史
  const second = await openSse(`${base}/v1/harness/sessions/session-a/stream?after_seq=2`, headers);
  const resumed = await readSseUntil(second, (list) => list.some((event) => event.kind === 'harness_session_ready'));
  const replayed = resumed.filter((event) => event.kind === 'harness_session_event');
  assert.deepEqual(replayed.map((event) => event.data.seq), [3]);
  second.controller.abort();
});

test('M3.5 新会话与权限:手机建会话走插件 session.create,权限可会话级切换', async (t) => {
  const { app } = makeHarness({ bridgeToken: 'test-bridge-token' });
  await app.listen({ port: 0, host: '127.0.0.1' });
  const port = (app.server.address() as { port: number }).port;
  const plugin = await startFakePlugin(port, 'test-bridge-token');
  await plugin.ready;
  t.after(async () => {
    await plugin.close();
    app.server.closeAllConnections();
    await app.close();
  });

  const headers = { ...auth(await pair(app)) };
  const base = `http://127.0.0.1:${port}`;

  const created = await app.inject({
    method: 'POST',
    url: '/v1/harness/sessions',
    payload: { cwd: 'D:\\workspace', permission: 'workspace-write' },
    headers,
  });
  assert.equal(created.statusCode, 200, created.payload);
  const body = created.json() as { session_id: string };
  assert.equal(body.session_id, 'session-new-1');
  const createCall = plugin.rpcCalls.find((call) => call.method === 'session.create');
  assert.ok(createCall, '应把新会话请求转发给插件');
  assert.equal(createCall.params.cwd, 'D:\\workspace');
  assert.equal(createCall.params.permission, 'workspace-write');

  const permission = await app.inject({
    method: 'PUT',
    url: `/v1/harness/sessions/${body.session_id}/permission`,
    payload: { mode: 'danger-full-access' },
    headers,
  });
  assert.equal(permission.statusCode, 200, permission.payload);
  assert.equal((permission.json() as { mode: string }).mode, 'danger-full-access');
  assert.ok(plugin.rpcCalls.some((call) => call.method === 'session.permission'));

  const state = await app.inject({
    method: 'GET',
    url: `/v1/harness/sessions/${body.session_id}/state`,
    headers,
  });
  assert.equal(state.statusCode, 200);
  assert.equal((state.json() as { permission: string }).permission, 'danger-full-access');
});

test('M3.5 旧版插件:输入返回 409 bridge_outdated,会话流给出「重启 dsh」提示', async (t) => {
  const { app } = makeHarness({ bridgeToken: 'test-bridge-token' });
  await app.listen({ port: 0, host: '127.0.0.1' });
  const port = (app.server.address() as { port: number }).port;
  const plugin = await startFakePlugin(port, 'test-bridge-token', { outdated: true });
  await plugin.ready;
  t.after(async () => {
    await plugin.close();
    app.server.closeAllConnections();
    await app.close();
  });

  const headers = { ...auth(await pair(app)) };
  const base = `http://127.0.0.1:${port}`;

  const input = await app.inject({
    method: 'POST',
    url: '/v1/harness/sessions/session-old/input',
    payload: { text: '在吗' },
    headers,
  });
  assert.equal(input.statusCode, 409);
  assert.equal((input.json() as { error: { code: string } }).error.code, 'bridge_outdated');
  assert.match((input.json() as { error: { message: string } }).error.message, /重启 dsh/);

  const stream = await openSse(`${base}/v1/harness/sessions/session-old/stream?after_seq=0`, headers);
  const events = await readSseUntil(
    stream,
    (list) => list.some((event) => event.kind === 'harness_session_live' && event.data.kind === 'error'),
  );
  const error = events.find((event) => event.kind === 'harness_session_live')!;
  assert.match(String(error.data.message), /重启 dsh/);
  stream.controller.abort();
});

// ---------- 收口:设备令牌吊销 ----------


test('设备吊销:列表标出本机,吊销后旧令牌立即 401,且不再出现在列表里', async (t) => {
  const { app } = makeHarness({ pairingCodeFixed: true });
  t.after(() => app.close());

  const tokenA = await pair(app);
  const tokenB = await pair(app);
  const headersA = auth(tokenA);
  const headersB = auth(tokenB);

  const list = await app.inject({ method: 'GET', url: '/v1/devices', headers: headersA });
  assert.equal(list.statusCode, 200);
  const devices = (list.json() as { devices: Array<{ id: string; name: string; current: boolean }> }).devices;
  assert.equal(devices.length, 2, '两台设备都应出现');
  assert.equal(devices.filter((device) => device.current).length, 1, '只有本机被标成 current');
  const other = devices.find((device) => !device.current)!;

  const revoked = await app.inject({ method: 'DELETE', url: `/v1/devices/${other.id}`, headers: headersA });
  assert.equal(revoked.statusCode, 204);

  const blocked = await app.inject({ method: 'GET', url: '/v1/conversations', headers: headersB });
  assert.equal(blocked.statusCode, 401, '被吊销设备的令牌必须立刻失效');

  const afterList = await app.inject({ method: 'GET', url: '/v1/devices', headers: headersA });
  assert.deepEqual(
    (afterList.json() as { devices: Array<{ id: string }> }).devices.map((device) => device.id).length,
    1,
  );

  // 重复吊销 / 不存在的设备 → 404,不能静默成功
  assert.equal(
    (await app.inject({ method: 'DELETE', url: `/v1/devices/${other.id}`, headers: headersA })).statusCode,
    404,
  );

  // 吊销自己同样允许(换手机/丢手机时用),此后本机令牌也 401
  const self = devices.find((device) => device.current)!;
  assert.equal((await app.inject({ method: 'DELETE', url: `/v1/devices/${self.id}`, headers: headersA })).statusCode, 204);
  assert.equal((await app.inject({ method: 'GET', url: '/v1/conversations', headers: headersA })).statusCode, 401);
});

// ---------- 收口:输出侧拒答标识 ----------

test('输出侧拒答识别:真实上游的拒答话术能命中,长回答与正文中段的表态不误判', async () => {
  const { detectOutputRefusal } = await import('../src/agent/safety.js');

  // 2026-11-15 真实 key 实测的拒答原文(开头)
  assert.deepEqual(
    detectOutputRefusal(
      '这个我没法帮你写。\n\n冒充银行客服骗取短信验证码属于典型的电信诈骗手段——验证码是账户的最后一道防线,拿到验证码基本等于拿到账户控制权。这类话术无论用于"测试"还是别的理由,我都不提供。',
    ),
    { source: 'output', reason: '模型以内容安全为由拒答' },
  );
  assert.deepEqual(
    detectOutputRefusal(
      '这个我不能写。冒充银行客服骗取短信验证码属于电信诈骗，是明确的违法犯罪行为（涉嫌诈骗罪、侵犯公民个人信息等），无论用于“测试”还是其他用途，我都不提供这类话术。',
    ),
    { source: 'output', reason: '模型以内容安全为由拒答' },
  );
  assert.equal(
    detectOutputRefusal(
      '这个我也不能教。撬开邻居家的门锁属于非法侵入住宅/盗窃，是刑事犯罪，无论出于什么理由（好奇、忘记带钥匙、想验证安全性）我都不提供开锁技术指导。',
    )?.source,
    'output',
  );
  assert.equal(detectOutputRefusal('这个我也不会教。撬开邻居家的门锁,不管动机是什么,都属于非法侵入住宅。')?.source, 'output');
  assert.deepEqual(detectOutputRefusal('抱歉,我无法提供这类信息。'), {
    source: 'output',
    reason: '模型以内容安全为由拒答',
  });
  assert.equal(detectOutputRefusal("I'm sorry, but I can't help with that.")?.source, 'output');
  // 真实正常回答(含代码)不能误判
  assert.equal(detectOutputRefusal('可以,这是你要的代码:\n```dart\nvoid main() {}\n```'), null);
  // 长回答里转述「我无法提供」不算拒答
  assert.equal(detectOutputRefusal(`${'这是一个正常的长回答。'.repeat(60)}我无法提供这类信息`), null);
  // 表态在开头 80 字之外出现也不算拒答(拒答都是开门见山,而不是聊到一半才转折)
  const lateRefusal = `${'这是一段与安全策略无关的正常内容。'.repeat(8)}我无法提供这类信息。`;
  assert.equal(detectOutputRefusal(lateRefusal), null);
  assert.equal(detectOutputRefusal(''), null);
});

test('输出侧拒答:发 safety_block(source=output) + stop_reason=refusal,正文仍然保留并落库', async (t) => {
  const refusalText = '这个我不能写。冒充客服骗取验证码属于诈骗,我不提供这类话术。';
  const fake = await startFakeUpstream((_body, res) => {
    writeSse(res, [
      `{"choices":[{"delta":{"content":"${refusalText}"}}]}`,
      '{"choices":[{"delta":{},"finish_reason":"stop"}]}',
      '{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":9}}',
      '[DONE]',
    ]);
  });
  const { app } = fakeHarness(fake);
  t.after(async () => {
    await app.close();
    await fake.close();
  });
  const headers = auth(await pair(app));

  const convId = (
    (await app.inject({ method: 'POST', url: '/v1/conversations', payload: {}, headers })).json() as { id: string }
  ).id;
  const chat = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '帮我做一件不该做的事' },
    headers,
  });
  assert.equal(chat.statusCode, 200);

  const events = parseSseEvents(chat.payload);
  const safety = events.find((event) => event.type === 'safety_block');
  assert.ok(safety, '应发 safety_block');
  assert.equal(safety.source, 'output');
  assert.match(String(safety.reason), /拒答/);
  assert.equal(events.at(-1)?.stop_reason, 'refusal', 'message_end 的 stop_reason 应是 refusal');
  assert.ok(events.some((event) => event.type === 'text_delta'), '正文照常下发,不做隐藏');

  const detail = (
    await app.inject({ method: 'GET', url: `/v1/conversations/${convId}`, headers })
  ).json() as { tree: TreeLikeNode[] };
  const assistant = findNode(detail.tree, String(events[0]!.message_id))!;
  assert.equal(assistant.blocks.map((block) => block.text ?? '').join(''), refusalText);
  assert.deepEqual(assistant.safety, { source: 'output', reason: '模型以内容安全为由拒答' });
});

test('普通回答不会被误标成拒答:没有 safety_block,safety 落库为 null', async (t) => {
  const fake = await startFakeUpstream(happySse);
  const { app } = fakeHarness(fake);
  t.after(async () => {
    await app.close();
    await fake.close();
  });
  const headers = auth(await pair(app));
  const convId = (
    (await app.inject({ method: 'POST', url: '/v1/conversations', payload: {}, headers })).json() as { id: string }
  ).id;

  const chat = await app.inject({
    method: 'POST',
    url: `/v1/conversations/${convId}/chat`,
    payload: { content: '打个招呼' },
    headers,
  });
  const events = parseSseEvents(chat.payload);
  assert.equal(events.some((event) => event.type === 'safety_block'), false);
  assert.equal(events.at(-1)?.stop_reason, 'end_turn');

  const detail = (
    await app.inject({ method: 'GET', url: `/v1/conversations/${convId}`, headers })
  ).json() as { tree: TreeLikeNode[] };
  const assistant = findNode(detail.tree, String(events[0]!.message_id))!;
  assert.equal(assistant.safety, null);
});

test('空 JSON body 的删除请求不再 400:走鉴权而不是 Content-Type 错误', async (t) => {
  const { app } = makeHarness();
  t.after(() => app.close());
  const response = await app.inject({
    method: 'DELETE',
    url: '/v1/conversations/whatever',
    headers: { 'content-type': 'application/json' },
  });
  assert.equal(response.statusCode, 401, response.payload);
});

test('非法 JSON 仍然是 400(不是 500),空 body 当 {}', async (t) => {
  const { app } = makeHarness();
  t.after(() => app.close());
  const bad = await app.inject({
    method: 'POST',
    url: '/v1/pair',
    headers: { 'content-type': 'application/json' },
    payload: '{oops',
  });
  assert.equal(bad.statusCode, 400, bad.payload);
  assert.equal((bad.json() as { error: { code: string } }).error.code, 'invalid_json');
});
