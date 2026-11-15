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

export interface PairingOptions {
  /** true = 码来自环境变量,是长期固定的,配对成功后不轮换(单人自用场景) */
  fixed?: boolean;
  /** 同一来源在窗口内允许的失败次数,超过则 429;默认 5 次 / 60s */
  maxFailures?: number;
  failureWindowMs?: number;
}

/**
 * 配对码服务。两种模式:
 * - 一次性(默认):auto 生成,成功配对即轮换并打印新码
 * - 固定(环境变量给码):更像「长期密码」,不轮换;因此带失败限速防爆破
 */
export class PairingService {
  private code: string;
  private readonly fixed: boolean;
  private readonly maxFailures: number;
  private readonly failureWindowMs: number;
  private readonly failures = new Map<string, { count: number; resetAt: number }>();

  constructor(initialCode: string, options: PairingOptions = {}) {
    this.code = initialCode;
    this.fixed = options.fixed ?? false;
    this.maxFailures = options.maxFailures ?? 5;
    this.failureWindowMs = options.failureWindowMs ?? 60_000;
  }

  get current(): string {
    return this.code;
  }

  get isFixed(): boolean {
    return this.fixed;
  }

  verify(candidate: string): boolean {
    const a = Buffer.from(candidate, 'utf8');
    const b = Buffer.from(this.code, 'utf8');
    return a.length === b.length && timingSafeEqual(a, b);
  }

  /** 固定码不轮换;一次性模式返回新码,否则返回 null */
  rotate(): string | null {
    if (this.fixed) return null;
    this.code = generatePairingCode();
    return this.code;
  }

  isLocked(key: string): boolean {
    const entry = this.failures.get(key);
    if (!entry) return false;
    if (Date.now() > entry.resetAt) {
      this.failures.delete(key);
      return false;
    }
    return entry.count >= this.maxFailures;
  }

  registerFailure(key: string): void {
    const now = Date.now();
    const entry = this.failures.get(key);
    if (!entry || now > entry.resetAt) {
      this.failures.set(key, { count: 1, resetAt: now + this.failureWindowMs });
      return;
    }
    entry.count += 1;
  }

  resetFailures(key: string): void {
    this.failures.delete(key);
  }
}

export function registerPairingRoute(
  app: FastifyInstance,
  db: Db,
  pairing: PairingService,
): void {
  app.post('/v1/pair', async (request, reply) => {
    const source = request.ip;
    if (pairing.isLocked(source)) {
      throw new ApiError(429, 'too_many_attempts', '配对码错误次数过多,请 1 分钟后再试');
    }

    const parsed = PairBody.safeParse(request.body);
    if (!parsed.success) {
      throw new ApiError(400, 'validation_error', '请求体需要 {code, device_name?}');
    }
    if (!pairing.verify(parsed.data.code)) {
      pairing.registerFailure(source);
      throw new ApiError(401, 'invalid_pairing_code', '配对码错误');
    }
    pairing.resetFailures(source);

    const token = randomBytes(32).toString('base64url');
    const deviceId = randomUUID();
    const name = parsed.data.device_name?.trim() || '未命名设备';
    const ts = nowIso();
    db.prepare(
      'INSERT INTO device (id, name, paired_at, last_seen, token_hash) VALUES (?, ?, ?, ?, ?)',
    ).run(deviceId, name, ts, ts, sha256(token));

    const nextCode = pairing.rotate();
    if (nextCode !== null) {
      app.log.info(`设备已配对: ${name}。新配对码: ${nextCode}`);
    } else {
      app.log.info(`设备已配对: ${name}(配对码为固定模式,不轮换)`);
    }

    return reply.code(201).send({ device_id: deviceId, device_name: name, token });
  });
}

/**
 * 设备管理(吊销)。令牌只存 sha256,所以"吊销"= 把 token_hash 换成一个永远不可能
 * 撞上真实 sha256 的值(带 `revoked:` 前缀),并记 revoked_at 留痕;
 * 不删行,设备列表与审计还能看出这台机器来过。
 */
export function registerDeviceRoutes(app: FastifyInstance, db: Db): void {
  app.get('/v1/devices', async (request) => {
    const rows = db
      .prepare(
        `SELECT id, name, paired_at, last_seen FROM device
          WHERE revoked_at IS NULL ORDER BY last_seen DESC`,
      )
      .all() as Array<{ id: string; name: string; paired_at: string; last_seen: string | null }>;
    return {
      devices: rows.map((row) => ({ ...row, current: row.id === request.deviceId })),
    };
  });

  app.delete('/v1/devices/:id', async (request, reply) => {
    const { id } = request.params as { id: string };
    const result = db
      .prepare('UPDATE device SET token_hash = ?, revoked_at = ? WHERE id = ? AND revoked_at IS NULL')
      .run(`revoked:${id}`, nowIso(), id);
    if (result.changes === 0) throw new ApiError(404, 'device_not_found', '设备不存在或已吊销');
    return reply.code(204).send();
  });
}

const DEVICE_LOOKUP = 'SELECT id FROM device WHERE token_hash = ? AND revoked_at IS NULL';
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
