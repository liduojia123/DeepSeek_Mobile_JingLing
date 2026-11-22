import { createReadStream, existsSync, statSync } from 'node:fs';
import { extname, join, normalize, sep } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { ApiError } from '../auth.js';
import type { Config } from '../config.js';

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.webp': 'image/webp',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.wasm': 'application/wasm',
};

/**
 * v1.8.0 Web 端静态托管:GET /web/* → config.webDir(flutter build web 产物)。
 * 不进鉴权作用域(网页壳先加载才能配对);SPA 回退:目录/无扩展名 → index.html。
 */
export function registerWebRoutes(app: FastifyInstance, config: Config): void {
  const root = normalize(config.webDir);

  const resolveSafe = (relative: string): string | null => {
    const target = normalize(join(root, relative));
    // 归一化后必须仍在托管目录内,挡 ../ 穿越
    if (target !== root && !target.startsWith(root + sep)) return null;
    return target;
  };

  const send = (reply: import('fastify').FastifyReply, path: string, cache: string): void => {
    const stat = statSync(path);
    reply.hijack();
    const raw = reply.raw;
    raw.writeHead(200, {
      'Content-Type': MIME[extname(path).toLowerCase()] ?? 'application/octet-stream',
      'Content-Length': String(stat.size),
      'Cache-Control': cache,
    });
    createReadStream(path).pipe(raw);
  };

  app.get('/web', async (request, reply) => {
    const index = resolveSafe('index.html');
    if (index === null || !existsSync(index)) throw new ApiError(404, 'web_not_deployed', 'Web 端尚未部署');
    send(reply, index, 'no-store');
  });

  app.get('/web/*', async (request, reply) => {
    const relative = (request.params as { '*': string })['*'] ?? '';
    const target = resolveSafe(relative);
    if (target === null) throw new ApiError(404, 'not_found', '文件不存在');

    if (existsSync(target) && statSync(target).isFile()) {
      const isIndex = extname(target).toLowerCase() === '.html';
      send(reply, target, isIndex ? 'no-store' : 'public, max-age=31536000, immutable');
      return;
    }
    // SPA 回退:无扩展名的路径(前端路由)交给 index.html;带扩展名的缺文件是真 404
    if (extname(target) === '') {
      const index = resolveSafe('index.html');
      if (index !== null && existsSync(index)) {
        send(reply, index, 'no-store');
        return;
      }
    }
    throw new ApiError(404, 'not_found', '文件不存在');
  });
}
