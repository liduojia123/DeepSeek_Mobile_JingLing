/**
 * dev(MOCK=1)才放开的 CORS 头。
 *
 * SSE 端点用 reply.hijack() + 手写 writeHead 绕过了 Fastify 的 reply 头管理,
 * 必须显式带上这些头,否则 flush 之后浏览器直接把整个流拦掉(Failed to fetch)。
 */
export const DEV_CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Authorization, Content-Type',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
};
