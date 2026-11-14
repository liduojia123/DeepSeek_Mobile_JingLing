# 鲸灵(JingLing)施工单 · M0 后端骨架 + M1 客户端核心

> 执行者:DeepSeek Harness(dsh)· 前置阅读:`docs/DESIGN.md`(v1.1)与 `AGENTS.md`
> 范围:仅 M0 + M1。M2 及之后里程碑完成后另行出施工单。

## 第 0 步:环境检查

依次确认,缺则安装(brew / 官方安装器):

```bash
node --version          # 需 ≥ 20
npm --version
flutter --version       # 未安装:https://docs.flutter.dev/get-started/install/macos
java -version           # Android 构建需要
echo $ANDROID_HOME      # 有 Android SDK 则 M1 末尾可 build apk
```

Flutter 未就绪时,M1 先以 `flutter run -d chrome`(Web 调试目标)验证,APK 打包属 M6。

## 仓库结构(monorepo,从零创建)

```
DPAPP/                         # 目录代号保持 DPAPP;产品名 = 鲸灵 JingLing
├── docs/                        # 已有:DESIGN.md、本文件
├── AGENTS.md                    # 已有
├── server/                      # Node.js + TypeScript + Fastify
│   ├── package.json / tsconfig.json / .env.example / .gitignore
│   ├── src/
│   │   ├── index.ts             # Fastify 启动、路由注册、dev CORS、临时会话清扫
│   │   ├── config.ts            # env 加载(zod):PORT / DEEPSEEK_API_KEY / PAIRING_CODE / DB_PATH / MOCK
│   │   ├── db.ts                # better-sqlite3 建表迁移
│   │   ├── auth.ts              # 配对端点 + Bearer 设备令牌中间件
│   │   ├── routes/
│   │   │   ├── conversations.ts # CRUD、PATCH、chat SSE、stop
│   │   │   └── usage.ts         # 用量统计
│   │   ├── deepseek/
│   │   │   ├── client.ts        # Chat Completions 流式调用
│   │   │   ├── events.ts        # zod 定义 DPAPP SSE 事件协议 + 归一化
│   │   │   └── mock.ts          # MOCK=1 假事件流(无 key 可开发验证)
│   │   └── agent/
│   │       └── loop.ts          # M0 直通骨架(M5 接工具)
│   └── test/smoke.ts            # 冒烟测试
└── app/                         # Flutter
    ├── pubspec.yaml
    └── lib/
        ├── main.dart            # riverpod 入口、路由
        ├── core/
        │   ├── config.dart      # 服务器地址(安全存储持久化)
        │   ├── sse_client.dart  # SSE 逐行解析(event:/data:)
        │   └── api.dart         # pair / conversations / chat 封装
        ├── models/events.dart   # DPAPP SSE 事件类型(与 server zod schema 逐字段同步)
        ├── pages/               # pair_page / conversations_page / chat_page / settings_page
        └── widgets/             # message_bubble / thinking_block / branch_switcher / message_menu
```

技术栈锁定:server = Fastify + better-sqlite3 + zod + TypeScript(strict);app = riverpod + http + flutter_secure_storage + flutter_markdown。不引入其他重量级框架。

## 消息分支设计(M0 建表时必须一次到位)

- `message.parent_id` 构成消息树;`conversation.active_leaf_id` 指向当前活跃叶子,**沿 parent 回溯即客户端展示的线性路径**
- 语义:
  - **编辑重发**:客户端对历史用户消息修改后发送 `{parent_message_id, content}` → 服务端在该父节点下新建**兄弟用户分支**及其回答;旧分支保留不删
  - **重新生成**:对助手消息发送 `{parent_message_id, regenerate:true}` → 在同一用户消息下新建**兄弟助手分支**
  - **切换分支**:客户端渲染活跃路径时,凡有兄弟分支持处显示 `‹ n/m ›`;切换 = `PATCH /v1/conversations/{id} {active_leaf_id}`,后续对话接在新活跃路径末尾
- `GET /v1/conversations/{id}` 返回全树(节点含 children)+ active_leaf_id;客户端据此渲染
- 会话 `pinned`(置顶)/ `ephemeral`(临时对话):临时会话不在列表默认查询中出现,服务启动时与每日清扫删除
- 消息长按菜单 v1 仅复制/删除;"朗读此回答"入口随 M4 TTS 加入

## M0 后端步骤

1. **脚手架**:`server/` npm 项目 + TS strict + Fastify + better-sqlite3 + zod;`.env.example`(PORT、DEEPSEEK_API_KEY、PAIRING_CODE、DB_PATH、MOCK);git init 与根 `.gitignore`(node_modules、.env、*.db、Flutter 构建产物)
2. **建表**:按 DESIGN §5.2(device / conversation / message / usage_log;**分支字段必须含**;memory_note、harness_* 留到 M5/M3)
3. **认证**:`PAIRING_CODE` 首次启动自动生成并打印到控制台;`POST /v1/pair {code, device_name}` 校验后返回设备令牌(明文仅此一次,库存 sha256);其余所有路由过 `Authorization: Bearer` 中间件
4. **会话路由**:`GET/POST /v1/conversations`、`GET/DELETE/PATCH /v1/conversations/{id}`(PATCH 支持 title/pinned/ephemeral/active_leaf_id)
5. **DeepSeek 适配层**:
   - `client.ts`:`POST https://api.deepseek.com/chat/completions`,model=`deepseek-flash`,`stream:true`,`thinking:{"type":"enabled"}`,解析 SSE 增量;思考内容在 Chat Completions 下以 `reasoning_content` 增量出现——以真实 API 响应为准做兼容解析,遇到与文档不符的字段以实测为准并注释
   - `events.ts`:**协议单一来源**,zod schema 定义 DESIGN §5.1 全部事件;文件顶部注释注明"修改此文件必须同步 `app/lib/models/events.dart`"
   - `mock.ts`:`MOCK=1` 时输出等价假流(至少含 thinking_delta×N → text_delta×N → message_end,带 usage),供无 key 开发与测试
6. **核心 SSE 端点**:`POST /v1/conversations/{id}/chat`,三种入参(普通 / 编辑重发 / 重新生成,见分支设计);流程:落库用户消息 → 开 DeepSeek 流 → 逐事件转发 → **内存累积 blocks,`message_end` 一次性落库** assistant 消息(含 thinking、引用、tool_traces、usage)与 usage_log;`POST .../stop` 中断流、落库已收部分并标 `stop_reason:"interrupted"`;`GET /v1/usage` 按天汇总 tokens 与费用
7. **验证**(见下方清单)

## M1 Flutter 步骤

1. `flutter create app --project-name jingling --org com.jingling`;应用显示名设为「鲸灵」(Android label 等);加入上述依赖
2. **core 层**:`config.dart` 服务器地址入 flutter_secure_storage;`sse_client.dart` 用 http streamed response 逐行解析 `event:`/`data:`(注意 CRLF 与多行 data);`api.dart` 封装 pair/conversations/chat/stop/PATCH
3. **页面**:
   - Pair:输入一次性配对码 → 存设备令牌 → 进会话列表
   - Conversations:置顶区在前,长按重命名/删除/置顶,"临时对话"新建入口,下拉刷新
   - Chat(核心):消息流渲染 = 思考折叠区(实时增长,默认收起/展开可切)→ 工具过程卡片 → 正文 markdown 流式追加 → 引用列表;发送/停止按钮;**分支 UI**:`‹ n/m ›` 切换器、自己消息"编辑重发"(弹出编辑框确认后走 parent_message_id 发送)、助手消息"重新生成";长按菜单复制/删除
   - Settings:改服务器地址、解除配对、用量入口
4. **事件模型**:`models/events.dart` 与 server `events.ts` zod schema 逐字段同步
5. **验证**(见下方清单)
6. 若本机有 Android SDK:`flutter build apk` 出包试装(非阻塞项)

## 端到端验证清单

1. **MOCK 全链路**:`MOCK=1 npm run dev` 后 curl 依次:
   - `POST /v1/pair` 错误码与正确码各一次 → 拿到设备令牌
   - `POST /v1/conversations` → 建会话
   - `POST /v1/conversations/{id}/chat` → 肉眼核对 SSE 事件序列符合 DESIGN §5.1
   - 对某条用户消息编辑重发 → `GET` 会话可见兄弟分支 → `PATCH active_leaf_id` 切换 → 再 chat 时上下文接新路径
   - 新建临时会话 → 列表查询不出现 → 重启服务后被清扫
   - `GET /v1/usage` 有记录
2. **真实 key**:server `.env` 填入 `DEEPSEEK_API_KEY`(由用户提供)复测,确认思考流与正文流真实到达、usage 落库
3. **Flutter 全流程**:连本地 server(MOCK=1),Chrome/真机完成 配对→新建→流式对话→编辑重发→分支切换→临时对话→停止生成
4. **冒烟测试**:`npm test` 覆盖:事件归一化快照、配对+令牌校验、消息树往返(建分支/切叶子后 GET 树正确)

## 关键实现要点

- SSE 转发期间 blocks 在内存累积,`message_end` 一次性落库,避免半截消息污染存储
- 协议改动必须双侧同步:server `src/deepseek/events.ts`(zod)↔ app `lib/models/events.dart`
- CORS 仅 dev 模式(MOCK=1)放开;错误统一走 `event: error`
- 每日预算字段预留(DAILY_BUDGET_CNY),M5 启用熔断
- 开发期走 `http://IP:PORT`(域名备案中;HTTPS/证书锁定属 M6 部署期,不在本单范围)
- 完成定义(DoD):验证清单 1、3、4 全绿;2 需用户提供 key 后补测;在 `docs/DESIGN.md` §10 决策记录表追加一行"M0+M1 完成 <日期>"
