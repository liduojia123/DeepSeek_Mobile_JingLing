# 鲸灵后端生产镜像:多阶段构建(编译 TS → 只带运行时依赖)
# 服务器在腾讯云,默认走内网 apt 镜像 + npmmirror,海外部署可覆盖这两个 ARG。

FROM node:24-bookworm-slim AS deps
ARG APT_MIRROR=mirrors.tencentyun.com
ARG NPM_REGISTRY=https://registry.npmmirror.com

# better-sqlite3 在 Linux 上需要 node-gyp 工具链(除非命中预编译包)
RUN if [ -n "${APT_MIRROR}" ]; then \
      sed -i "s#deb.debian.org#${APT_MIRROR}#g; s#security.debian.org#${APT_MIRROR}#g" /etc/apt/sources.list.d/debian.sources 2>/dev/null || true; \
    fi \
 && apt-get update \
 && apt-get install -y --no-install-recommends python3 make g++ ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm config set registry "${NPM_REGISTRY}" && npm ci

FROM deps AS build
COPY tsconfig.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM node:24-bookworm-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
RUN mkdir -p /app/data
EXPOSE 3000
CMD ["node", "dist/src/index.js"]
