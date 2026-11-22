import assert from 'node:assert/strict';
import test from 'node:test';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/index.js';
import { loadConfig, type Config } from '../src/config.js';
import { openDb, type Db } from '../src/db.js';
import { effectiveApiKey, keyHint, storedApiKey } from '../src/apikey.js';
import { looksLikeApiKey } from '../src/routes/modelkey.js';

const PAIRING_CODE = 'TESTCODE';
const CUSTOM_KEY = 'sk-custom-1234567890abcd';

interface Harness {
  app: FastifyInstance;
  db: Db;
  config: Config;
}

function makeHarness(env: Record<string, string> = {}): Harness {
  const config: Config = {
    ...loadConfig({ MOCK: '1', PAIRING_CODE, ...env } as unknown as NodeJS.ProcessEnv),
    pairingCodeFixed: false,
    mockDelayMs: 0,
    logRequests: false,
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
  return (response.json() as { token: string }).token;
}

const auth = (token: string) => ({ authorization: `Bearer ${token}` });

test('model-key:未设置时 source=none(无 env key)或 default(有 env key)', async () => {
  const none = makeHarness();
  const first = await none.app.inject({ method: 'GET', url: '/v1/model-key', headers: auth(await pair(none.app)) });
  assert.deepEqual(first.json(), { source: 'none', hint: '' });

  const withEnv = makeHarness({ DEEPSEEK_API_KEY: 'sk-env-9876543210efgh' });
  const second = await withEnv.app.inject({ method: 'GET', url: '/v1/model-key', headers: auth(await pair(withEnv.app)) });
  assert.deepEqual(second.json(), { source: 'default', hint: '…efgh' });
});

test('model-key:PUT 存入个人 key,只回尾号、绝不回全文', async () => {
  const { app } = makeHarness({ DEEPSEEK_API_KEY: 'sk-env-9876543210efgh' });
  const headers = auth(await pair(app));

  const put = await app.inject({
    method: 'PUT',
    url: '/v1/model-key',
    headers,
    payload: { api_key: CUSTOM_KEY },
  });
  assert.equal(put.statusCode, 200);
  assert.deepEqual(put.json(), { source: 'custom', hint: '…abcd' });
  assert.ok(!put.body.includes(CUSTOM_KEY), '响应不能带 key 全文');

  const get = await app.inject({ method: 'GET', url: '/v1/model-key', headers });
  assert.deepEqual(get.json(), { source: 'custom', hint: '…abcd' });
  assert.ok(!get.body.includes(CUSTOM_KEY), '响应不能带 key 全文');
});

test('model-key:形状不对的 key 被拒(sk- 前缀、长度、含空白)', async () => {
  const { app } = makeHarness();
  const headers = auth(await pair(app));
  for (const bad of ['abc-1234567890abcd', 'sk-123', 'sk-12 34567890abcd', '']) {
    const response = await app.inject({
      method: 'PUT',
      url: '/v1/model-key',
      headers,
      payload: { api_key: bad },
    });
    assert.equal(response.statusCode, 400, `应拒绝:${bad}`);
  }
});

test('model-key:DELETE 后回落默认 key', async () => {
  const { app, db, config } = makeHarness({ DEEPSEEK_API_KEY: 'sk-env-9876543210efgh' });
  const headers = auth(await pair(app));

  await app.inject({ method: 'PUT', url: '/v1/model-key', headers, payload: { api_key: CUSTOM_KEY } });
  assert.equal(effectiveApiKey(config, db), CUSTOM_KEY, '个人 key 优先于 env');

  const deleted = await app.inject({ method: 'DELETE', url: '/v1/model-key', headers });
  assert.equal(deleted.statusCode, 204);
  assert.equal(storedApiKey(db), null);
  assert.equal(effectiveApiKey(config, db), 'sk-env-9876543210efgh', '清掉后回落 env');
});

test('model-key:必须带设备令牌', async () => {
  const { app } = makeHarness();
  assert.equal((await app.inject({ method: 'GET', url: '/v1/model-key' })).statusCode, 401);
});

test('keyHint/looksLikeApiKey 纯函数', () => {
  assert.equal(keyHint(''), '');
  assert.equal(keyHint('sk-abcdef1234'), '…1234');
  assert.equal(keyHint('abcd'), '…');
  assert.ok(looksLikeApiKey('sk-1234567890abcdef'));
  assert.ok(!looksLikeApiKey('pk-1234567890abcdef'));
  assert.ok(!looksLikeApiKey('sk-12'));
  assert.ok(!looksLikeApiKey('sk-12 4567890abcdef'));
});
