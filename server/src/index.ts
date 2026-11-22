import { pathToFileURL } from 'node:url';
import Fastify, { type FastifyInstance } from 'fastify';
import { ApiError, PairingService, makeAuthGuard, registerDeviceRoutes, registerPairingRoute } from './auth.js';
import { loadConfig, loadDotEnv, type Config } from './config.js';
import { DEV_CORS_HEADERS } from './cors.js';
import { openDb, purgeEphemeral, type Db } from './db.js';
import { registerAppRoutes } from './routes/app.js';
import { registerConversationRoutes, GenerationRegistry } from './routes/conversations.js';
import { registerFileRoutes } from './routes/files.js';
import { HarnessHub, registerHarnessBridge, registerHarnessRoutes } from './routes/harness.js';
import { registerMemoryRoutes } from './routes/memory.js';
import { registerModelKeyRoutes } from './routes/modelkey.js';
import { registerReminderRoutes } from './routes/reminders.js';
import { registerSearchRoutes } from './routes/search.js';
import { registerUsageRoutes } from './routes/usage.js';
import { registerVoiceRoutes } from './routes/voice.js';
import { registerWebRoutes } from './routes/web.js';

export interface AppContext {
  config: Config;
  db: Db;
}

const EPHEMERAL_SWEEP_MS = 24 * 60 * 60 * 1000;

/** 构造 Fastify 实例但不 listen —— 测试用 app.inject 直接打路由。 */
export function buildApp(
  ctx: AppContext,
  registry: GenerationRegistry = new GenerationRegistry(),
): FastifyInstance {
  const { config, db } = ctx;

  const app = Fastify({
    logger: config.logRequests ? { level: 'info' } : false,
    bodyLimit: Math.max(1024 * 1024, config.maxContentChars * 8),
  });

  app.decorateRequest('deviceId', null);

  // Fastify 默认对「Content-Type: application/json 但 body 为空」直接回 400。
  // 删除类接口本来就没有 body,客户端统一带 JSON 头时就会撞上,所以空 body 当 {}。
  // 非法 JSON 仍然报错(由下面的 errorHandler 转成 400)。
  app.addContentTypeParser('application/json', { parseAs: 'string' }, (_request, body, done) => {
    const raw = typeof body === 'string' ? body.trim() : '';
    if (raw === '') return done(null, {});
    try {
      done(null, JSON.parse(raw) as unknown);
    } catch {
      // 保持"非法 JSON = 400"的老行为:默认 SyntaxError 没有 statusCode,会被 errorHandler 归成 500
      const invalid = Object.assign(new Error('请求体不是合法 JSON'), {
        statusCode: 400,
        code: 'invalid_json',
      });
      done(invalid, undefined);
    }
  });

  // CORS 只在开发期放开(DEV_CORS,默认跟随 MOCK);生产部署必须为 0
  if (config.devCors) {
    app.addHook('onRequest', async (request, reply) => {
      for (const [name, value] of Object.entries(DEV_CORS_HEADERS)) reply.header(name, value);
      if (request.method === 'OPTIONS') reply.code(204).send();
    });
  }

  app.setErrorHandler((error: unknown, request, reply) => {
    if (error instanceof ApiError) {
      return reply.code(error.statusCode).send({ error: { code: error.code, message: error.message } });
    }
    // 只有 schema 校验失败才带 validation 数组;FastifyError 上该字段可能存在但为 undefined
    if (
      typeof error === 'object' &&
      error !== null &&
      Array.isArray((error as { validation?: unknown }).validation)
    ) {
      const message = error instanceof Error ? error.message : '请求体校验失败';
      return reply.code(400).send({ error: { code: 'validation_error', message } });
    }
    // Fastify 自身的客户端错误(415 不支持的 Content-Type、413 超限等)按原状态码透出
    if (typeof error === 'object' && error !== null && 'statusCode' in error) {
      const statusCode = Number((error as { statusCode: unknown }).statusCode);
      if (Number.isInteger(statusCode) && statusCode >= 400 && statusCode < 500) {
        const rawCode = 'code' in error ? (error as { code: unknown }).code : undefined;
        const code = typeof rawCode === 'string' ? rawCode : 'bad_request';
        const message = error instanceof Error ? error.message : '请求不合法';
        return reply.code(statusCode).send({ error: { code, message } });
      }
    }
    request.log.error({ err: error }, 'unhandled error');
    return reply.code(500).send({ error: { code: 'internal_error', message: '服务器内部错误' } });
  });

  app.get('/health', async () => ({ ok: true, mock: config.mock }));

  // v1.8.0:Web 端静态托管(公开,不鉴权;网页壳先加载才能配对)
  registerWebRoutes(app, config);

  const pairing = new PairingService(config.pairingCode, { fixed: config.pairingCodeFixed });
  registerPairingRoute(app, db, pairing);

  // M3:dsh 桥接(插件用 bridge token 出站接入,在设备鉴权之外)
  const harnessHub = new HarnessHub(db, config);
  registerHarnessBridge(app, harnessHub);

  // 除 /health 与 /v1/pair 外的所有路由都要 Bearer 设备令牌
  app.register(async (secured) => {
    secured.addHook('preHandler', makeAuthGuard(db));
    registerConversationRoutes(secured, ctx, registry);
    registerUsageRoutes(secured, ctx);
    await registerFileRoutes(secured, ctx);
    await registerVoiceRoutes(secured, { config, db, mock: config.mock });
    registerMemoryRoutes(secured, { db });
    registerReminderRoutes(secured, { db });
    registerSearchRoutes(secured, { db });
    registerModelKeyRoutes(secured, { db, config });
    registerDeviceRoutes(secured, db);
    registerAppRoutes(secured, config);
    registerHarnessRoutes(secured, harnessHub, config);
  });

  return app;
}

async function main(): Promise<void> {
  loadDotEnv();
  const config = loadConfig();
  const db = openDb(config.dbPath);
  const registry = new GenerationRegistry();
  const app = buildApp({ config, db }, registry);

  const purged = purgeEphemeral(db);
  if (purged > 0) app.log.info(`启动清扫:删除 ${purged} 个临时会话`);

  const sweep = setInterval(() => {
    try {
      const removed = purgeEphemeral(db);
      if (removed > 0) app.log.info(`每日清扫:删除 ${removed} 个临时会话`);
    } catch (error) {
      app.log.error({ err: error }, '临时会话清扫失败');
    }
  }, EPHEMERAL_SWEEP_MS);
  sweep.unref();

  await app.listen({ port: config.port, host: config.host });

  console.log('--------------------------------------------------');
  console.log(`鲸灵服务器已启动  http://${config.host}:${config.port}`);
  console.log(`模式              MOCK=${config.mock ? '1(假流,不调用真实 API)' : '0(真实 DeepSeek)'}`);
  console.log(`${config.pairingCodeFixed ? '配对码(固定)      ' : '一次性配对码      '}${config.pairingCode}`);
  console.log('配对              POST /v1/pair {"code":"<配对码>","device_name":"我的手机"}');
  console.log('--------------------------------------------------');

  const shutdown = async (signal: string): Promise<void> => {
    app.log.info(`收到 ${signal},正在关闭`);
    // 先中止所有在途生成:否则 open SSE 会让 server.close() 一直挂着,Docker 只能 SIGKILL
    registry.abortAll();
    try {
      await Promise.race([
        app.close(),
        new Promise((resolve) => setTimeout(resolve, 3000).unref()),
      ]);
    } finally {
      db.close();
      process.exit(0);
    }
  };
  process.on('SIGINT', () => void shutdown('SIGINT'));
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
}

const entry = process.argv[1];
if (entry !== undefined && import.meta.url === pathToFileURL(entry).href) {
  main().catch((error: unknown) => {
    console.error(error);
    process.exit(1);
  });
}
