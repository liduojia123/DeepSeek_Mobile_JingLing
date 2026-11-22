import { randomUUID } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { ApiError } from '../auth.js';
import { effectiveApiKey } from '../apikey.js';
import type { Config } from '../config.js';
import { nowIso, type Db } from '../db.js';

/** ASR 音频上限:上游限制 8 MiB、120 秒 */
const ASR_MAX_BYTES = 8 * 1024 * 1024;
/** TTS 文本上限:上游限制 10,000 计费字符(汉字算 2) */
const TTS_MAX_TEXT = 10_000;

/** 上游语音接口返回(与 OpenAI 风格不同,这里只取需要的字段) */
interface AsrResponse {
  request_id?: string;
  text?: string;
  duration_ms?: number;
}

/** 汉字按 2 个计费字符计,其余(字母/数字/空格/标点)按 1 个。 */
export function billedTtsChars(text: string): number {
  let units = 0;
  for (const char of text) {
    units += /[\u3400-\u9fff\uf900-\ufaff]/.test(char) ? 2 : 1;
  }
  return units;
}

export interface VoiceContext {
  config: Config;
  db: Db;
  mock: boolean;
}

/**
 * M4 语音管道:
 * - POST /v1/asr  上传 16kHz WAV/Ogg Opus → 识别文本(上游 POST /v1/tools/asr,multipart)
 * - POST /v1/tts  文本 → 音频流(上游 POST /v1/tools/tts,audio/wav)
 * 两处都记账到 usage_log(kind=asr/tts)。
 */
export async function registerVoiceRoutes(app: FastifyInstance, ctx: VoiceContext): Promise<void> {
  const { config, db, mock } = ctx;
  const apiKey = (): string => effectiveApiKey(config, db);


  const insertUsage = db.prepare(
    `INSERT INTO usage_log (id, ts, kind, quantity, cost) VALUES (?, ?, ?, ?, ?)`,
  );

  app.post('/v1/asr', async (request) => {
    let buffer: Buffer;
    try {
      const part = await request.file();
      if (!part) throw new ApiError(400, 'invalid_audio', '缺少文件字段 file');
      buffer = await part.toBuffer();
    } catch (error) {
      if (error instanceof ApiError) throw error;
      if (String(error).includes('FST_REQ_FILE_TOO_LARGE')) {
        throw new ApiError(413, 'audio_too_large', '音频超过 8 MiB 上限');
      }
      throw new ApiError(400, 'invalid_audio', '无法读取上传音频(multipart)');
    }
    if (buffer.length === 0) throw new ApiError(400, 'invalid_audio', '音频内容为空');
    if (buffer.length > ASR_MAX_BYTES) throw new ApiError(413, 'audio_too_large', '音频超过 8 MiB 上限');

    if (mock) {
      const durationMs = 3000;
      insertUsage.run(randomUUID(), nowIso(), 'asr', durationMs / 1000, (durationMs / 1000) * config.asrPriceCnyPerSecond);
      return { text: 'MOCK 语音识别结果', duration_ms: durationMs };
    }

    const form = new FormData();
    form.append('file', new Blob([new Uint8Array(buffer)]), 'speech.wav');
    const response = await fetch(`${config.deepseekBaseUrl.replace(/\/+$/, '')}/v1/tools/asr`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey()}` },
      body: form,
    });
    if (!response.ok) {
      const detail = await response.text().catch(() => '');
      throw new ApiError(
        response.status >= 400 && response.status < 500 ? 400 : 502,
        'asr_failed',
        `语音识别失败(上游 ${response.status})${detail ? `: ${detail.slice(0, 160)}` : ''}`,
      );
    }
    const data = (await response.json()) as AsrResponse;
    const durationMs = Math.max(0, Number(data.duration_ms ?? 0)) || 0;
    const text = typeof data.text === 'string' ? data.text : '';
    insertUsage.run(
      randomUUID(),
      nowIso(),
      'asr',
      durationMs / 1000,
      (durationMs / 1000) * config.asrPriceCnyPerSecond,
    );
    return { text, duration_ms: durationMs };
  });

  app.post('/v1/tts', async (request, reply) => {
    const body = (request.body ?? {}) as Record<string, unknown>;
    const text = typeof body.text === 'string' ? body.text : '';
    if (text.trim() === '') throw new ApiError(400, 'validation_error', '需要非空 text');
    const units = billedTtsChars(text);
    if (units > TTS_MAX_TEXT) {
      throw new ApiError(400, 'text_too_long', `文本超过 ${TTS_MAX_TEXT} 计费字符上限`);
    }
    const voiceId = body.voice_id === 'tide' ? 'tide' : 'stella';

    if (mock) {
      // MOCK:返回 0.3 秒静音 WAV(44 字节头 + 静音数据),保证客户端播放链路可测
      const sampleRate = 16000;
      const seconds = 0.3;
      const dataSize = Math.floor(sampleRate * seconds) * 2;
      const wav = Buffer.alloc(44 + dataSize);
      wav.write('RIFF', 0);
      wav.writeUInt32LE(36 + dataSize, 4);
      wav.write('WAVE', 8);
      wav.write('fmt ', 12);
      wav.writeUInt32LE(16, 16);
      wav.writeUInt16LE(1, 20);
      wav.writeUInt16LE(1, 22);
      wav.writeUInt32LE(sampleRate, 24);
      wav.writeUInt32LE(sampleRate * 2, 28);
      wav.writeUInt16LE(2, 32);
      wav.writeUInt16LE(16, 34);
      wav.write('data', 36);
      wav.writeUInt32LE(dataSize, 40);
      insertUsage.run(randomUUID(), nowIso(), 'tts', units, units * config.ttsPriceCnyPerUnit);
      reply.header('Content-Type', 'audio/wav').send(wav);
      return reply;
    }

    const response = await fetch(`${config.deepseekBaseUrl.replace(/\/+$/, '')}/v1/tools/tts`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey()}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ text, voice_id: voiceId, format: 'wav', filter_markdown: true }),
    });
    if (!response.ok || !response.body) {
      const detail = await response.text().catch(() => '');
      throw new ApiError(
        response.status === 400 ? 400 : 502,
        'tts_failed',
        `语音合成失败(上游 ${response.status})${detail ? `: ${detail.slice(0, 160)}` : ''}`,
      );
    }

    insertUsage.run(randomUUID(), nowIso(), 'tts', units, units * config.ttsPriceCnyPerUnit);

    reply.hijack();
    const raw = reply.raw;
    raw.writeHead(200, {
      'Content-Type': 'audio/wav',
      'Cache-Control': 'no-store',
    });
    try {
      for await (const chunk of response.body as unknown as AsyncIterable<Uint8Array>) {
        raw.write(chunk);
      }
    } catch {
      // 上游中途断开:客户端会把提前结束的响应当失败处理
    } finally {
      raw.end();
    }
    return reply;
  });
}
