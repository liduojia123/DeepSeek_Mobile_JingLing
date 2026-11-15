import { createReadStream, existsSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { ApiError } from '../auth.js';
import type { Config } from '../config.js';

interface ReleaseManifest {
  version_code: number;
  version_name: string;
  notes?: string;
  published_at?: string;
}

/**
 * OTA:发布目录里放 `jingling.apk` + `release.json`(版本号/更新说明),
 * App 通过 /v1/app/version 比对 version_code,再走 /v1/app/download 下载安装。
 */
export function registerAppRoutes(app: FastifyInstance, config: Config): void {
  const manifestPath = join(config.appReleaseDir, 'release.json');
  const apkPath = join(config.appReleaseDir, 'jingling.apk');

  const readManifest = (): ReleaseManifest | null => {
    if (!existsSync(manifestPath)) return null;
    try {
      const parsed = JSON.parse(readFileSync(manifestPath, 'utf8')) as Partial<ReleaseManifest>;
      const versionCode = Number(parsed.version_code);
      const versionName = typeof parsed.version_name === 'string' ? parsed.version_name : '';
      if (!Number.isFinite(versionCode) || versionCode <= 0 || versionName === '') return null;
      return {
        version_code: versionCode,
        version_name: versionName,
        notes: typeof parsed.notes === 'string' ? parsed.notes : '',
        published_at: typeof parsed.published_at === 'string' ? parsed.published_at : undefined,
      };
    } catch {
      return null;
    }
  };

  app.get('/v1/app/version', async () => {
    const manifest = readManifest();
    if (manifest === null || !existsSync(apkPath)) {
      throw new ApiError(404, 'no_release', '服务器还没有发布 App 安装包');
    }
    const stat = statSync(apkPath);
    return {
      version_code: manifest.version_code,
      version_name: manifest.version_name,
      notes: manifest.notes ?? '',
      published_at: manifest.published_at ?? null,
      size: stat.size,
      download_path: '/v1/app/download',
    };
  });

  app.get('/v1/app/download', async (request, reply) => {
    if (!existsSync(apkPath)) throw new ApiError(404, 'no_release', '服务器还没有发布 App 安装包');
    const stat = statSync(apkPath);
    reply.hijack();
    const raw = reply.raw;
    raw.writeHead(200, {
      'Content-Type': 'application/vnd.android.package-archive',
      'Content-Length': String(stat.size),
      'Content-Disposition': 'attachment; filename="jingling.apk"',
      'Cache-Control': 'no-store',
    });
    createReadStream(apkPath).pipe(raw);
    return reply;
  });
}
