/**
 * 时间工具(M7 提醒)。
 *
 * 提醒的关键是"现在几点":模型要把「20 分钟后」「明天 8 点」换算成绝对时间。
 * 服务器容器可能是 UTC,所以所有面向用户的格式化都显式走 Asia/Shanghai,
 * 存储一律用 UTC ISO(字符串排序即时间序)。
 */

export const REMINDER_TZ = 'Asia/Shanghai';

interface ShanghaiParts {
  year: string;
  month: string;
  day: string;
  hour: string;
  minute: string;
  second: string;
}

function shanghaiParts(date: Date): ShanghaiParts {
  const formatted = new Intl.DateTimeFormat('en-CA', {
    timeZone: REMINDER_TZ,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  }).formatToParts(date);
  const pick = (type: Intl.DateTimeFormatPartTypes): string =>
    formatted.find((part) => part.type === type)?.value ?? '00';
  return {
    year: pick('year'),
    month: pick('month'),
    day: pick('day'),
    hour: pick('hour') === '24' ? '00' : pick('hour'),
    minute: pick('minute'),
    second: pick('second'),
  };
}

/** 该时刻在 Asia/Shanghai 的偏移,形如 +08:00。 */
function shanghaiOffset(date: Date): string {
  const label = new Intl.DateTimeFormat('en-US', {
    timeZone: REMINDER_TZ,
    timeZoneName: 'longOffset',
  })
    .formatToParts(date)
    .find((part) => part.type === 'timeZoneName')?.value;
  const matched = /GMT([+-]\d{2}:\d{2})/.exec(label ?? '');
  return matched?.[1] ?? '+08:00';
}

/** 当前时间,带 +08:00 偏移,例如 2026-11-17T21:26:11+08:00。 */
export function nowShanghaiIso(now: Date = new Date()): string {
  const p = shanghaiParts(now);
  return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}:${p.second}${shanghaiOffset(now)}`;
}

/** 给模型的时间上下文(每次请求放在最前面的 system 消息)。 */
export function timeContextLine(now: Date = new Date()): string {
  return `当前时间:${nowShanghaiIso(now)}(Asia/Shanghai)。用户说「20 分钟后」「明天 8 点」等相对时间时以此为准。`;
}

/** 任意可解析的时间 → UTC ISO(存储用);解析失败返回 null。 */
export function toUtcIso(input: string): string | null {
  const ms = Date.parse(input.trim());
  if (!Number.isFinite(ms)) return null;
  return new Date(ms).toISOString();
}

/** 面向用户的简短时间,如 11-17 20:30(按 Asia/Shanghai 显示)。 */
export function formatShanghai(iso: string): string {
  const ms = Date.parse(iso);
  if (!Number.isFinite(ms)) return iso;
  const p = shanghaiParts(new Date(ms));
  return `${p.month}-${p.day} ${p.hour}:${p.minute}`;
}
