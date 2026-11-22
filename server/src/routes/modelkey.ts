import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { clearApiKey, effectiveApiKey, keyHint, saveApiKey, storedApiKey } from '../apikey.js';
import { ApiError } from '../auth.js';
import type { Config } from '../config.js';
import type { Db } from '../db.js';

const PutBody = z.object({
  api_key: z.string().min(1).max(200),
});

/** 形状校验:DeepSeek key 都是 sk- 开头;真伪校验走 /models,两回事。 */
export function looksLikeApiKey(key: string): boolean {
  return key.startsWith('sk-') && key.length >= 16 && !/\s/.test(key);
}

/** 拿新 key 打一次 GET /models 验真(MOCK 下跳过;失败不落库)。 */
async function verifyApiKey(baseUrl: string, apiKey: string): Promise<void> {
  const response = await fetch(`${baseUrl.replace(/\/+$/, '')}/models`, {
    headers: { Authorization: `Bearer ${apiKey}` },
    signal: AbortSignal.timeout(8000),
  }).catch(() => {
    throw new ApiError(502, 'api_key_unreachable', '连不上 DeepSeek,无法校验 key');
  });
  if (response.status === 401 || response.status === 403) {
    throw new ApiError(400, 'api_key_invalid', 'key 无效,校验没有通过');
  }
  if (!response.ok) throw new ApiError(502, 'api_key_unreachable', 'DeepSeek 校验返回异常,稍后再试');
}

function statusOf(db: Db, config: Config) {
  const custom = storedApiKey(db) !== null;
  const active = effectiveApiKey(config, db);
  return {
    source: custom ? 'custom' : (config.deepseekApiKey === '' ? 'none' : 'default'),
    hint: keyHint(active),
  };
}

/**
 * v1.5.3:个人 DeepSeek API Key(设置页「服务器」区)。
 * 安全口径:响应永远只带尾号 hint,key 全文只存 app_setting 表,不进日志。
 */
export function registerModelKeyRoutes(app: FastifyInstance, ctx: { db: Db; config: Config }): void {
  const { db, config } = ctx;

  app.get('/v1/model-key', async () => statusOf(db, config));

  app.put('/v1/model-key', async (request) => {
    const parsed = PutBody.safeParse(request.body ?? {});
    if (!parsed.success) throw new ApiError(400, 'validation_error', '请求体格式错误');
    const key = parsed.data.api_key.trim();
    if (!looksLikeApiKey(key)) {
      throw new ApiError(400, 'api_key_invalid', 'key 看起来不对:应为 sk- 开头、至少 16 位');
    }
    if (!config.mock) await verifyApiKey(config.deepseekBaseUrl, key);
    saveApiKey(db, key);
    return statusOf(db, config);
  });

  app.delete('/v1/model-key', async (request, reply) => {
    clearApiKey(db);
    return reply.code(204).send();
  });
}
