import { randomUUID } from 'node:crypto';
import multipart from '@fastify/multipart';
import type { FastifyInstance } from 'fastify';
import { ApiError } from '../auth.js';
import { effectiveApiKey } from '../apikey.js';
import type { Config } from '../config.js';
import { nowIso, type Db } from '../db.js';

/** 文档解析支持的格式(以文件实际内容判断,这里先按 MIME/扩展名粗筛) */
const DOC_MIME = new Set([
  'application/pdf',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-powerpoint',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/gif',
  'image/bmp',
  'image/tiff',
]);

/** 纯文本/表格/电子书:不需要解析,走 user_data(不计费) */
const TEXT_MIME = new Set([
  'text/plain',
  'text/markdown',
  'text/csv',
  'application/json',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-excel',
  'application/epub+zip',
]);

export type FilePurpose = 'text_recognition' | 'rich_layout_recognition' | 'user_data';

function normalizePurpose(raw: unknown, mime: string): FilePurpose {
  const requested = typeof raw === 'string' ? raw.trim() : '';
  if (requested === 'text_recognition' || requested === 'rich_layout_recognition' || requested === 'user_data') {
    return requested;
  }
  if (TEXT_MIME.has(mime)) return 'user_data';
  return 'text_recognition';
}

function isSupported(mime: string, name: string): boolean {
  if (DOC_MIME.has(mime) || TEXT_MIME.has(mime)) return true;
  // 有些浏览器/客户端对 Office 文件给出的 MIME 不准,按扩展名兜底
  return /\.(pdf|docx?|pptx?|png|jpe?g|webp|gif|bmp|tiff?|txt|md|csv|json|xlsx?|epub)$/i.test(name);
}

/**
 * 文件上传:M1 之后的 M2 能力。
 * 客户端把文件传给我们,我们转发给 DeepSeek Files API(解析是同步的,成功才返回 file_id),
 * 本地只记引用与状态——官方不支持下载原件或解析结果,所以不留档。
 */
export async function registerFileRoutes(
  app: FastifyInstance,
  ctx: { db: Db; config: Config },
): Promise<void> {
  const { db, config } = ctx;

  await app.register(multipart, {
    limits: {
      fileSize: config.fileMaxBytes,
      files: 1,
      fields: 10,
    },
  });

  app.post('/v1/files', async (request, reply) => {
    let part;
    try {
      part = await request.file();
    } catch (error) {
      if (String(error).includes('FST_REQ_FILE_TOO_LARGE')) {
        throw new ApiError(413, 'file_too_large', `文件超过 ${config.fileMaxBytes} 字节上限`);
      }
      throw new ApiError(400, 'invalid_file', '无法读取上传内容(multipart)');
    }
    if (!part) throw new ApiError(400, 'invalid_file', '缺少文件字段 file');

    const mime = part.mimetype || 'application/octet-stream';
    if (!isSupported(mime, part.filename ?? '')) {
      throw new ApiError(415, 'unsupported_file_type', `不支持的文件类型: ${mime}`);
    }

    let buffer: Buffer;
    try {
      buffer = await part.toBuffer();
    } catch (error) {
      if (String(error).includes('FST_REQ_FILE_TOO_LARGE') || String(error).includes('limit')) {
        throw new ApiError(413, 'file_too_large', `文件超过 ${config.fileMaxBytes} 字节上限`);
      }
      throw new ApiError(400, 'invalid_file', '读取上传内容失败');
    }
    if (buffer.length === 0) throw new ApiError(400, 'invalid_file', '文件内容为空');

    const purpose = normalizePurpose(request.query && (request.query as Record<string, unknown>).purpose, mime);
    const providerFileId = await uploadToProvider(
      config,
      buffer,
      part.filename ?? 'upload',
      mime,
      purpose,
      effectiveApiKey(config, db),
    );

    const id = randomUUID();
    db.prepare(
      `INSERT INTO file (id, conversation_id, name, mime, size, purpose, provider_file_id, parse_status, created_at)
       VALUES (?, NULL, ?, ?, ?, ?, ?, 'parsed', ?)`,
    ).run(id, part.filename ?? 'upload', mime, buffer.length, purpose, providerFileId, nowIso());

    return reply.code(201).send({
      file_id: id,
      name: part.filename ?? 'upload',
      mime,
      size: buffer.length,
      purpose,
      status: 'parsed',
    });
  });

  app.get('/v1/files/:id', async (request) => {
    const { id } = request.params as { id: string };
    const row = db
      .prepare('SELECT id, name, mime, size, purpose, parse_status, created_at FROM file WHERE id = ?')
      .get(id) as
      | {
          id: string;
          name: string;
          mime: string;
          size: number;
          purpose: string;
          parse_status: string;
          created_at: string;
        }
      | undefined;
    if (!row) throw new ApiError(404, 'file_not_found', '文件不存在');
    return {
      file_id: row.id,
      name: row.name,
      mime: row.mime,
      size: row.size,
      purpose: row.purpose,
      status: row.parse_status,
      created_at: row.created_at,
    };
  });
}

/** 转发到 DeepSeek Files API。purpose 必须在 file 之前写入(官方要求,实测顺序错会 400)。 */
async function uploadToProvider(
  config: Config,
  buffer: Buffer,
  filename: string,
  mime: string,
  purpose: FilePurpose,
  apiKey: string,
): Promise<string> {
  const form = new FormData();
  form.append('purpose', purpose);
  // 注意:不能写 new Uint8Array(buffer) —— Buffer 是共享内存池上的视图,
  // 那样会把整个 8KB 池当成文件内容上传。Uint8Array.from 会按视图实际长度拷一份。
  const bytes = Uint8Array.from(buffer);
  form.append('file', new Blob([bytes], { type: mime }), filename);

  const response = await fetch(`${config.deepseekBaseUrl.replace(/\/+$/, '')}/files`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}` },
    body: form,
  });

  if (!response.ok) {
    const detail = (await response.text().catch(() => '')).slice(0, 500);
    // 上游 400/413 基本都是文件本身的问题,原样透出给客户端
    throw new ApiError(
      response.status === 413 ? 413 : 400,
      'provider_upload_failed',
      `文件解析失败: ${detail || `上游返回 ${response.status}`}`,
    );
  }

  const json = (await response.json().catch(() => ({}))) as { id?: string };
  if (!json.id) throw new ApiError(502, 'provider_upload_failed', '上游未返回 file id');
  return json.id;
}
