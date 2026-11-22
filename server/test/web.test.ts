import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/index.js';
import { loadConfig, type Config } from '../src/config.js';
import { openDb, type Db } from '../src/db.js';

const PAIRING_CODE = 'TESTCODE';

interface Harness {
  app: FastifyInstance;
  db: Db;
  webRoot: string;
}

function makeHarness(): Harness {
  const webRoot = mkdtempSync(join(tmpdir(), 'jingling-web-'));
  writeFileSync(join(webRoot, 'index.html'), '<html>INDEX-OK</html>');
  mkdirSync(join(webRoot, 'assets'));
  writeFileSync(join(webRoot, 'assets', 'main.dart.js'), '// JS-OK');

  const config: Config = {
    ...loadConfig({ MOCK: '1', PAIRING_CODE, WEB_DIR: webRoot } as unknown as NodeJS.ProcessEnv),
    pairingCodeFixed: false,
    mockDelayMs: 0,
    logRequests: false,
  };
  const db = openDb(':memory:');
  const app = buildApp({ config, db });
  return { app, db, webRoot };
}

test('web 静态:/web 与 /web/ 返回 index.html,免鉴权', async () => {
  const { app, webRoot } = makeHarness();
  try {
    for (const url of ['/web', '/web/']) {
      const response = await app.inject({ method: 'GET', url });
      assert.equal(response.statusCode, 200, url);
      assert.match(response.body, /INDEX-OK/);
      assert.match(response.headers['content-type'] as string, /text\/html/);
      assert.equal(response.headers['cache-control'], 'no-store');
    }
  } finally {
    rmSync(webRoot, { recursive: true, force: true });
  }
});

test('web 静态:资源文件带正确 MIME 与长缓存', async () => {
  const { app, webRoot } = makeHarness();
  try {
    const response = await app.inject({ method: 'GET', url: '/web/assets/main.dart.js' });
    assert.equal(response.statusCode, 200);
    assert.match(response.body, /JS-OK/);
    assert.match(response.headers['content-type'] as string, /javascript/);
    assert.match(response.headers['cache-control'] as string, /max-age=31536000/);
  } finally {
    rmSync(webRoot, { recursive: true, force: true });
  }
});

test('web 静态:SPA 回退——无扩展名路径回 index.html,缺资源是真 404', async () => {
  const { app, webRoot } = makeHarness();
  try {
    const route = await app.inject({ method: 'GET', url: '/web/some/frontend/route' });
    assert.equal(route.statusCode, 200);
    assert.match(route.body, /INDEX-OK/);

    const missing = await app.inject({ method: 'GET', url: '/web/assets/missing.js' });
    assert.equal(missing.statusCode, 404);
  } finally {
    rmSync(webRoot, { recursive: true, force: true });
  }
});

test('web 静态:路径穿越被挡', async () => {
  const { app, webRoot } = makeHarness();
  try {
    for (const url of ['/web/../package.json', '/web/%2e%2e/package.json', '/web/..%2fpackage.json']) {
      const response = await app.inject({ method: 'GET', url });
      assert.notEqual(response.statusCode, 200, `${url} 不该可达`);
      assert.ok(!response.body.includes('"name"'), `${url} 不该泄漏文件内容`);
    }
  } finally {
    rmSync(webRoot, { recursive: true, force: true });
  }
});
