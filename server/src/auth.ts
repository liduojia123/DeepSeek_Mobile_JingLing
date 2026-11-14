import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { generatePairingCode, type Config } from './config.js';
import { nowIso, type Db } from './db.js';

declare module 'fastify' {
  interface FastifyRequest {
    deviceId: string | null;
  }
}

/** 统一 API 错误,由全局 errorHandler 转成 {error:{code,message}}。 */
export class ApiError extends Error {
  constructor(
    public readonly statusCode: number,
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

export const sha256 = (value: string): string =>
  createHash('sha256').update(value, 'utf8').digest('hex');

const PairBody = z.object({
  code: z.string().min(1),
  device_name: z.string().max(64).optional(),
});

/**
 * 一次性配对码:成功配对后立即轮换,旧码作废。
 * 轮换状态只在内存里 —— 重启会换新码并在控制台打印,符合「一次性」语义。
 */
export class PairingService {
  private code: string;

  constructor(initialCode: string) {
    this.code = initialCode;
  }

  get current(): string {
    return this.code;
  }

  verify(candidate: string): boolean {
    const a = Buffer.from(candidate, 'utf8');
    const b = Buffer.from(this.code, 'utf8');
    return a.length === b.length && timingSafeEqual(a, b);
  }

  rotate(): string {
    this.code = generatePairingCode();
    return this.code;
  }
}

export function registerPairingRoute(
  app: FastifyInstance,
  db: Db,
  pairing: PairingService,
): void {
  app.post('/v1/pair', async (request, reply) => {
    const parsed = PairBody.safeParse(request.body);
    if (!parsed.success) {
      throw new ApiError(400, 'validation_error', '请求体需要 {code, device_name?}');
    }
    if (!pairing.verify(parsed.data.code)) {
      throw new ApiError(401, 'invalid_pairing_code', '配对码错误');
    }

    const token = randomBytes(32).toString('base64url');
    const deviceId = randomUUID();
    const name = parsed.data.device_name?.trim() || '未命名设备';
    const ts = nowIso();
    db.prepare(
      'INSERT INTO device (id, name, paired_at, last_seen, token_hash) VALUES (?, ?, ?, ?, ?)',
    ).run(deviceId, name, ts, ts, sha256(token));

    const nextCode = pairing.rotate();
    app.log.info(`设备已配对: ${name}。新配对码: ${nextCode}`);

    return reply.code(201).send({ device_id: deviceId, device_name: name, token });
  });
}

const DEVICE_LOOKUP = 'SELECT id FROM device WHERE token_hash = ?';
const DEVICE_TOUCH = 'UPDATE device SET last_seen = ? WHERE id = ?';

/** 所有受保护路由的 preHandler:校验 Bearer 设备令牌,只比对 sha256。 */
export function makeAuthGuard(db: Db) {
  const lookup = db.prepare(DEVICE_LOOKUP);
  const touch = db.prepare(DEVICE_TOUCH);

  return async function authGuard(request: FastifyRequest): Promise<void> {
    const header = request.headers.authorization;
    if (!header || !header.startsWith('Bearer ')) {
      throw new ApiError(401, 'unauthorized', '缺少设备令牌');
    }
    const token = header.slice('Bearer '.length).trim();
    if (token === '') throw new ApiError(401, 'unauthorized', '设备令牌为空');

    const row = lookup.get(sha256(token)) as { id: string } | undefined;
    if (!row) throw new ApiError(401, 'unauthorized', '设备令牌无效');

    touch.run(nowIso(), row.id);
    request.deviceId = row.id;
  };
}
