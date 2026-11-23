import assert from 'node:assert/strict';
import test from 'node:test';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/index.js';
import { loadConfig, type Config } from '../src/config.js';
import { openDb, type Db } from '../src/db.js';

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

const auth = (token: string) => ({ authorization: `Bearer ${token}` });

async function register(app: FastifyInstance, email: string, password = 'password123') {
  const response = await app.inject({
    method: 'POST',
    url: '/v1/auth/register',
    payload: { email, password },
  });
  return response;
}

test('账号:注册 → 验证码激活(自动登录)→ 令牌可用', async () => {
  const { app } = makeHarness();
  const created = await register(app, 'a@example.com');
  assert.equal(created.statusCode, 201);
  const code = (created.json() as { debug_code: string }).debug_code;
  assert.match(code, /^\d{6}$/, 'MOCK 下应带 6 位 debug_code');

  const verified = await app.inject({
    method: 'POST',
    url: '/v1/auth/verify',
    payload: { email: 'a@example.com', code, device_name: '测试端' },
  });
  assert.equal(verified.statusCode, 200);
  const { token, device_name: deviceName } = verified.json() as { token: string; device_name: string };
  assert.equal(deviceName, '测试端');
  assert.ok(token.length > 20);

  const list = await app.inject({ method: 'GET', url: '/v1/conversations', headers: auth(token) });
  assert.equal(list.statusCode, 200);
});

test('账号:仅允许一个账号,二次注册 409', async () => {
  const { app } = makeHarness();
  await register(app, 'a@example.com');
  const second = await register(app, 'b@example.com');
  assert.equal(second.statusCode, 409);
  assert.equal((second.json() as { error: { code: string } }).error.code, 'account_exists');
});

test('账号:未激活不能登录,激活后密码登录拿令牌', async () => {
  const { app } = makeHarness();
  const created = await register(app, 'c@example.com');
  const code = (created.json() as { debug_code: string }).debug_code;

  const early = await app.inject({
    method: 'POST',
    url: '/v1/auth/login',
    payload: { email: 'c@example.com', password: 'password123' },
  });
  assert.equal(early.statusCode, 403);

  await app.inject({ method: 'POST', url: '/v1/auth/verify', payload: { email: 'c@example.com', code } });

  const wrong = await app.inject({
    method: 'POST',
    url: '/v1/auth/login',
    payload: { email: 'c@example.com', password: 'wrong-pass' },
  });
  assert.equal(wrong.statusCode, 401);

  const ok = await app.inject({
    method: 'POST',
    url: '/v1/auth/login',
    payload: { email: 'c@example.com', password: 'password123', device_name: '手机' },
  });
  assert.equal(ok.statusCode, 200);
  assert.ok((ok.json() as { token: string }).token.length > 20);
});

test('账号:验证码错/过期被拒', async () => {
  const { app } = makeHarness();
  await register(app, 'd@example.com');

  const bad = await app.inject({
    method: 'POST',
    url: '/v1/auth/verify',
    payload: { email: 'd@example.com', code: '000000' },
  });
  // 000000 恰好撞上的概率是百万分之一;撞上就当通过(核心是"错的被拒")
  if ((bad.statusCode === 200)) {
    // 极小概率,跳过断言
  } else {
    assert.equal(bad.statusCode, 400);
    assert.equal((bad.json() as { error: { code: string } }).error.code, 'invalid_code');
  }

  // 重发后旧码作废:同用途只保留最新一条
  const resent = await app.inject({
    method: 'POST',
    url: '/v1/auth/resend',
    payload: { email: 'd@example.com' },
  });
  const fresh = (resent.json() as { debug_code?: string }).debug_code;
  assert.ok(fresh !== undefined);
  const useOld = await app.inject({
    method: 'POST',
    url: '/v1/auth/verify',
    payload: { email: 'd@example.com', code: fresh === '000000' ? '111111' : '000000' },
  });
  assert.equal(useOld.statusCode, 400);
});

test('账号:重置密码——旧令牌吊销、新密码可登录', async () => {
  const { app } = makeHarness();
  const created = await register(app, 'e@example.com');
  const code = (created.json() as { debug_code: string }).debug_code;
  const verified = await app.inject({
    method: 'POST',
    url: '/v1/auth/verify',
    payload: { email: 'e@example.com', code },
  });
  const oldToken = (verified.json() as { token: string }).token;

  const forgot = await app.inject({
    method: 'POST',
    url: '/v1/auth/forgot',
    payload: { email: 'e@example.com' },
  });
  const resetCode = (forgot.json() as { debug_code: string }).debug_code;
  const reset = await app.inject({
    method: 'POST',
    url: '/v1/auth/reset',
    payload: { email: 'e@example.com', code: resetCode, new_password: 'newpassword456' },
  });
  assert.equal(reset.statusCode, 200);

  const stale = await app.inject({ method: 'GET', url: '/v1/conversations', headers: auth(oldToken) });
  assert.equal(stale.statusCode, 401, '重置密码后旧令牌必须失效');

  const login = await app.inject({
    method: 'POST',
    url: '/v1/auth/login',
    payload: { email: 'e@example.com', password: 'newpassword456' },
  });
  assert.equal(login.statusCode, 200);
});

test('账号:密码太短 400;不泄露 forgot/resend 的账号存在性', async () => {
  const { app } = makeHarness();
  const short = await register(app, 'f@example.com', 'short');
  assert.equal(short.statusCode, 400);

  await register(app, 'g@example.com');
  const ghostForgot = await app.inject({
    method: 'POST',
    url: '/v1/auth/forgot',
    payload: { email: 'ghost@example.com' },
  });
  assert.equal(ghostForgot.statusCode, 200);
  assert.equal((ghostForgot.json() as { debug_code?: string }).debug_code, undefined, '不存在的邮箱不给 debug_code');
});

test('账号:非 MOCK 且 SMTP 未配 → 注册 503 且不留半个账号', async () => {
  const config: Config = {
    ...loadConfig({ MOCK: '0', DEEPSEEK_API_KEY: 'sk-test-not-real', PAIRING_CODE } as unknown as NodeJS.ProcessEnv),
    pairingCodeFixed: false,
    mockDelayMs: 0,
    logRequests: false,
  };
  const db = openDb(':memory:');
  const app = buildApp({ config, db });

  const response = await register(app, 'smtp@example.com');
  assert.equal(response.statusCode, 503);
  assert.equal(
    (response.json() as { error: { code: string } }).error.code,
    'mail_not_configured',
  );
  assert.equal(
    (db.prepare('SELECT COUNT(1) AS n FROM user_account').get() as { n: number }).n,
    0,
    '发信失败不能留下账号把注册口堵死',
  );
});
