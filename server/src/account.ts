import { createHash, randomBytes, randomInt, randomUUID, scryptSync, timingSafeEqual } from 'node:crypto';
import nodemailer from 'nodemailer';
import { ApiError } from './auth.js';
import type { Config } from './config.js';
import { nowIso, type Db } from './db.js';

// ---------- 密码(Node 内置 scrypt,零新算法依赖) ----------

export function hashPassword(password: string): string {
  const salt = randomBytes(16).toString('hex');
  const derived = scryptSync(password, salt, 32, { N: 16384, r: 8, p: 1 }).toString('hex');
  return `scrypt$16384$8$1$${salt}$${derived}`;
}

export function verifyPassword(password: string, stored: string): boolean {
  const parts = stored.split('$');
  if (parts.length !== 6 || parts[0] !== 'scrypt') return false;
  const [, n, r, p, salt, hash] = parts;
  let derived: Buffer;
  try {
    derived = scryptSync(password, salt, 32, { N: Number(n), r: Number(r), p: Number(p) });
  } catch {
    return false;
  }
  const expected = Buffer.from(hash, 'hex');
  return derived.length === expected.length && timingSafeEqual(derived, expected);
}

// ---------- 账号(单人:仅允许一个) ----------

export interface AccountRow {
  id: string;
  email: string;
  password_hash: string;
  email_verified: number;
  created_at: string;
}

export function findAccount(db: Db, email: string): AccountRow | undefined {
  return db.prepare('SELECT * FROM user_account WHERE email = ?').get(email.toLowerCase()) as
    | AccountRow
    | undefined;
}

export function countAccounts(db: Db): number {
  return (db.prepare('SELECT COUNT(1) AS n FROM user_account').get() as { n: number }).n;
}

export function createAccount(db: Db, email: string, passwordHash: string): AccountRow {
  const id = randomUUID();
  const ts = nowIso();
  db.prepare(
    'INSERT INTO user_account (id, email, password_hash, email_verified, created_at) VALUES (?, ?, ?, 0, ?)',
  ).run(id, email.toLowerCase(), passwordHash, ts);
  return findAccount(db, email)!;
}

export function markVerified(db: Db, email: string): void {
  db.prepare('UPDATE user_account SET email_verified = 1 WHERE email = ?').run(email.toLowerCase());
}

export function updatePassword(db: Db, email: string, passwordHash: string): void {
  db.prepare('UPDATE user_account SET password_hash = ? WHERE email = ?').run(passwordHash, email.toLowerCase());
}

// ---------- 验证码(只存哈希,一次性,限时) ----------

const CODE_TTL_MS = 10 * 60 * 1000;

export interface IssuedCode {
  id: string;
  /** 明文验证码:只在返回值/邮件里出现,不落库不进日志 */
  code: string;
}

export function issueCode(db: Db, email: string, kind: 'verify' | 'reset'): IssuedCode {
  const code = randomInt(0, 1_000_000).toString().padStart(6, '0');
  const id = randomUUID();
  const hash = createHash('sha256').update(code, 'utf8').digest('hex');
  const expires = new Date(Date.now() + CODE_TTL_MS).toISOString();
  // 同邮箱同用途只保留最新一条:旧的直接作废
  db.prepare('DELETE FROM auth_token WHERE email = ? AND kind = ? AND used_at IS NULL').run(
    email.toLowerCase(),
    kind,
  );
  db.prepare(
    'INSERT INTO auth_token (id, email, kind, code_hash, expires_at) VALUES (?, ?, ?, ?, ?)',
  ).run(id, email.toLowerCase(), kind, hash, expires);
  return { id, code };
}

/** 校验并消费验证码;失败返回原因(不区分过期/错码的细节也可以,这里给清楚点方便提示)。 */
export function consumeCode(db: Db, email: string, kind: 'verify' | 'reset', code: string): boolean {
  const row = db
    .prepare(
      'SELECT * FROM auth_token WHERE email = ? AND kind = ? AND used_at IS NULL ORDER BY expires_at DESC LIMIT 1',
    )
    .get(email.toLowerCase(), kind) as
    | { id: string; code_hash: string; expires_at: string }
    | undefined;
  if (row === undefined) return false;
  const hash = createHash('sha256').update(code.trim(), 'utf8').digest('hex');
  const a = Buffer.from(hash, 'hex');
  const b = Buffer.from(row.code_hash, 'hex');
  const matches = a.length === b.length && timingSafeEqual(a, b);
  const expired = Date.parse(row.expires_at) < Date.now();
  if (!matches || expired) return false;
  db.prepare('UPDATE auth_token SET used_at = ? WHERE id = ?').run(nowIso(), row.id);
  return true;
}

// ---------- 发信(MOCK 不真发,验证码走响应 debug_code) ----------

const subjects: Record<string, string> = {
  verify: '鲸灵:邮箱验证码',
  reset: '鲸灵:重置密码验证码',
};

export async function sendCodeMail(
  config: Config,
  email: string,
  kind: 'verify' | 'reset',
  code: string,
): Promise<void> {
  const text = `你的验证码是 ${code}(${kind === 'verify' ? '邮箱激活' : '重置密码'}),10 分钟内有效。`;
  if (config.mock) return; // MOCK:不发信,调用方把 code 放进响应 debug_code 供开发与测试
  if (config.smtpHost === '') {
    // 没配 SMTP 就别静默吞信(注册会卡在"码发不出"),明确告诉用户要配
    throw new ApiError(503, 'mail_not_configured', '服务器还没配 SMTP 邮箱,暂时无法发送验证码');
  }
  const transport = nodemailer.createTransport({
    host: config.smtpHost,
    port: config.smtpPort,
    secure: config.smtpPort === 465,
    auth: { user: config.smtpUser, pass: config.smtpPass },
  });
  await transport.sendMail({ from: config.mailFrom, to: email, subject: subjects[kind], text });
}
