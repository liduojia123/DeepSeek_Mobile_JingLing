# 鲸灵 JingLing

> 当前进度与交接见 [docs/CURRENT.md](docs/CURRENT.md);设计以 [docs/DESIGN.md](docs/DESIGN.md) 为准。
> **部署到自己的服务器(换机器 / 别人 / 给 AI 执行)见 [docs/DEPLOY-FROM-SCRATCH.md](docs/DEPLOY-FROM-SCRATCH.md)。**

手机 APK 瘦客户端 + 自有服务器上的 Agent 大脑(DeepSeek 全家桶 API)+ dsh 远程开发桥(插件)。
个人自用、专业级标准。产品设计见 [`docs/DESIGN.md`](docs/DESIGN.md)(权威),施工单见 `docs/HANDOFF-*.md`。

## 架构

```
手机 App(Flutter) ──HTTPS+SSE──▶ 服务器(Node/Fastify) ──▶ DeepSeek API(对话/搜索/文件)
                                      │
                                      └── 电脑:dsh 桥插件(M3,outbound WS)
```

- Agent 大脑在服务器:客户端零密钥,只认自有 DPAPP 事件协议
- 数据在服务端:会话、消息树、分支、文件、用量;客户端只存服务器地址 + 设备令牌
- 协议单一来源:`server/src/deepseek/events.ts`(zod)↔ `app/lib/models/events.dart`

## 目录

```
server/           Node ≥20.12 + TS strict + Fastify 5 + better-sqlite3 + zod
  src/index.ts      启动、路由注册、CORS、临时会话清扫
  src/auth.ts       配对认证(令牌只存 sha256)
  src/db.ts         建表迁移
  src/routes/       会话/分支/SSE/文件/用量
  src/deepseek/     client(上游适配)、events(协议)、mock(无 key 假流)
  test/smoke.test.ts
app/              Flutter 3.50 + riverpod 3 + http + flutter_markdown
  lib/core/         配置、SSE 解析、API 封装、状态(providers)
  lib/models/       事件与消息树模型
  lib/pages/        配对 / 会话列表 / 对话 / 设置
  lib/widgets/      消息气泡、思考折叠、分支切换器、长按菜单
docs/             DESIGN、ENVIRONMENT、HANDOFF-*
```

## 快速开始

环境安装记录见 [`docs/ENVIRONMENT.md`](docs/ENVIRONMENT.md)(本机路径、踩过的坑)。

### 服务端

```bash
cd server
npm install
cp .env.example .env      # 填 DEEPSEEK_API_KEY;无 key 时保持 MOCK=1
npm run dev               # 控制台打印一次性配对码
```

- `MOCK=1`:不调用真实 API,输出等价假流,适合纯前端联调
- `MOCK=0`:真实调用(需 key);`DEV_CORS=1` 才能在浏览器里调试客户端
- 测试:`npm test`;类型检查:`npm run typecheck`

### 客户端

```bash
cd app
flutter run -d chrome     # Web 调试(需服务端 DEV_CORS=1)
flutter build apk --debug # 真机安装包
```

真机调试最快路径(USB 连着电脑时):

```bash
adb reverse tcp:3000 tcp:3000      # 手机 localhost:3000 → 电脑服务端
adb install -r app/build/app/outputs/flutter-apk/app-debug.apk
```

App 里服务器地址保持 `http://127.0.0.1:3000`,输入服务端控制台的配对码即可。

### 测试与检查

```bash
cd server && npm ci && npm run typecheck && npm test
cd app && flutter pub get && flutter analyze && flutter test
```

同样两条链(先装依赖再跑)就是发布前必须过的检查;`npm ci` 一步能同时验证 lockfile 是否可用。

## 关键约定

- **分支模型**:`message.parent_id` 构成消息树,`conversation.active_leaf_id` 是当前展示路径的叶子。
  编辑重发 = 在父节点下新建兄弟用户分支;重新生成 = 在用户消息下新建兄弟助手分支;
  切换分支 = `PATCH {active_leaf_id}`。`/chat` 的 `parent_message_id` 三种取值语义见 DESIGN §5.1。
- **SSE**:`message_end` 是唯一终止事件;`error`/`safety_block` 只是过程信息;
  服务端每 15s 发 `: ping` 注释行,客户端必须忽略。失败/中断也会落一条 assistant 消息(可能空正文)。
- **安全**:`DEEPSEEK_API_KEY` 只进 `server/.env`(已 gitignore);设备令牌库里只存 sha256;
  仓库根若出现 `apikey*.md` 之类文件已在 `.gitignore` 里,但仍建议放到仓库外。

## 已知环境坑

1. Angular 无关,但 **Flutter 3.50 起 `package:flutter/material.dart` 已废弃**,Material 用 `package:material_ui/material_ui.dart`。
2. **NDK 必须手动预装**:`sdkmanager --install "ndk/28.2.13676358"`,否则 `flutter build apk` 会因 AGP 用旧包名失败。
3. 新版 Android cmdline-tools 的 sdkmanager 已废弃、包名改斜杠(`platforms/android-36`、`build-tools/36.0.0`)。
4. 用静态服务器跑 `flutter build web` 时浏览器会缓存旧 `main.dart.js`;调试请用 `flutter run -d web-server`(自带 no-cache)。
5. 小米/红米真机装包,需要在开发者选项里打开「USB 安装」,否则 `INSTALL_FAILED_USER_RESTRICTED`;
   `adb shell input` 需要额外的「USB 调试(安全设置)」。

## 里程碑

| 阶段 | 状态 |
|---|---|
| M0 后端骨架 | ✅ 完成(配对/分支/SSE/文件/用量) |
| M1 客户端核心 | ✅ 完成(四页/流式/分支 UI,真机验证) |
| M2 搜索与文件 | ✅ 完成(搜索/读链接卡片、引用角标、PDF 问答、自动标题) |
| M3 dsh 远程开发桥 | ✅ 完成(工具调用逐条确认,fail-closed;手机端可切沙箱预设) |
| M4 语音 | ✅ 完成(ASR/TTS 接口、连续语音模式) |
| M5 工具与用量 | ✅ 完成(memory / http_request、每日预算熔断、用量页) |
| M6 打包发布 | ✅ 完成(release 18.3MB、应用内 OTA、服务器备份与健康检查) |

测试规模:server `npm test` 34 项、app `flutter test` 37 项(以 CI 徽章为准,数字随版本变)。

## 许可

MIT,见 [`LICENSE`](LICENSE)。
