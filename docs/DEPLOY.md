# 生产部署手册(鲸灵后端)

> 服务器:腾讯云 Ubuntu 24.04(4C/3.6G),路径 `/opt/jingling`。
> 登录凭据放**仓库外**(仓库根的 `生产环境.md` 已被 gitignore,但更建议移出仓库)。
> 同一台机器还跑着 spendlens;两者共用 Caddy,鲸灵只占 `127.0.0.1:3001`。

## 拓扑

```
外网 ──HTTPS(8000)──▶ Caddy ──▶ 127.0.0.1:3001 ──▶ jingling 容器(node:24, PORT=3000)
                                                      └── SQLite: /opt/jingling/data/jingling.db (挂卷)
```

- **为什么是 8000**:域名备案未下,80/443 被 DNSPod 拦截,Caddy 配置了 `https_port 8000`(与 spendlens 共用)。备案通过后删掉 `https_port` 即可回到标准 443。
- **对外地址:`https://www.example.com:8000/jingling`**(复用 www 的既有证书,`handle_path /jingling/*` 剥前缀转发到 3001)。
- **为什么不是子域名**:ACME 证书校验只走标准端口 —— TLS-ALPN-01 连 443、HTTP-01 连 80,两个端口都被未备案拦截,所以 `ling.example.com` 签不出证书(spendlens 的证书是拦截生效前签发的)。8000 端口只能"用"证书,不能"签"证书。
- 备案通过后(或给 Caddy 装 DNSPod DNS-01 插件拿到 DNS API token)再切回子域名,客户端只需改服务器地址。
- 证书:Caddy + Let's Encrypt 自动续期,无需手工维护。

## 首次部署(已完成,留档)

```bash
# 本地打包源码(排除 node_modules/data)
tar -czf jingling-src.tar.gz -C DPAPP/server src package.json package-lock.json tsconfig.json
pscp -P 22222 jingling-src.tar.gz Dockerfile docker-compose.yml .dockerignore .env \
      ubuntu@<ip>:/home/ubuntu/jingling-deploy/

# 服务器侧
sudo mkdir -p /opt/jingling/data
cd /opt/jingling && sudo tar -xzf /home/ubuntu/jingling-deploy/jingling-src.tar.gz
sudo cp /home/ubuntu/jingling-deploy/{Dockerfile,docker-compose.yml,.dockerignore,.env} .
sudo chmod 600 .env && sudo chown -R ubuntu:ubuntu /opt/jingling
sudo docker compose up -d --build
```

Caddy 站点(`/etc/caddy/Caddyfile`):

```
www.example.com {
	handle_path /jingling/* {
		reverse_proxy 127.0.0.1:3001 {
			flush_interval -1     # SSE 必须关缓冲
		}
	}
	handle {
		reverse_proxy 127.0.0.1:8080   # spendlens
	}
}
```

改完 `sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && sudo systemctl reload caddy`。
DNS:`www.example.com` 已解析到本机;当前不需要新增记录(备案后再加 `ling`)。

## 日常运维

```bash
sudo docker compose -f /opt/jingling/docker-compose.yml ps          # 状态
sudo docker logs -f jingling-jingling-1                             # 日志(含一次性配对码)
curl -s http://127.0.0.1:3001/health                                # 容器内健康
sudo systemctl reload caddy                                         # 改 Caddy 后重载
```

**配对码**:`PAIRING_CODE` 留空 → 每次容器启动自动生成并打印。配对成功后旧码作废、轮换新码。
查看当前可用的码(最近一次打印):

```bash
sudo docker logs jingling-jingling-1 2>&1 | grep 配对码 | tail -1
```

**更新版本**:

```bash
# 本地重新打包 → 上传覆盖 /opt/jingling/src 与 package*.json
sudo docker compose -f /opt/jingling/docker-compose.yml up -d --build
```

**备份**(SQLite,建议每日 cron 到对象存储/另一台机器):

```bash
sudo docker exec jingling-jingling-1 node -e "
const D=require('better-sqlite3');const db=new D('/app/data/jingling.db');
db.exec(\"VACUUM INTO '/app/data/backup-'+Date.now()+'.db'\");"
```

(也可以直接复制 `/opt/jingling/data` 里的 `.db` + `-wal` 文件,但要在停容器或 `VACUUM` 后做才一致。)

## 密钥与安全

- `DEEPSEEK_API_KEY` 只存在于 `/opt/jingling/.env`(chmod 600),不进镜像、不进仓库、不进日志。
- 容器只绑 `127.0.0.1:3001`,公网只暴露 Caddy 的 8000(HTTPS)。
- 生产 `DEV_CORS=0`:浏览器跨域调试只在本地开。
- 设备令牌库里只存 sha256;桥接令牌(M3)与设备令牌分离。
- 服务器现状(用户要求暂不改):root 登录开放、密码登录开放、ufw 未启用。**建议后续**:加 SSH key、关密码登录、开 ufw + fail2ban。

## 排障

| 现象 | 排查 |
|---|---|
| 手机连不上 | `curl -sS https://www.example.com:8000/jingling/health`;先看 Caddy 日志有没有证书错误(DNS 没生效时是 `no such host`) |
| 流式卡住不更新 | Caddy 少了 `flush_interval -1`;或链路中间代理缓冲了 SSE |
| 容器 unhealthy | `sudo docker logs jingling-jingling-1`;看是否 `EADDRINUSE` 或 env 缺失 |
| 配对码无效 | 重启过容器会换码;用上面 `grep 配对码` 取最新 |
| 磁盘占用 | `docker system df`;镜像多了 `sudo docker image prune -f` |
