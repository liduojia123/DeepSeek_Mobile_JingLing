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
  /** 配对码是否由 env 固定(固定则不轮换,等同长期密码;自动生成的是一次性) */
  pairingCodeFixed: boolean;
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
  /** 浏览器调试用 CORS(独立于 MOCK:真实 key 下也可能需要 flutter run -d chrome) */
  devCors: boolean;
  logRequests: boolean;

  // ---- M2:联网工具 / 文件 / 安全 / 标题 ----
  enableWebSearch: boolean;
  enableReadUrl: boolean;
  safetyLevel: 'off' | 'low' | 'high';
  titleEnabled: boolean;
  fileMaxBytes: number;
  /** 工具单价(元/次),按官方价填:搜索 5 元/千次、抓取 5 元/千次 */
  searchPriceCnyPerCall: number;
  fetchPriceCnyPerCall: number;
  /** 文档解析单价(元/页):OCR 1.5 元/千页 */
  ocrPriceCnyPerPage: number;

  // ---- M3:dsh 远程开发桥 ----
  /** 桥接令牌(与设备令牌分离);为空则桥接端点关闭 */
  bridgeToken: string;
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
  DEV_CORS: z.string().optional(),
  LOG_REQUESTS: z.string().optional(),
  ENABLE_WEB_SEARCH: z.string().optional(),
  ENABLE_READ_URL: z.string().optional(),
  SAFETY_LEVEL: z.string().optional(),
  TITLE_ENABLED: z.string().optional(),
  FILE_MAX_BYTES: z.string().optional(),
  SEARCH_PRICE_CNY_PER_CALL: z.string().optional(),
  FETCH_PRICE_CNY_PER_CALL: z.string().optional(),
  OCR_PRICE_CNY_PER_PAGE: z.string().optional(),
  BRIDGE_TOKEN: z.string().optional(),
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

const normalizeSafety = (v: string | undefined): 'off' | 'low' | 'high' => {
  const level = (v ?? '').trim().toLowerCase();
  if (level === 'off' || level === 'low' || level === 'high') return level;
  return 'high';
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
  const envPairingCode = e.PAIRING_CODE?.trim() ?? '';
  const config: Config = {
    port: num(e.PORT, 3000),
    host: e.HOST?.trim() || '0.0.0.0',
    deepseekApiKey: e.DEEPSEEK_API_KEY?.trim() ?? '',
    deepseekBaseUrl: e.DEEPSEEK_BASE_URL?.trim() || 'https://api.deepseek.com',
    model: e.DEEPSEEK_MODEL?.trim() || 'deepseek-flash',
    pairingCode: envPairingCode === '' ? generatePairingCode() : envPairingCode,
    pairingCodeFixed: envPairingCode !== '',
    dbPath: e.DB_PATH?.trim() || './data/jingling.db',
    mock,
    mockDelayMs: num(e.MOCK_DELAY_MS, 25),
    priceInCnyPerMtok: num(e.PRICE_IN_CNY_PER_MTOK, 0.5),
    priceOutCnyPerMtok: num(e.PRICE_OUT_CNY_PER_MTOK, 2),
    dailyBudgetCny: num(e.DAILY_BUDGET_CNY, 20),
    maxContentChars: num(e.MAX_CONTENT_CHARS, 100_000),
    maxToolLoops: 10,
    upstreamTimeoutMs: num(e.UPSTREAM_TIMEOUT_MS, 120_000),
    // 未显式配置时跟随 MOCK:mock 开发默认放开,真实部署默认关
    devCors: e.DEV_CORS === undefined || e.DEV_CORS.trim() === '' ? mock : isOn(e.DEV_CORS),
    logRequests: e.LOG_REQUESTS?.trim() === '' || e.LOG_REQUESTS === undefined ? true : isOn(e.LOG_REQUESTS),
    enableWebSearch: e.ENABLE_WEB_SEARCH === undefined || e.ENABLE_WEB_SEARCH.trim() === '' ? true : isOn(e.ENABLE_WEB_SEARCH),
    enableReadUrl: e.ENABLE_READ_URL === undefined || e.ENABLE_READ_URL.trim() === '' ? true : isOn(e.ENABLE_READ_URL),
    safetyLevel: normalizeSafety(e.SAFETY_LEVEL),
    titleEnabled: e.TITLE_ENABLED === undefined || e.TITLE_ENABLED.trim() === '' ? true : isOn(e.TITLE_ENABLED),
    fileMaxBytes: num(e.FILE_MAX_BYTES, 100 * 1024 * 1024),
    searchPriceCnyPerCall: num(e.SEARCH_PRICE_CNY_PER_CALL, 5 / 1000),
    fetchPriceCnyPerCall: num(e.FETCH_PRICE_CNY_PER_CALL, 5 / 1000),
    ocrPriceCnyPerPage: num(e.OCR_PRICE_CNY_PER_PAGE, 1.5 / 1000),
    bridgeToken: e.BRIDGE_TOKEN?.trim() ?? '',
  };
  if (!config.mock && config.deepseekApiKey === '') {
    throw new Error('未配置 DEEPSEEK_API_KEY。开发阶段请设 MOCK=1,或把 key 写入 server/.env');
  }
  return config;
}
