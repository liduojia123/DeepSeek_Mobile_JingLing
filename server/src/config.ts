import { existsSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { z } from 'zod';

/** 运行时配置。env 只在这里解析一次,其余模块拿 Config 对象。 */
export interface Config {
  port: number;
  host: string;
  deepseekApiKey: string;
  deepseekBaseUrl: string;
  model: string;
  pairingCode: string;
  dbPath: string;
  mock: boolean;
  /** MOCK 流每段间隔,便于肉眼观察流式;测试里置 0 */
  mockDelayMs: number;
  priceInCnyPerMtok: number;
  priceOutCnyPerMtok: number;
  dailyBudgetCny: number;
  maxContentChars: number;
  maxToolLoops: number;
  /** 上游流式响应空闲超时:超过即放弃本轮,避免会话永久卡在 generating */
  upstreamTimeoutMs: number;
  logRequests: boolean;
}

const EnvSchema = z.object({
  PORT: z.string().optional(),
  HOST: z.string().optional(),
  DEEPSEEK_API_KEY: z.string().optional(),
  DEEPSEEK_BASE_URL: z.string().optional(),
  DEEPSEEK_MODEL: z.string().optional(),
  PAIRING_CODE: z.string().optional(),
  DB_PATH: z.string().optional(),
  MOCK: z.string().optional(),
  MOCK_DELAY_MS: z.string().optional(),
  PRICE_IN_CNY_PER_MTOK: z.string().optional(),
  PRICE_OUT_CNY_PER_MTOK: z.string().optional(),
  DAILY_BUDGET_CNY: z.string().optional(),
  MAX_CONTENT_CHARS: z.string().optional(),
  UPSTREAM_TIMEOUT_MS: z.string().optional(),
  LOG_REQUESTS: z.string().optional(),
});

/** Node 20.12+ 原生 .env 支持,不引入 dotenv 依赖。 */
export function loadDotEnv(path = '.env'): void {
  if (existsSync(path)) process.loadEnvFile(path);
}

const isOn = (v: string | undefined): boolean => v === '1' || v?.toLowerCase() === 'true';

const num = (v: string | undefined, fallback: number): number => {
  if (v === undefined || v.trim() === '') return fallback;
  const n = Number(v);
  if (!Number.isFinite(n)) throw new Error(`配置项不是合法数字: ${v}`);
  return n;
};

/** 一次性配对码:去掉易混淆字符,8 位足够个人自用场景。 */
export function generatePairingCode(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const bytes = randomBytes(8);
  return Array.from(bytes, (b) => alphabet[b % alphabet.length]).join('');
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const e = EnvSchema.parse(env);
  const mock = isOn(e.MOCK);
  const config: Config = {
    port: num(e.PORT, 3000),
    host: e.HOST?.trim() || '0.0.0.0',
    deepseekApiKey: e.DEEPSEEK_API_KEY?.trim() ?? '',
    deepseekBaseUrl: e.DEEPSEEK_BASE_URL?.trim() || 'https://api.deepseek.com',
    model: e.DEEPSEEK_MODEL?.trim() || 'deepseek-flash',
    pairingCode: e.PAIRING_CODE?.trim() || generatePairingCode(),
    dbPath: e.DB_PATH?.trim() || './data/jingling.db',
    mock,
    mockDelayMs: num(e.MOCK_DELAY_MS, 25),
    priceInCnyPerMtok: num(e.PRICE_IN_CNY_PER_MTOK, 0.5),
    priceOutCnyPerMtok: num(e.PRICE_OUT_CNY_PER_MTOK, 2),
    dailyBudgetCny: num(e.DAILY_BUDGET_CNY, 20),
    maxContentChars: num(e.MAX_CONTENT_CHARS, 100_000),
    maxToolLoops: 10,
    upstreamTimeoutMs: num(e.UPSTREAM_TIMEOUT_MS, 120_000),
    logRequests: e.LOG_REQUESTS?.trim() === '' || e.LOG_REQUESTS === undefined ? true : isOn(e.LOG_REQUESTS),
  };
  if (!config.mock && config.deepseekApiKey === '') {
    throw new Error('未配置 DEEPSEEK_API_KEY。开发阶段请设 MOCK=1,或把 key 写入 server/.env');
  }
  return config;
}
