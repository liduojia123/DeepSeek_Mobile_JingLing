# 从零部署(给执行者:人类或 AI)

> 目标:在一台**空白机器**上把鲸灵后端跑起来,让别人(或自己)的手机装上 App、填一个地址、配对成功、能真正对话。
> 本文件是**通用路径**;`docs/DEPLOY.md` 是某一台生产机的运维记录,里面的域名/端口/同机服务都是特例,**不要照抄**。
>
> 读法:按 0 → 14 顺序做,**每一步都有验证命令,验证不过就停**,按 §15 排障,不要猜。

## 0. 完工标准(做到这些才算部署完)

```bash
# 1) 服务活着
curl -s http://127.0.0.1:3000/health
#    → {"ok":true,"mock":false}
# 2) 能配对(用下面脚本,拿到 token)
# 3) 带 token 能列会话
#    → {"conversations":[...]}
# 4) 用 MOCK=1 跑通一整轮 SSE 对话(不花 key)
#    → 流里出现 message_end
# 5) 手机 App 填入公网地址 + 配对码 → 进入会话列表,发一条消息有回复
```

只做到 1) 不算部署完;5) 通过才算。

## 1. 先向用户确认这 5 件事(缺一个就问,不要默认)

| # | 要问的 | 为什么要问 | 常用默认 |
|---|---|---|---|
| 1 | `DEEPSEEK_API_KEY` 是什么? | 没有它只能 `MOCK=1` 假流 | 无默认,**必须用户给** |
| 2 | 用域名还是公网 IP? | 决定 §7 走哪条路 | 没域名 → IP + 端口 |
| 3 | 有没有已经装好的反向代理(Caddy/Nginx)? | 有就走子路径反代,没有就走 IP 直连 | 无 |
| 4 | 配对码要固定的还是一次性的? | 单人自用建议**固定但够长**(≥20 位随机) | 留空 = 一次性,启动时打印 |
| 5 | 要不要手机连电脑的 dsh 远程开发桥? | 不要就整段跳过 §11 | 不要 |

## 2. 选形态(三选一,后面步骤按选择走)

| 形态 | 适用 | 代价 |
|---|---|---|
| **A. 本机 node 直跑** | 先验证能不能用、内网自用 | 无守护进程,重启机器就没了;适合第一步 |
| **B. Docker Compose(推荐生产)** | 一台 VPS 长期跑 | 要装 Docker |
| **C. 已有反代 + 域名(生产最稳)** | 有 Caddy/Nginx 和证书 | 要配一条反代 + 关缓冲 |

## 3. 前置检查

```bash
uname -a                      # Linux x86_64 或 arm64 都行
node -v                       # 需要 ≥ v20.12;形态 A 必须有,形态 B 只在构建时需要
docker --version              # 形态 B 需要
docker compose version        # 需要 v2(命令是 docker compose,不是 docker-compose)
free -m                       # 内存 ≥ 1G(better-sqlite3 编译 + 运行)
df -h /                       # ≥ 2G 可用
```

任一项不满足 → **停下**,先装好再继续(better-sqlite3 是原生模块,缺 `python3 make g++` 会编译失败;Dockerfile 里已经装好了,形态 A 需要自己装)。

## 4. 拿代码

```bash
git clone https://github.com/liduojia123/DeepSeek_Mobile_JingLing.git jingling
cd jingling/server
```

只需要 `server/` 就能跑后端;`app/`(Flutter 客户端)、`bridge-dsh/`(dsh 插件)、`docs/` 不影响后端启动。

## 5. 生成 `server/.env`

```bash
cd jingling/server
cp .env.example .env
```

然后**逐项确认**下面这些(注释说明为什么):

```ini
PORT=3000
HOST=0.0.0.0
# 用户给的 key。只存在于本文件 / 服务器环境变量,绝不进代码、不进 git、不进日志
DEEPSEEK_API_KEY=<用户的 key>
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_MODEL=deepseek-flash
# 固定配对码:填一个 ≥20 位随机串(等同长期密码);留空 = 每次启动生成一次性码
PAIRING_CODE=<随机串>
# 形态 B 必须是容器内路径(见 §6B);形态 A 用 ./data/jingling.db
DB_PATH=./data/jingling.db
# 0 = 真实调用(必须有 key);1 = 假流(不花钱)。想先验链路就临时填 1,§8④ 通过后再改回 0
MOCK=0
DEV_CORS=0
DAILY_BUDGET_CNY=20
```

要点:

- `MOCK=0` 且 `DEEPSEEK_API_KEY` 为空 → 服务**启动即报错**(`未配置 DEEPSEEK_API_KEY`),这是故意的。
- `DEV_CORS=1` 只给浏览器调试(App 的 Web 版),**生产必须 0**,否则任意网页都能带着浏览器里的令牌打你的服务器。
- `PAIRING_CODE` 一旦是固定码,就带失败限速(同来源 60s 内错 5 次 → 429),但仍应该用长随机串:仓库是公开的,别人知道你的地址。

生成随机码:

```bash
head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-24
```

## 6. 起服务

### 6A. 本机 node 直跑

```bash
cd jingling/server
npm ci                 # 需要 python3 make g++ 编译 better-sqlite3
npm run build          # tsc → dist/
mkdir -p data
node dist/src/index.js
```

启动成功的标志(终端两行):

```
配对码(固定)      <你的码>      ← PAIRING_CODE 为空时显示「一次性配对码」
配对              POST /v1/pair {"code":"<配对码>","device_name":"我的手机"}
```

首次启动会自建 SQLite 表结构,文件在 `data/jingling.db`。

### 6B. Docker Compose(推荐)

```bash
cd jingling/server
# compose 用 env_file 读 .env,且容器内数据库必须在挂载卷里
sed -i 's#^DB_PATH=.*#DB_PATH=/app/data/jingling.db#' .env
mkdir -p data
docker compose up -d --build          # 首次 3–8 分钟(装编译工具链 + npm ci)
docker compose ps                      # 期望 STATUS 里有 (healthy)
docker compose logs --tail=20          # 找「配对码」两行
```

默认把容器绑在 **`127.0.0.1:3001`**(不直接暴露公网,前面放反代)。两个后果:

- 走 §7 的反代 → 保持原样,反代指 `127.0.0.1:3001`。
- 想用公网 IP 直连 → 改 `docker-compose.yml`:

```yaml
    ports:
      - "3000:3000"        # 原来是 "127.0.0.1:3001:3000"
```

然后 `docker compose up -d` 重建。**注意这是明文 HTTP**,令牌会裸奔,只建议临时/内网。

## 7. 让手机能连上(三种,按 §2 选择)

### 7A. 公网 IP + 端口(最快,无域名)

```bash
# 云厂商安全组放行 3000/TCP,本机防火墙也放
sudo ufw allow 3000/tcp 2>/dev/null || true
curl -s http://<公网IP>:3000/health        # 从另一台机器/手机浏览器验证
```

App 里填 `http://<公网IP>:3000`。

### 7B. 域名 + HTTPS 反代(生产)

Caddy(最省事,自动证书):

```caddyfile
ling.example.com {
    reverse_proxy 127.0.0.1:3001 {
        flush_interval -1        # ← 必须:否则 SSE 被缓冲,手机上看不到流式输出
    }
}
```

```bash
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy
curl -s https://ling.example.com/health    # → {"ok":true,...}
```

Nginx 等价配置(关键是关缓冲):

```nginx
location / {
    proxy_pass http://127.0.0.1:3001;
    proxy_http_version 1.1;
    proxy_set_header Connection '';
    proxy_buffering off;              # ← 必须
    proxy_read_timeout 3600s;         # 长连接 SSE
}
```

**路径前缀**(把服务挂在别人的域名下,例如 `https://host/jingling/`):反代要**剥前缀**再转发(Caddy 用 `handle_path /jingling/*`),App 里就填带前缀的完整地址 `https://host/jingling`(客户端会自己拼 `/v1/...`)。

App 里填 `https://ling.example.com`(有前缀就带上前缀,末尾斜杠可有可无)。

### 7C. 内网 / 本机调试(手机 USB 连着电脑)

```bash
adb reverse tcp:3000 tcp:3000     # 手机 localhost:3000 → 电脑 3000
```

App 里填 `http://127.0.0.1:3000`。仅调试,手机拔线就断。

## 8. 验证后端(四条,逐条过)

把地址设成变量,后面都用它:

```bash
BASE=http://127.0.0.1:3000       # 形态 B 若没改端口,这里是 127.0.0.1:3001
```

**① 健康检查**

```bash
curl -s $BASE/health
# {"ok":true,"mock":false}
```

**② 配对,拿设备令牌**

```bash
curl -s -X POST $BASE/v1/pair \
  -H 'Content-Type: application/json' \
  -d '{"code":"<配对码>","device_name":"部署验证"}'
# 201 {"device_id":"...","device_name":"部署验证","token":"..."}
```

把 `token` 存下来:

```bash
TOKEN=<上一步返回的 token>
```

失败对照:`401 invalid_pairing_code` = 码错;`429 too_many_attempts` = 一分钟内错太多次,等 60s。

**③ 带令牌访问受保护接口**

```bash
curl -s -H "Authorization: Bearer $TOKEN" $BASE/v1/conversations
# {"conversations":[]}      ← 空数组也是对的
```

**④ 跑一轮真实对话(建议先用 MOCK=1 验链路,再切 MOCK=0 花真钱)**

```bash
CID=$(curl -s -X POST $BASE/v1/conversations \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"title":"部署验证"}' | sed -E 's/.*"id":"([^"]+)".*/\1/')

curl -sN -X POST $BASE/v1/conversations/$CID/chat \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"content":"你好,报一下你的模型名"}'
```

期望:出现多行 `event:` / `data:`,最后有一条 `message_end`(它是唯一的终止事件;`error`/`safety_block` 只是过程信息)。中途断开 = 反代缓冲了 SSE(回 §7B 检查 `flush_interval -1` / `proxy_buffering off`)。

切真实 key:`sed -i 's/^MOCK=.*/MOCK=0/' .env` → 重启(`node` 直接 Ctrl+C 重启;docker 用 `docker compose up -d`,不用 `--build`)→ 重复 ①②④,回答应该来自真实模型。

## 9. 手机端

1. 装 APK:从 GitHub Releases 下最新 `jingling-<版本>.apk`(**仓库里没有 APK**,`build-release/` 已 gitignore)。首次安装要允许「安装未知应用」。
2. 打开 App → 配对页填地址(`§7` 里选的那个,**带不带尾部斜杠都行**,有路径前缀要带上)→ 填配对码 → 配对。
3. 进入会话列表,发一条消息,看到流式输出即完成。

客户端**不内置任何服务器地址和密钥**(默认值只是 `http://127.0.0.1:3000` 占位),所以同一个 APK 可以连任何一台自建服务器。

## 10. 可选:自己构建 release APK

只有当你要**自己的签名**或改包名时才需要;否则直接用 Releases 的包。

```bash
cd jingling/app
flutter --version                 # Flutter 3.50+
# 1) 造自己的签名(只做一次,丢了只能换签名重装)
keytool -genkeypair -v -keystore android/jingling-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias jingling
# 2) 写 android/key.properties(不入库,已在 .gitignore)
cat > android/key.properties <<'EOF'
storeFile=jingling-release.jks
storePassword=<你刚设的密码>
keyAlias=jingling
keyPassword=<同上>
EOF
# 3) 构建
flutter build apk --release --target-platform android-arm64
# 产物:app/build/app/outputs/flutter-apk/app-release.apk(约 18–19 MB)
```

`key.properties` 不放 `storeFile` 时 release 构建会失败(签名配置缺 `storeFile`)。另外:**换了签名就不能覆盖安装旧包**,先 `adb uninstall com.jingling.jingling`,并会清掉手机上已有的设备令牌(需重新配对)。

## 11. 可选:dsh 远程开发桥(手机看/操作电脑上的 dsh)

不需要就跳过整节;不做这一步 App 的普通对话照样能用。

1. 服务器 `.env` 加一行并重启:

```ini
BRIDGE_TOKEN=<48 位随机十六进制>
```
```bash
openssl rand -hex 24
```

2. 电脑端:装 dsh,装插件 `bridge-dsh/`(用 dsh 的 Plugins → Add plugin),写 `~/.dsh/jingling-bridge.json`:

```json
{
  "serverUrl": "https://ling.example.com",
  "bridgeToken": "<与服务器 BRIDGE_TOKEN 相同>",
  "nodeName": "我的电脑",
  "confirmTimeoutSec": 15
}
```

3. 验证节点上线:

```bash
curl -s -H "Authorization: Bearer $TOKEN" $BASE/v1/harness/nodes
# 期望里面 "online": true
```

4. 手机:会话列表页右上角「电脑」图标 → 选工作区/会话 → 派任务。

注意:桥接**只出站**,电脑不开任何入站端口;审批请求不带工具参数;超时 15s 未确认按拒绝处理(fail-closed)。

## 12. 可选:App 内 OTA(自己发版给手机)

```bash
# 在 compose 目录(部署目录)执行:APK 放数据卷,再写清单(./data 已挂进容器)
mkdir -p data/app
cp app-release.apk data/app/jingling.apk
cat > data/app/release.json <<'EOF'
{"version_code": 15, "version_name": "1.2.1", "notes": "本次更新说明", "published_at": "2026-11-17T10:00:00+08:00"}
EOF
curl -s -H "Authorization: Bearer $TOKEN" $BASE/v1/app/version
```

`version_code` 必须**大于**手机当前包的 versionCode(见 `app/pubspec.yaml` 的 `+N`),否则「检查更新」永远显示已是最新。

⚠️ 客户端「GitHub」更新源里硬编码了上游仓库地址([app/lib/core/update.dart](../app/lib/core/update.dart) 的 `_githubRepo`)。如果你 fork 后自建,记得改这个常量,否则手机会去查上游的 Releases,可能提示安装**别人签名**的 APK(装不上)。

## 13. 可选:备份与健康检查

仓库里 `deploy/` 有两个脚本,拷到服务器后**必须先改脚本里的路径**,再挂 cron:

```bash
scp deploy/backup.sh deploy/healthcheck.sh <user>@<host>:<部署目录>/     # 例如 /opt/jingling
```

`backup.sh` 顶部有 3 个写死的值,按实际部署改:

```bash
BACKUP_DIR=/opt/jingling/backups      # → <部署目录>/backups
DATA_DIR=/opt/jingling/data           # → <部署目录>/data
CONTAINER=jingling-jingling-1          # → 用 docker compose ps --format '{{.Name}}' 查真实容器名
```

`healthcheck.sh` 里两处也要改:`LOG` / `STATUS_FILE` 的路径,以及第 6 行探测的 `http://127.0.0.1:3001/health`(改成你实际的容器端口映射)。

然后:

```bash
crontab -e
# 30 3 * * *  <部署目录>/backup.sh
# */5 * * * * <部署目录>/healthcheck.sh
```

恢复:

```bash
docker compose stop
gunzip -c backups/jingling-YYYYmmdd-HHMMSS.db.gz > data/jingling.db
docker compose up -d && curl -s http://127.0.0.1:3001/health
```

## 14. 验收清单

| # | 检查 | 命令 / 动作 | 期望 |
|---|---|---|---|
| 1 | 服务活着 | `curl -s $BASE/health` | `{"ok":true,...}` |
| 2 | 无 key 不出错 | `.env` 里 `MOCK=0` 且 key 非空,重启 | 正常启动,日志有两行配对码 |
| 3 | 配对 | `POST /v1/pair` | 201 + token |
| 4 | 鉴权生效 | 不带 token 调 `/v1/conversations` | 401 |
| 5 | 列表 | 带 token 调 `/v1/conversations` | `{"conversations":[...]}` |
| 6 | SSE 不被缓冲 | `curl -sN .../chat` | 逐行流出 + `message_end` |
| 7 | 真实模型 | `MOCK=0` 后再跑一轮 | 回答合理,`usage` 有数值 |
| 8 | 手机端 | 装 APK → 填地址+码 → 发消息 | 流式回复 |
| 9 | 公网可达 | 手机用 4G(非同一 WiFi)再试 | 同上 |

## 15. 排障

| 现象 | 原因 | 检查 / 处理 |
|---|---|---|
| 启动即报 `未配置 DEEPSEEK_API_KEY` | `MOCK=0` 但 key 为空 | 填 key,或临时 `MOCK=1` |
| `EADDRINUSE` | 端口被占 | `ss -ltnp \| grep 3000`,换 `PORT` |
| 容器 `unhealthy` | 容器内 3000 没起来 | `docker compose logs --tail=50` |
| 手机连不上 | 地址/端口/安全组 | 先 `curl $BASE/health`,再查云厂商安全组 + 本机防火墙 |
| 手机能连但配对 401 | 用了一次性码且已轮换 | 看日志最新「一次性配对码」;或启用固定码 |
| 配对 429 | 一分钟内错 5 次 | 等 60 秒 |
| 流式卡住不动 | 反代缓冲 | Caddy `flush_interval -1`;Nginx `proxy_buffering off` |
| 日志里 `no such host` | DNS 没生效/证书没签下来 | 查 DNS 解析、Caddy 日志 |
| 上传文件 413 | 反代体积上限 | Caddy 默认不限;Nginx 设 `client_max_body_size 100m` |
| App「检查更新」查的是别人仓库 | `_githubRepo` 硬编码 | 见 §12 末尾 |
| `better-sqlite3` 编译失败(形态 A) | 缺工具链 | `apt install -y python3 make g++` |

## 16. 红线(不要为了「先跑起来」破坏这些)

1. **`DEEPSEEK_API_KEY` 不进代码、不进 git、不进日志、不进客户端**;只在 `.env` 或环境变量里。
2. **不要把容器/进程直接暴露在公网 3001 之外**还开 `DEV_CORS=1`;`DEV_CORS` 生产恒为 0。
3. **配对码不要用弱串**(如 `123456`);固定码等于长期密码,服务器端只是 5 次/分钟的限速。
4. **不要关掉鉴权或写死令牌**;所有 `/v1/*`(除 `/health`、`/v1/pair`)都要求 `Bearer` 设备令牌。
5. **数据库文件备份好**;`data/jingling.db` 是唯一数据源(含会话、消息树、用量、设备)。
6. 别把 `.env`、`key.properties`、`*.jks`、`.db` 提交进 git(都已在 `.gitignore`)。

## 17. 和其它文档的关系

| 文档 | 用途 |
|---|---|
| **本文件** | 通用从零部署(换机器、给别人、给 AI 执行) |
| `docs/DEPLOY.md` | 某一台生产机的运维记录:固定域名/端口、Caddy 特例、备份/OTA 实操 |
| `README.md` | 项目结构与本地开发速查 |
| `docs/ENVIRONMENT.md` | 工具链安装与本机踩坑记录 |
| `docs/DESIGN.md` | 协议与决策的唯一权威(改动前必读) |
