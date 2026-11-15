# 鲸灵 JingLing · 个人全能 AI Agent — 项目设计文档

> 产品名:**鲸灵(JingLing)** · 目录代号 DPAPP 保留(历史路径,不影响命名)

> 状态:v1.1(2026-11-14)· 产品、架构、技术栈、功能范围全部敲定
> 本文档是开发输入,配合 `docs/HANDOFF-M0-M1.md`(施工单)与 `AGENTS.md`(工作规范)使用。

## 1. 产品定位

**一句话**:鲸灵——跑在手机上的个人专属 AI Agent(鲸 = DeepSeek 血统,灵 = 随身精灵),能力对齐 DeepSeek 官方 App(联网搜索、文件、语音),具备真正的 agent 能力(多步规划、工具调用、执行任务),并且能**远程指挥电脑上的 DeepSeek Harness(dsh)开发项目**;由自己的服务器驱动。

**原则**:
- 专业开发,不是玩具:架构、安全、可观测性、成本护栏从第一天就做对
- API key 只存在于服务器,客户端不持有任何密钥
- 单用户设计(个人自用),但架构预留多客户端扩展(手机 / 网页)

## 2. 总体架构

```
┌─────────────┐  HTTPS+SSE   ┌──────────────────────┐   HTTPS   ┌──────────────┐
│  手机 APK    │ ◄─────────► │  个人服务器            │ ◄───────► │  DeepSeek API │
│  (瘦客户端)  │              │  · Agent 运行时       │           │  · Messages/  │
│  会话 UI     │              │  · 工具执行器         │           │    Chat API   │
│  录音/播放   │              │  · 会话存储/文件      │           │  · OCR/ASR/   │
│  文件选择    │              │  · 密钥/用量/风控     │           │    TTS/Search │
└─────────────┘              │  · dsh 桥接中继(M3)  │           └──────────────┘
                             └──────────▲───────────┘
                                        │ outbound WS(M3)
                             ┌──────────┴───────────┐
                             │ 电脑:dsh 桥插件       │
                             │ (跑在 dsh 运行时内部) │
                             └──────────────────────┘
```

**关键决策 A:Agent 大脑放在服务器端,客户端只做 UI。**

理由:
1. key 安全(客户端零密钥,符合已定原则)
2. 自定义工具在服务器执行才有想象空间(跑代码、访问个人服务、读写数据库)
3. 会话/文件/用量天然持久化,换手机不丢数据
4. 将来加网页端客户端,agent 层一行不用改

**关键决策 B:客户端与服务器之间定义自有协议,服务器与 DeepSeek 之间做适配层。**
DeepSeek 有 Messages / Responses / Chat Completions 三种接口,后端统一封装,客户端只认识 DPAPP 自己的事件协议(§5.1)。DeepSeek 改接口或换模型,客户端不用动。

## 3. 功能规格

### v1(MVP)— P0

| # | 功能 | 规格 |
|---|---|---|
| F1 | 会话管理 | 多会话列表、历史消息服务端存储、自动生成标题、删除 |
| F2 | 流式对话 | SSE 流式输出;思考过程(thinking)实时展示、可折叠;正文 markdown + 代码高亮 |
| F3 | 联网搜索 | 服务端工具 `deepseek_web_search`;非思考=普通搜索,思考模式=深度思考搜索;搜索动作与结果以过程卡片展示;正文引用角标 + 引用列表 |
| F4 | 读链接 | 服务端工具 `deepseek_read_url`;用户消息含 URL 时自动抓取 |
| F5 | 文件输入 | 上传 PDF / Office / 图片;服务端解析(文件输入接口 / OCR);解析结果入上下文;UI 显示文件卡片与解析状态 |
| F6 | 语音对话 | 按住说话→录音上传→ASR→文字确认(可一键直接发送)→对话→TTS→播放;可打断播放 |
| F7 | 模型安全 | 全链路开启安全校验参数,命中风险时展示拒答标识 |
| F8 | Agent 工具 v1 | `memory`(个人记忆,存 SQLite)+ `http_request`(域名白名单调用个人服务),见 §4 |
| F9 | 用量看板 | token 用量、工具调用次数、估算费用(按天/按会话) |
| F10 | 配对认证 | 首次启动输一次性配对码→换取设备令牌,存系统安全存储 |
| F11 | 消息编辑/重新生成/分支导航 | 消息可编辑重发、助手回答可重新生成;同一位置多版本以兄弟分支保存,`‹ n/m ›` 左右切换;切换后对话接在新活跃路径末尾(设计见 HANDOFF §分支) |
| F12 | 基础操作包 | 会话置顶/重命名;临时对话(不留历史);消息长按菜单:复制/删除(朗读入口随 M4 TTS 加入) |
| F13 | dsh 远程开发(完整控制) | 手机查看电脑 dsh 工作区/会话→派任务→实时输出流→**工具调用确认卡片(批准/拒绝)**→停止/追问;架构见 §4.4,M3 实施 |

### v1.5 — P1(v1 稳定后)

| # | 功能 | 说明 |
|---|---|---|
| G1 | `run_code` 代码执行沙箱 | Docker 隔离、无网络、限时限资源;算数、数据处理、画图 |
| G2 | 记忆管理 UI | 查看/编辑/删除 memory 工具沉淀的每一条记忆,透明可控 |
| G3 | 拍照/相册提问 | 复用 F5 图片解析,补相机入口 |

### v2 — P2(架构预留)

- 网页端客户端(复用同一后端)
- 全局对话搜索 / 文件夹
- 手机原生工具桥:日历、闹钟、剪贴板、系统通知 + 推送提醒(FCM/APNs)
- 个人知识库 RAG(文档长期沉淀 + 检索)
- 连续语音对话(免按住)

### 明确暂不做(2026-11-14 拍板)

建议追问 chips、提示词模板库、自定义指令/人设、系统分享集成、导出/分享对话、生图(DeepSeek 无生图 API,接入第三方另议)、GPTs 商店形态、Canvas 工作区。

## 4. Agent 设计

### 4.1 运行循环

```
用户输入 → 服务器 Agent 运行时:
  1. 组装上下文(历史活跃路径 + 文件解析内容 + 工具定义)
  2. 调用 DeepSeek(思考模式,stream=true)
  3. 模型若返回 tool_calls → 执行自定义工具 → 结果回传 → 回到 2
     (服务端工具 search/read_url 由 DeepSeek 自动执行,SSE 中收到过程事件)
  4. 收到最终回答 → 落库 → 结束流
  循环上限:N 轮(默认 10,可配),超限向用户说明
```

### 4.2 工具清单

**服务端工具(DeepSeek 自动执行,零维护)**:`deepseek_web_search`、`deepseek_read_url`

**自定义工具 v1(服务器执行)**:

| 工具 | 用途 | 说明 |
|---|---|---|
| `memory` | 个人记忆:存/查/列 | 存 SQLite;agent 可主动沉淀用户偏好、事实;v1.5 配管理 UI |
| `http_request` | 调用个人服务 | 域名白名单制;可查自己服务器上的其他服务 |

**v1.5**:`run_code`(Docker 沙箱)。**v2**:日历/闹钟(设备桥)、知识库检索、定时任务。

### 4.3 护栏

- 工具调用轮数上限、单次执行超时
- `http_request` 域名白名单;`run_code` 无网络 + 资源限额
- 每日 token / 工具调用预算,超预算熔断并通知
- 全部工具调用留痕(入参/出参/耗时/费用),UI 可展开查看

### 4.4 远程开发:DeepSeek Harness 集成(M3)

**目标**:手机远程指挥电脑上的 dsh 开发项目,完整控制(派任务、看实时输出、逐条确认敏感操作、停止、追问)。

**方案:dsh 桥插件**——官方"一切皆插件"(Cordis)扩展点,TypeScript 插件跑在 dsh 运行时内部(桌面版与 Web 版同一运行时,通用):

```
手机 APK ⇄ SSE ⇄ DPAPP 服务器 ⇄ outbound WS ⇄ dsh 桥插件(电脑)
   电脑不开任何入站端口;插件主动外连
```

**插件五项能力(2026-11-15 已按本机 dsh 源码与真实运行时逐项验证)**:

| 能力 | 真实接口 |
|---|---|
| 枚举工作区与会话 | `ctx.workspaceRegistry.list()`;`ctx.sessionQuery.listSessions()`(async,返回 `{header,live,persisted}`) |
| 订阅会话事件流 | `agent/assistant-stream`(start/chunk/end,chunk 内含 `text-delta`/`reasoning-delta`)、`agent/status`、`agent/error`、`agent/created`、`agent/disposed` |
| 注入用户输入 | `agent.followup({content,source})` / `agent.steer()` / `agent.cancel({kind:'user'})`;恢复历史会话用 `agents.resume({resumeSessionId})` |
| **拦截工具调用确认** | `ctx.on('approval/request', answerer)`,返回 `allowed-once`/`rejected`/`cancelled`/`unavailable`,非本插件请求 `next()` 委托;无 answerer 时 fail-closed;请求只有工具名与理由(**无参数**);会话策略为 `never` 时不经过 answerer |
| 发起出站 WebSocket | Electron 44/Node 24 全局 `WebSocket` 直连,无入站端口 |

实现要点:插件必须以 `dsh.bundle.patch` 形式打包(`package.json`+`cordis.patch.yml`+`apply(ctx,config)`);访问服务用 `ctx.get(name)`(直接 `ctx.xxx` 需 `inject`);热重载会残留旧实例,已加单例守卫 + `stand_down` 协议;真实代码见 `bridge-dsh/` 与 `server/src/routes/harness.ts`。

**Spike 闸门(M3 首日)**:克隆 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness),读 `docs/architecture.md`、`docs/development.md`,对照本机 dsh 实际版本验证上述五项;运行时处于开发者预览期,一切以源码为准。

**备选方案**(若④拦截确认经插件 API 不可行):电脑上跑外部桥进程,代理 dsh Web UI 本地接口(`npx @deepseek-ai/dsh web` 默认 `127.0.0.1:3080`)。预览期内部接口有变更风险,故插件方案优先。

**不采用**:headless 自动化模式(社区实测反馈可能触发平台风控)。

**风险与对策**:预览期破坏性变更 → 插件独立成模块(`bridge-dsh/`),dsh 升级只改插件不动主体;服务器中继协议自有(§5.1),两端解耦。

## 5. 后端服务设计

### 5.1 客户端-服务器 API 契约(自有协议)

| 端点 | 方法 | 说明 |
|---|---|---|
| `/v1/pair` | POST | 一次性配对码 → 设备令牌(仅首次) |
| `/v1/conversations` | GET/POST | 会话列表(置顶分组,排除临时会话)/ 新建(可指定临时) |
| `/v1/conversations/{id}` | GET/DELETE/PATCH | 详情(全树+活跃叶子)/ 删除 / 置顶·重命名·临时标记·切换活跃叶子 |
| `/v1/conversations/{id}/chat` | POST | **SSE 流**:普通发送 / `{parent_message_id, content}` 编辑重发 / `{parent_message_id, regenerate:true}` 重新生成 |
| `/v1/conversations/{id}/messages/{mid}` | DELETE | 删除消息及其整个子树;若删到活跃叶子,`active_leaf_id` 回退到该消息父节点(M1 长按删除用) |
| `/v1/conversations/{id}/stop` | POST | 中断当前生成 |
| `/v1/files` | POST | 上传文件(multipart)→ file_id 与解析状态 |
| `/v1/asr` | POST | 上传录音 → 识别文本 |
| `/v1/tts` | POST | 文本 → 音频流(mp3) |
| `/v1/files` | POST | 上传文档(multipart,`?purpose=text_recognition｜rich_layout_recognition｜user_data`)→ file_id(服务端转发 DeepSeek Files API 同步解析) |
| `/v1/files/{id}` | GET | 文件状态(名称/大小/purpose/解析状态) |
| `/v1/usage` | GET | 用量与费用统计 |

**`/chat` 的 `parent_message_id` 语义(M0 实现时定稿,客户端 M1 必须一致)**:

- 省略(undefined)= 挂到会话当前 `active_leaf_id` 下 —— 普通发送
- 显式 `null` = 挂到根节点(会话无父节点的位置)
- 给具体 id = 在该节点下插入新消息

由此:`{content, parent_message_id:<被编辑用户消息的父节点>}` = 编辑重发(产生兄弟用户分支);
`{regenerate:true, parent_message_id:<该用户消息 id>}` = 重新生成(在该用户消息下产生兄弟助手分支)。

**SSE 事件协议**(客户端唯一需要理解的格式,对 DeepSeek 原生事件归一化;M0 已冻结,M1 逐字段镜像):

```
event: message_start     {message_id, user_message_id, model}   # user_message_id:重新生成时为 null
event: thinking_delta    {text}
event: thinking_end
event: tool_progress     {tool:"web_search", phase:"searching"|"reading", query?}
event: tool_result       {tool, summary, results:[{title,url,site?}...]}
event: text_delta        {text}
event: citation          {index, url, title}
event: file_attached     {file_id, name, status}                # status: pending|parsed|failed
event: safety_block      {reason}
event: message_end       {usage:{tokens_in,out}, cost_estimate, stop_reason}
event: error             {code, message}
```

线上编码约定(M1 解析必须按此实现):

- 每行格式 `event: <type>` + `data: <JSON>`,块以空行分隔;**`data` 的 JSON 里也带 `type` 字段**,两份信息一致,客户端可用任一解析。
- 服务端每 15s 发一行注释 `: ping`,**客户端必须忽略以 `:` 开头的行**(SSE 规范注释,不是数据)。
- **`message_end` 永远是流的终止事件**;`error` 只表示"本轮失败",其后仍会收到 `message_end`(`stop_reason:"error"`),客户端不用把 `error` 当终止信号。
- `stop_reason` 取值:`end_turn`(正常)/ `interrupted`(用户 stop 或客户端断连)/ `error`(上游失败或超时)。
- **失败/中断也会落库**:服务端会把已收到的部分内容(可能为空)存成一条 assistant 消息并推进 `active_leaf_id`,所以客户端收到 `error`/`interrupted` 后刷新会话一定能看到当轮用户消息,不会"消失";空正文的 assistant 消息在组装下一轮上下文时会被服务端过滤掉。
- 中断或上游失败时拿不到真实 usage,`usage` 与 `cost_estimate` 是按字符数估算值(用于用量看板,不用于计费对账)。

**dsh 桥接端点(M3 落地,协议在 spike 后定稿,预留)**:

| 端点 | 方法 | 说明 |
|---|---|---|
| `/v1/harness/bridge` | WS | 插件接入(独立 bridge token);上报节点/工作区/会话,订阅事件,确认往返 |
| `/v1/harness/workspaces` | GET | 代理插件枚举工作区/会话 |
| `/v1/harness/tasks` | POST | 派任务(工作区 + prompt)→ task_id |
| `/v1/harness/tasks/{id}/confirm` | POST | 批准/拒绝工具调用(**默认拒绝:超时未确认不执行**) |
| `/v1/harness/tasks/{id}/events` | GET(SSE) | 任务实时事件流(输出/工具调用/确认请求/完成) |

### 5.2 数据模型(SQLite 起步,预留 Postgres 迁移)

```
device        (id, paired_at, last_seen, token_hash)
conversation  (id, title, pinned, ephemeral, active_leaf_id, settings_json,
               created_at, updated_at)
message       (id, conversation_id, parent_id, role, blocks_json, thinking,
               citations_json, tool_traces_json, tokens_in, tokens_out, cost,
               created_at)                    -- parent_id 构成消息树;active_leaf_id 沿 parent 回溯即展示路径
file          (id, conversation_id, name, mime, size, storage_path, parse_status)
usage_log     (id, ts, kind[model|search|fetch|ocr|asr|tts], quantity, cost)
memory_note   (id, content, tags, created_at, updated_at)

-- M3 建:
harness_node  (id, name, platform, status, last_seen)
harness_task  (id, node_id, workspace, prompt, status, created_at)
harness_event (id, task_id, kind[output|tool_call|confirm_request|confirm_result|done|error],
               payload_json, ts)
```

**分支语义**:编辑用户消息重发 = 在原父节点下新建兄弟分支(旧回答保留);重新生成 = 同一用户消息下新建兄弟助手分支;切换分支 = PATCH `active_leaf_id`。详见 HANDOFF。

### 5.3 文件与语音管道

- 文件:上传→存盘→调 DeepSeek 文件解析/OCR→文本入上下文;原件保留供再读
- 语音:客户端录 16kHz(opus/wav)→ `/v1/asr` → 文本 → 进入对话流 → 回答完成后(或用户点击)对最终回答调 `/v1/tts` → 音频流回客户端播放
- TTS 策略:默认只朗读最终回答,不朗读工具过程

## 6. 客户端设计(Flutter)

**命名**:Flutter 项目名 `jingling`,组织 `com.jingling`,应用显示名「鲸灵」(Android label / iOS display name)。启动页:鲸鱼 icon + 「鲸灵」+ slogan「你的随身精灵」。

**页面**:配对 / 会话列表(置顶区+长按管理+临时对话入口)/ 对话页(核心)/ 设置(服务器地址、解除配对、用量);M3 增加电脑页(工作区→任务→输出流→确认卡片)。

**对话页要素**:
- 消息流:用户气泡 / 助手消息(思考折叠区 → 工具过程卡片 → 正文 markdown → 引用列表)
- 分支导航:兄弟分支持显示 `‹ n/m ›` 切换器;自己消息提供"编辑重发",助手消息提供"重新生成"
- 输入区:文本框、文件附件、按住说话按钮、发送/停止
- 长按消息:复制、删除(M4 起加"朗读此回答")
- 本地仅存"服务器地址 + 设备令牌"(系统安全存储),其余数据以服务端为准

## 7. 安全设计

| 层 | 措施 |
|---|---|
| 密钥 | `DEEPSEEK_API_KEY` 仅存服务器环境变量/secret,不进代码库,不出服务器 |
| 认证 | 一次性配对码 → 设备令牌(服务端只存 sha256);所有请求带令牌;dsh 桥接用独立 bridge token |
| 传输 | 过渡方案(域名备案期间):纯 IP + 自签名证书,客户端证书锁定(仅信任本服务器);备案通过后切域名 + Let's Encrypt。可选防火墙白名单 / Tailscale |
| 内容 | 开启 DeepSeek 安全校验参数 |
| 输入 | 文件类型白名单、大小上限;消息长度上限 |
| 远程执行(M3) | 确认默认拒绝(超时未确认不执行);工具调用全量留痕;bridge token 与设备令牌分离 |
| 成本 | 每日预算熔断(见 §4.3) |
| 运维 | Docker 部署,数据目录独立卷,SQLite 定期备份 |

## 8. 成本模型(DeepSeek 公布价,2026-11)

| 项目 | 价格 |
|---|---|
| 文字/图片搜索 | 5 元/千次 |
| 网页抓取 | 5 元/千次 |
| 文字识别 OCR | 1.5 元/千页 |
| 语音识别 ASR | 0.39 元/小时(限时5折,刊例 0.78) |
| 语音合成 TTS | 1.5 元/万字符(限时5折,刊例 3.0) |
| 模型 token | 按 deepseek-flash 标准 token 价 |

**体感估算(个人重度使用)**:一次深度搜索回答约 2–5 次搜索 ≈ 1–2.5 分钱;每天 1 小时语音对话 ≈ 0.4 元。月成本预计个位数到十几元量级(不含 token);`/v1/usage` 核实。

## 9. 里程碑

| 阶段 | 交付物 | 验收 | 施工单 |
|---|---|---|---|
| M0 后端骨架 | 服务部署、配对认证、DeepSeek 适配层、SSE 事件协议、会话+分支存储 | curl 走通流式对话与分支 | HANDOFF §M0 |
| M1 客户端核心 | Flutter 四页、流式渲染、分支 UI、基础操作包 | 真机/Chrome 全流程 | HANDOFF §M1 |
| M2 搜索与文件 ✅ | 搜索过程卡片、引用、文件上传解析 | 带 URL 能读网页;传 PDF 能答 | `docs/HANDOFF-M2.md`(完成 2026-11-15) || M3 dsh 远程开发桥 | spike→插件→服务器中继→电脑页 | 手机派任务+批准工具调用,任务完成 | §4.4 + 届时另出 |
| M4 语音闭环 | ASR/TTS 管道、录音 UI、播放打断、长按朗读 | 全程语音完成一轮问答 | `HANDOFF-M4.md`(服务端+客户端已完成,真机麦克风验收待做) |
| M5 工具与用量 | memory + http_request + 预算熔断 + 用量看板 | "记住我用 XX,下次直接用"生效 | 届时另出 |
| M6 打包发布 | APK、HTTPS(备案通过后)、证书锁定、备份脚本 | 手机安装即用 | 届时另出 |

## 10. 决策记录

| 日期 | 决策 |
|---|---|
| 2026-11-14 | 架构:Agent 大脑在服务器端,客户端瘦 UI、零密钥 |
| 2026-11-14 | 使用者:个人自用,专业级标准;API key 只存服务器 |
| 2026-11-14 | v1 语音形态:按住说话(松开→识别→确认→播报,可打断) |
| 2026-11-14 | 客户端:v1 只做 APK,网页端为 v2(架构已预留) |
| 2026-11-14 | 服务器:已有域名,ICP 备案审核中 → 过渡方案 IP+自签证书+客户端锁定 |
| 2026-11-14 | `run_code` 代码执行沙箱:v1.5 再做,v1 工具集 = memory + http_request |
| 2026-11-14 | 技术栈:后端 Node.js/TypeScript(Fastify + better-sqlite3 + zod),客户端 Flutter(riverpod) |
| 2026-11-14 | 功能对齐 ChatGPT(用户以其为体验基准):**采纳进 v1** = 消息编辑/重新生成/分支导航、基础操作包;**v1.5** = 记忆管理 UI、拍照提问;**v2** = 全局搜索;**暂不做** = 建议追问 chips、提示词模板库、自定义指令/人设、系统分享集成、导出/分享、生图 |
| 2026-11-14 | dsh 远程开发进 v1(M3),**完整控制**(含手机端逐条确认工具调用);实现走官方插件机制(五项能力 spike 验证),备选外部桥代理 Web UI 本地接口;headless 模式不采用(风控反馈) |
| 2026-11-14 | 开发执行方式:本项目由电脑端 dsh 按施工单开发(`docs/HANDOFF-M0-M1.md`),插件问题由 dsh 直接查自身源码修复(`AGENTS.md`) |
| 2026-11-14 | 产品命名:**鲸灵(JingLing)**,包名 `com.jingling`,Flutter 项目名 `jingling`;目录代号 DPAPP 保留 |
| 2026-11-14 | **M0 完成**:server 骨架(Fastify 5 + better-sqlite3 + zod 4 + TS strict)、配对认证(设备令牌只存 sha256、配对码成功即轮换)、会话 CRUD + 消息树/分支模型、DeepSeek 适配层(client/events/mock)、SSE `chat`(普通/编辑重发/重新生成)+ `stop`、按天用量。`npm test` 9/9 通过;MOCK=1 真实进程 curl 全流程(配对→分支→切叶子→重新生成→stop 中断→断连恢复→临时会话清扫)验证通过。**真实 key 复测(DoD 第 2 项)待用户提供 `DEEPSEEK_API_KEY`** |
| 2026-11-14 | M0 实现决策:`usage_log` 增加 `tokens_in/tokens_out/conversation_id/message_id`(在 §5.2 基础上扩展),否则 F9 无法按天/按会话拆分 token;token 单价放 env(`PRICE_IN/OUT_CNY_PER_MTOK`,默认 0.5/2.0 元每百万,**需按官方公告核定**);一次性配对码轮换状态仅在内存,重启即换新码并打印;预算熔断字段只读取不启用(M5 开启) |
| 2026-11-14 | M0 代码审查后定稿(修复 Critical/Important):①失败/中断也落 assistant 消息(可能空正文)并推进 `active_leaf_id`,杜绝"用户消息不在展示路径上";②助手落库+active_leaf+标题+用量放进同一 SQLite 事务;③加 `UPSTREAM_TIMEOUT_MS`(默认 120s)防止会话永久卡在 generating;④空正文 assistant 不进下一轮上下文;⑤关停时先 abort 在途生成再 close,Docker stop 不再卡死;⑥§5.1 协议冻结(message_start 增加 `user_message_id`、`stop_reason` 三值、`message_end` 为唯一终止事件、data 含 `type`、心跳注释行) |
| 2026-11-14 | M0 遗留项(进 M1/backlog,非阻塞):消息删除服务端接口(`DELETE /v1/conversations/{id}/messages/{mid}`,约定删子树且 `active_leaf` 落在删除点父节点)——M1 长按"删除"必须先有此接口;会话列表 preview 目前 N+1 查询(个人量级可接受);`/v1/pair` 无速率限制、无令牌吊销接口;`/v1/usage` 按 UTC 日分桶 |
| 2026-11-14 | **M1 完成**:Flutter 客户端四页(配对/会话列表/对话/设置)+ 流式渲染(思考折叠区→markdown 正文→引用→token 费用)+ 分支 UI(`‹ n/m ›`)+ 长按菜单(复制/编辑重发/重新生成/删除)+ 临时对话入口 + 用量弹窗;`flutter analyze` 0 问题,`flutter test` 7/7,debug APK 构建通过。**已用真实 DeepSeek key 端到端验证**:真实思考增量 → 正文增量 → 真实 usage 落库(示例 38 in / 148 out),自动标题、编辑重发兄弟分支、`‹ n/m ›` 切换、重新生成、停止生成、按天用量均实测通过 |
| 2026-11-14 | **真实 API 实测结论**(替换文档假设):`model=deepseek-flash` 可用;请求参数 `thinking:{"type":"enabled"}` 与 `stream_options:{"include_usage":true}` 均被接受、不报错;思考内容确实以 `reasoning_content` 增量返回(一次回答 116 个 thinking_delta);`usage` 在末尾 chunk 真实回传。**token 单价仍是占位值**(0.5/2.0 元每百万),估算费用不可用于对账,需按官方公告价更新 env |
| 2026-11-14 | M1 实现决策:①CORS 从「跟随 MOCK」改为独立 `DEV_CORS` 开关(默认跟随 MOCK),因为用真实 key 时也要 `flutter run -d chrome`,而生产必须为 0;②SSE 端点用 `reply.hijack()` 后 Fastify 的 CORS 头不会自动写入,已显式补上(`src/cors.ts`),否则浏览器整条流被拦(Failed to fetch);③客户端协议层用 `package:http` 流式解析,服务端每 15s 的心跳注释行必须忽略;④`flutter_markdown` 的 `selectable` 会吞掉长按手势,助手消息改为不可选文本 + 显式 `⋯` 菜单按钮兜底 |
| 2026-11-14 | M1 已知限制:Flutter **Web** 上长按助手正文偶发不触发(桌面浏览器合成指针事件差异),已提供 `⋯` 按钮作为等价入口,真机上需复测长按;**APK 需真机安装验证**(本机无连接设备);`server/.env` 与仓库根的 `apikey.md` 已加入 `.gitignore`,密钥只允许留在本机 |
| 2026-11-14 | **M1 真机验证通过**:小米 24129PN74C / Android 15 / HyperOS,`adb reverse` 把手机 `localhost:3000` 映射到电脑服务端,debug APK 安装后完成 配对 → 多轮真实对话(「你是谁」「你可以做什么」)→ 临时会话;服务端 `device.last_seen` 与消息均正确落库。注:小米需在开发者选项打开「USB 安装」,`adb shell input` 另需「USB 调试(安全设置)」 |
| 2026-11-14 | **M2 施工单已出**(`docs/HANDOFF-M2.md`),并**用真实 key 抓包确认了 Chat Completions 下的联网/文件接口形态**(非文档推测):`tools:[{type,name}]`、`safety_check:{level}`、`title:{enabled}` 均可用;新增流式字段 `delta.annotations[].url_citation{url,title,start_index,end_index}`、`delta.server_tool_calls[{index,reasoning_content,calls[{id,type,kind,action,status,sources[]}]}]`、`delta.title`、`choices[0].server_tool_event{type,step}`;`usage` 增加 `prompt_tokens_details.cached_tokens`、`completion_tokens_details.reasoning_tokens/safety_tokens`、`server_tool_use{tool_search,tool_fetch,tool_image_search}`;`finish_reason` 为 `stop`。文件走 `POST /files`(`purpose` 必须在 `file` 之前)→ 对话里用 `{type:"document",source:{type:"file",file_id}}` 引用 |

| 2026-11-15 | **M2 完成**:联网搜索与读链接(服务端工具由 DeepSeek 执行)、搜索/打开网页过程卡片(可展开来源列表)、正文引用角标 `[n]` + 引用列表、文件输入(PDF/Office/图片,`POST /v1/files` 转发 Files API → 对话里以 `file` 块引用)、输入命中审核 → `safety_block`、服务端生成会话标题、usage 按 `model/search/fetch` 分类。**真 key 硬指标实测**:读链接→1 张打开网页卡片 + 1 条引用 + `fetch_calls=1`;联网搜索→5 张卡片(含 14 条搜索结果)+3 条引用 + `search_calls=2`;上传 PDF→答出文档内暗号。`npm test` 20/20、`flutter test` 11/11、`flutter analyze` 0 问题。**真机(小米)复验**:配对 → 上传 191KB PDF(application/octet-stream,按扩展名+上游解析兜底成功)→ 文档问答返回结构化总结(2 条工具留痕 / 2 条引用 / 2321 tokens) |
| 2026-11-15 | **M2 实测坑(重要)**:①Chat Completions 里文件内容块是 `{type:"file",file_id}`(官方文档主体写的是 Messages 的 `document`,照抄会 422);②服务端转发文件时**必须 `Uint8Array.from(buffer)`**,直接 `new Uint8Array(buffer)` 会把 Node 8KB 共享内存池当成文件内容上传,表现为模型回答“文档内容为空”(曾一度误判为“思考模式与文件不兼容”,修正后 thinking+文件正常);③工具计费按查询词条数/成功网页数计次,写入 `usage_log` 的 `search`/`fetch`;④文件解析按页计费但上游响应不含页数,`ocr` 费用暂未计入(已知限制);⑤超时/中断沿用 M0 规则:失败也落库并返回 `message_end` |
| 2026-11-15 | M2 遗留项(backlog):文件解析费用(ocr)未记账;`deepseek_read_url` 在「思考 + 已声明 web_search」时不会被单独使用(走深度思考搜索的 open_page),该工具声明保留以备关闭思考时用;`/v1/files` 未做病毒扫描与格式深度校验(仅 MIME/扩展名 + 上游解析兜底);文件不落本地(官方不支持下载原件/解析结果) |

| 2026-11-15 | **生产环境上线**(M6 部署部分提前):后端容器化部署到腾讯云 `/opt/jingling`(Docker Compose,多阶段构建,只绑 `127.0.0.1:3001`,SQLite 挂卷);Caddy 反代对外 `https://www.example.com:8000/jingling`。**备案未下导致子域名签不出证书**(ACME 只走 80/443,TLS-ALPN 连 443、HTTP-01 连 80,均被 DNSPod 拦截),故复用 www 既有证书 + `handle_path /jingling/*` 剥前缀;备案通过后改回子域名(客户端只需改服务器地址)。同机 spendlens 不受影响。公网实测:健康检查 200、SSE 首事件 67ms(反代 `flush_interval -1` 生效)、真实 usage 落库。运维手册见 `docs/DEPLOY.md` |
| 2026-11-15 | 配对方式定稿:**生产用固定配对码**(`PAIRING_CODE` 由 env 提供则不轮换,等同长期密码;留空仍是启动生成的一次性码)。配套给 `/v1/pair` 加失败限速(同源 60s 内错 5 次 → 429)。理由:单人自用不需要账号体系(无多用户/找回密码/权限分级),账号反而扩大攻击面;固定码解决"每次取码麻烦"。设备令牌仍是长期凭证(库里只存 sha256),账号密码登录与设备吊销留到 M5 视需要再做 |

**当前状态**:M0 + M1 + M2 已交付并验证;**M2 后端已上线生产**(`https://www.example.com:8000/jingling`,固定配对码模式)。下一步 M3(dsh 远程开发桥)——需先出 M3 施工单并做插件 API spike。

## 11. 参考资料

- DeepSeek 全家桶应用 API 发布公告:https://api-docs.deepseek.com/zh-cn/news/news261113
- 构建 Chatbot 指南(SSE 事件示例):https://api-docs.deepseek.com/zh-cn/guides/build_a_chatbot
- Create Chat Completion API(tools / server_tool_calls):https://api-docs.deepseek.com/zh-cn/api/create-chat-completion
- DeepSeek Harness 官网:https://www.deepseek.com/zh/harness · 下载:https://www.deepseek.com/zh/download
- Harness 仓库:https://github.com/deepseek-ai/deepseek-harness(架构深读:#1103)
- 官方开源 Demo(参考实现):https://github.com/deepseek-ai/chat-demo

| 2026-11-15 | M3 工具确认与权限 | 逐条确认走 `tools/pre-execute`(可拿参数,超时/断线 fail-closed);沙箱越界由 `permissionPresets` 会话级预设控制,手机端提供「沙箱内/完全访问」开关。生产实测:批准后文件真实写入,拒绝/超时文件不写入 |

| 2026-11-15 | M3 本地优先 | 远程逐条确认不得压过本地用户:会话为「完全访问」时桥接不拦截;手机派任务默认不逐条确认,确认改为可选开关。原因:远程门曾把本机 dsh 的每个工具调用都拦成拒绝,导致本地无法操作 |
