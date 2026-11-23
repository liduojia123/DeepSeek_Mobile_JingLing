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

> **已全部交付(2026-11-18)**,下表留档;新增条目请另开一节。

| # | 功能 | 状态 |
|---|---|---|
| G1 | **手机原生提醒**(精确闹钟 + 系统通知) | ✅ v1.3.0(2026-11-18)。**不做系统日历**(提醒≠日程) |
| G2 | 记忆管理 UI | ✅ 已有:设置 → 记忆(查看/删除 memory 沉淀) |
| G3 | 拍照/相册提问 | ✅ 已有:对话页「＋」→ 拍照 / 相册(≤6 张) |

> `run_code` 代码执行沙箱已于 2026-11-17 决定不做(理由见 §10 决策记录)。

### v2 — P2(架构预留)

- 网页端客户端(复用同一后端)
- 全局对话搜索 ✅(v1.5.0,2026-11-22 交付;**文件夹**未做)
- 手机原生工具桥:日历、闹钟、剪贴板、系统通知 + 推送提醒(FCM/APNs)
- 个人知识库 RAG(文档长期沉淀 + 检索)
- 连续语音对话(免按住)✅(M4 已交付:聊天页内联连续语音、VAD 断句、自动播报)

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

**v1.5(当前)**:手机原生提醒(日历/闹钟)。**v2**:知识库检索、定时任务、推送(FCM/APNs)。

### 4.3 护栏

- 工具调用轮数上限、单次执行超时
- `http_request` 域名白名单
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

**会话级桥接(M3.5,2026-11-16):手机 = 同一个会话的第二窗口**

M3 的"任务级"接口只能看到手机自己派的任务;要"和电脑上同一份对话",接口换成会话级。已验证(本机 `app.asar` 内 `@deepseek-ai/*` 源码 + 运行时):

| 能力 | 真接口 | 要点 |
|---|---|---|
| 持久事件(历史+实时同源) | `ctx.on('session/event', (session, event) => …)`,`event={type,seq,time,data}` | **必须 `{global:true}`**:本地用户开的会话不在插件作用域里,cordis 默认按上下文过滤 |
| 历史 | `sessionQuery.readSurface(sessionId)` → `{events, capturedThroughSeq}` | 事件自带 `seq`;手机时间线直接从这里起步 |
| 实时增量 | `agent/assistant-stream` 的 `chunk`:`text-delta`/`reasoning-delta` | 仅做"正在打字",不落库 |
| 输入 | `agent.steer()`(下一步/当前轮改方向)、`agent.followup()`(下一轮)、`agent.cancel({kind:'user'})` | `agent.status` 只有 `idle`/`running` |
| 排队提示 | `agent/inbox/inserted|claimed|discarded` | 手机上显示"已排队/已采纳" |
| 事件类型 | `turn/start|end`、`step/start|end`、`user/message`、`assistant/message{message,stream,usage,interrupted}`、`tool/call{name,arguments}`、`tool/result{message,error}` | 内容块:`text`/`reasoning`/`image`/`file`/`tool-call` |

实现:服务器给每会话维护本地 `seq` 游标(表 `harness_stream_event`,`dsh_seq` 唯一去重),手机 `GET /v1/harness/sessions/{id}/stream?after_seq=N` 断线续传;只有手机在看时(引用计数)才让插件 `session.watch.start`。详见 `docs/HANDOFF-M3.5.md`。

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
| `/v1/devices` | GET | 已配对设备列表(标出当前设备) |
| `/v1/devices/{id}` | DELETE | 吊销设备令牌(立即失效;吊销本机 = 强制把自己踢下线) |
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
event: safety_block      {reason, source}                       # source: input|output(input=输入被审核拦截;output=模型拒答)
event: message_end       {usage:{tokens_in,out}, cost_estimate, stop_reason}
event: error             {code, message}
```

线上编码约定(M1 解析必须按此实现):

- 每行格式 `event: <type>` + `data: <JSON>`,块以空行分隔;**`data` 的 JSON 里也带 `type` 字段**,两份信息一致,客户端可用任一解析。
- 服务端每 15s 发一行注释 `: ping`,**客户端必须忽略以 `:` 开头的行**(SSE 规范注释,不是数据)。
- **`message_end` 永远是流的终止事件**;`error` 只表示"本轮失败",其后仍会收到 `message_end`(`stop_reason:"error"`),客户端不用把 `error` 当终止信号。
- `stop_reason` 取值:`end_turn`(正常)/ `interrupted`(用户 stop 或客户端断连)/ `error`(上游失败或超时)/ `refusal`(命中内容安全)。
- `refusal` 的两种来源看同轮的 `safety_block.source`:`input` = 用户输入被上游审核拦截(正文通常为空);`output` = 模型自己在正文里拒答(正文保留,服务端通过启发式识别,并在 `message.safety_json` 落库,历史消息也带标识)。
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

**会话级(M3.5)**:手机与电脑共用同一个会话。

| 端点 | 方法 | 说明 |
|---|---|---|
| `/v1/harness/sessions` | POST | 在电脑上新建会话(`cwd` + 可选 preset/权限)→ `session_id` |
| `/v1/harness/sessions/{id}/stream` | GET(SSE) | 会话时间线:`?after_seq=N` 续传;首帧 `harness_session_ready{last_seq,status,permission}` |
| `/v1/harness/sessions/{id}/input` | POST | 手机输入:`{text, mode: auto\|steer\|followup}`;auto = 正在跑就插话,空闲就追加 |
| `/v1/harness/sessions/{id}/stop` | POST | 中断电脑上的当前回合 |
| `/v1/harness/sessions/{id}/state` | GET | 会话状态(运行中/权限/模型) |
| `/v1/harness/sessions/{id}/permission` | PUT | 会话级权限预设(沙箱内 / 完全访问) |

会话流事件:`harness_session_event{seq, dsh_seq, kind, payload}`(kind: `user_message`/`assistant_message`/`tool_call`/`tool_result`/`turn_start`/`turn_end`)、`harness_session_live{kind: text|reasoning|status|inbox|input_echo}`。`seq` 是服务器本地游标,断线用它续传;`dsh_seq` 只用于去重。

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
| M5 工具与用量 | memory + http_request + 预算熔断 + 用量看板 | "记住我用 XX,下次直接用"生效 | ✅ `HANDOFF-M5.md`(生产已验证) |
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

| 2026-11-22 | **v1.5.0 会话全局搜索**(v2 主线第一项,施工单 `docs/HANDOFF-SEARCH.md`):会话列表搜索框从本地过滤升级为服务端全量历史搜索(`GET /v1/search`),搜标题 + **活跃路径**消息正文(不含 thinking、不含非活跃分支、不含临时会话),按会话分组返回,摘要 snippet 纯文本(高亮由客户端做,避免转义问题);点结果跳转 ChatPage 定位到命中消息并短暂高亮(GlobalObjectKey + ensureVisible,找不到静默停底部)。实现决策:①全表扫描 + JS 匹配而非 SQL LIKE(JSON 转义会坑 `%_"` 等关键词),性能口径与列表 preview 一致,量大再上 search_text 列/FTS5;②每组正文命中 ≤5 条、组 ≤20(limit 可调);③本地 `filterConversations` 删除(职责被取代)。测试 server 54/54(新增 9)、app 69/69(新增 7、移除 3);真机验收待做 |

| 2026-11-22 | **v1.5.3 个人 DeepSeek API Key**(设置 → 服务器 → API Key):用户可录入自己的 DeepSeek key,**只存服务端数据库**(`app_setting` 表)、接口只回尾号、不进日志;服务端所有上游调用(对话/文件/ASR/TTS)统一走 `effectiveApiKey()`:个人 key 优先、清除后回落 `server/.env`。保存前服务端拿新 key 打 `GET /models` 验真(401/403 拒绝落库,MOCK 跳过)。安全红线相应修订(见 AGENTS.md)。**范围决策**:只做 DeepSeek key,不做第三方模型接入(专有字段兼容问题见当日对话;若将来做,入口是 `UPSTREAM_COMPAT` 开关)。测试 server 60/60、app 76/76 |

| 2026-11-22 | **v1.6.0 输入优先首页**(照用户提供的截图设计,导航重排):App 打开即进首页(logo + 问候语 + 底部完整输入区),**发消息自动建会话进对话页并发出首条消息**——此前"每次都要先点新对话"的摩擦点消除;「深度思考/智能搜索」药丸开关(对应联网/思考开关)、附件(拍照/相册/文件)在首页先传随首条带走、语音模式一键进对话开聊;历史会话收进左上角抽屉(`ConversationDrawer`),全局搜索/分组/置顶/批量管理/电脑横幅原样保留;⋯ 菜单留首页顶栏。实现决策:①首页不起空会话(发送/语音才建,列表不积空壳);②ChatPage 增加 `initialText/initialFileIds/initialSearch/initialThinking/autoStartVoice` 接力参数,首条消息走既有 `chat.send` 管道(零新协议);③`app_icon.png` 首次进 pubspec assets(launcher 构建期读的图不进 APK,运行时展示需显式声明)。测试 app 78/78(新增首页冒烟 2 条);真机验收待做 |

| 2026-11-22 | **v1.7.0 声音回答(TTS 播报)整体移除**(用户拍板:「没有声音,直接删掉声音回答这个功能,只要文字回答」,不做故障排查):删除自动朗读(设置项 + `jingling.auto_speak` 偏好)、「朗读这条回答」(⋯ 菜单)与「朗读此回答」(长按菜单)、语音模式的播报阶段与「打断」、`api.synthesize` 客户端调用、`audioplayers` 播放链路(`VoiceService` 只留录音)。**语音输入全部保留**(麦克风按钮、免按住连续语音),语音模式语义变为「语音进、文字出」(`VoiceStage.speaking` 删除)。服务端 `/v1/tts` 保留备用(客户端不再调用)。回答仍全部以文字呈现,协议零改动 |

| 2026-11-23 | **v1.8.0 Web 端(双栏桌面布局)**(v2 主线,施工单 `docs/HANDOFF-WEB.md`;用户在「双栏/单栏放大/分步」中选了双栏):Flutter Web 产物(实测构建一次通过)由服务端 `/web/*` 静态托管(`WEB_DIR`,公开免鉴权、SPA 回退、路径穿越防护),挂 `…/jingling/web/` 与 API 同域同证书 → **无 CORS**;宽屏 ≥1000px 双栏 = `ConversationPane` 会话栏(抽屉内容复用,`onClose` 可空)+ 右侧嵌套 Navigator(HomePage(wide)⇄ChatPage),窄屏走原单栏。Web 适配:隐藏 检查更新/更新来源/等待通知/麦克风(语音输入因录音管道依赖 dart:io 路径,v1 不做,留口子),会话行加显式「多选」入口(鼠标长按不可靠),配对页服务器地址从 `Uri.base` 推导预填。`AppShell` 断点 1000px、会话栏 320px。测试 server 64/64(新增静态托管 4 条)、app 81/81(新增壳 3 条);真机浏览器验收待做 |

| 2026-11-23 | **v1.9.0 邮箱账号体系(单人)**(施工单 `docs/HANDOFF-ACCOUNT.md`;用户拍板推翻本表 2026-11-15「不做账号体系」旧决策——Web 端上线后多端使用需求成立,且明确**目前一个人用**):注册(邮箱+密码)→ 邮箱验证码激活 → 登录**签设备令牌**(与配对共用 `issueDeviceToken`,底下鉴权/数据零改动);忘记密码(重置码,重置即吊销全部旧令牌)。安全设计:①**仅允许一个账号**(countAccounts>0 注册即 409,回应旧决策"账号扩大攻击面"的顾虑——公网不开自助注册);②密码 scrypt(N=16384)只存哈希、验证码 sha256 存库一次性 10 分钟、登录 5 次/60s 限速;③SMTP 未配置时注册明确 503 不静默吞信。登录页三态合一并保留「用配对码连接」(两套并存,旧设备令牌不受影响)。新增依赖 nodemailer(邮件验证码必需,Node 无内置 SMTP)。测试 server 70/70、app 83/83;**SMTP 凭据待用户提供后才可用真邮件** |

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

| 2026-11-15 | M5 工具与用量 | memory / http_request 用标准 function calling 在服务端本地执行(DeepSeek 服务端工具不受影响,可并存);工具调用以 `assistant(tool_calls)+tool` 成对落 `message.tool_blocks_json` 供历史回放;预算熔断在生成前按 UTC 当日累计检查,超出返回 402 |
| 2026-11-15 | M6 发布 | release 签名(keystore/key.properties 不入库,密码存仓库外)、R8 混淆+资源裁剪(195MB→18.3MB)、自适应应用图标+品牌蓝启动底;服务器每日备份(cron 03:30,sqlite 一致性快照,保留 7 天)与 5 分钟健康检查(仅记录失败/恢复,不自动重启) |

| 2026-11-15 | M6+ OTA | 应用内更新:服务器发布目录放 `jingling.apk` + `release.json`,App 比对 versionCode 后下载并交系统安装器(FileProvider + REQUEST_INSTALL_PACKAGES);不引入第三方安装插件。开发期仍需 adb 装首次版本,之后走 OTA |

| 2026-11-15 | 连续语音 | 手机输入法自带 STT,按条语音输入价值低 → 改为连续语音模式(免按住、自动断句、自动播报、可手动打断);VAD 用录音音量阈值,未做回声消除式自动 barge-in |

| 2026-11-15 | 语音交互形态(最终) | 不做按条「语音转文字」(输入法已具备);语音以**聊天页内联**方式提供:输入框左侧麦克风开启/退出连续语音模式,状态条只占一行,不遮挡对话与回答;以此替代全屏语音层 |

| 2026-11-15 | 拍照提问(G3 提前) | 聊天页输入框新增相机按钮:`image_picker` 拍照 → `POST /v1/files` 解析 → 有文字就附加,没文字直接把图片当问题发送(服务端放宽「content 不能为空」为「content 或 file_ids 至少一个」)。坑:`image_picker_android` 的 lint 与 AGP/JDK 组合会崩 → release 关闭 `lintVital`(不影响 flutter analyze) |

| 2026-11-15 | **v1.0.10 收口三项** | ①**代码语法高亮**:自研轻量 tokenizer(关键字/字符串/注释/数字,按语言给词表,`pre` 块用 flutter_markdown 的 builder 换成带语言标签+复制按钮的代码块),不引入 flutter_highlight/highlight —— 那类库会把上百种语言语法打进 APK,而这里只需要给模型输出的常见代码上色;新增直接依赖 `markdown`(原本是 flutter_markdown 的传递依赖,只为拿 `md.Element` 类型,不增加包体)。②**输出侧拒答结构化标识**:上游实测无结构化信号(2026-11-14 结论仍成立),改为服务端启发式识别(短答 ≤400 字 + 开头 80 字内 + 真实拒答话术模式),命中时发 `safety_block{source:"output"}` 且 `stop_reason=refusal`,正文照常下发,**标识落库** `message.safety_json` 供历史回放;输入侧仍映射上游 400 `Content Exists Risk`(`source:"input"`)。③**设备令牌吊销**:`GET /v1/devices` + `DELETE /v1/devices/{id}`,吊销 = `token_hash` 换成 `revoked:<id>`(永不命中 sha256)+ 记 `revoked_at`,设备行保留留痕;手机端设置 →「设备管理」可吊销任意设备(含本机,吊销本机即回到配对页) |
| 2026-11-15 | 拒答启发式的真实 fixture | 真实 key 实测(2026-11-15)拒答开场白形如「这个我不能写。」「这个我也不会教。」「这个我没法帮你写。」——谓语是任意动作,所以模式不能只列几个动词;这两条原文已写进 `server/test/smoke.test.ts` 作为回归 fixture。已知限制:改写得很客气的拒答、纯英文长拒答可能漏判(漏判只是不打标识,正文照常显示);启发式只影响标识,不影响内容 |

| 2026-11-16 | **M3.5 会话级桥接(v1.1.0)** | 需求:手机要接的是**电脑上正开着的同一个会话**(能看到同一份对话),同时能新建会话;场景是离开电脑时派任务/看进度,所以"跑在电脑上、手机不盯着也不丢"是硬要求。做法:插件把订阅从 `task_id` 抬到 `session_id`(`ctx.on('session/event', …, {global:true})` + `readSurface` 历史 + `agent/assistant-stream` 增量),服务器给每个会话维护本地 `seq` 游标并用 `dsh_seq` 去重,手机 `stream?after_seq=N` 断线续传;输入 `mode=auto`(running→steer,idle→followup),手机输入回显在持久 `user_message` 到达后消失。**产品语义**:本地用户永远优先(远程确认门只在会话非完全访问时生效,M3 已定);手机消息带 `source.kind=jingling`,时间线标「手机」 |
| 2026-11-16 | M3.5 实现坑 | ①cordis 事件默认按上下文过滤,插件 ctx 收不到本地用户会话的 `session/event`,必须 `{global:true}`(否则只有插件自己建的 agent 有事件);②服务器本地 `seq` 与 dsh `dsh_seq` 要分开:前者给手机续传、后者只做去重,插件重连补发才不会出现重复消息;③`readSurface` 的第一页会带 `capturedThroughSeq`,历史与实时用同一套事件格式拼起来比"消息 + 事件两套模型"省一个数量级;④只让手机在看时说 `session.watch.start`(引用计数),否则电脑上每个会话都在往服务器推流 |

| 2026-11-16 | **v1.1.1 检查更新修复** | 现象:用户点「检查更新」后没有任何有效反馈。生产日志显示手机只发了 1 次 `GET /v1/app/version`,服务器 **200** 正常返回 `version_code=12`,既无 401 也无下载请求 → 链路是通的,是客户端把结果吞了。根因:旧代码 `appVersion()` 捕获所有 `ApiException` 返回 null、`check()` 又用 null 同时表示"已是最新"和"查询失败",于是 401/404/网络/解析错误全被显示成「已是最新版本」;GitHub 分支的异常则直接抛出,`_checkUpdate` 没有 try/catch,表现为"点了没反应"。修法:①`appVersion` 只把 404(服务器没放包)当"没有更新",其余错误上抛;②`check()` 返回 `UpdateCheck`(available / upToDate / failed),失败必带原因,GitHub 侧补超时 / 403 限流 / 无 APK 资产的具体说明;③设置页点击先提示「正在检查」,失败弹窗显示原因 + 当前版本 + 来源;④读不到本机版本号直接报错而不是猜(猜 0 会永远提示有新版本) |

| 2026-11-16 | **M3.6 等待期通知(v1.2.0,方案 B)** | 需求:离开电脑时,跑完 / 出错 / 电脑断线要能主动响一声。选择**只在"正在等"期间开前台服务**:手机把输入送进会话(或派任务)且电脑在跑 → 起一个带常驻通知的 `WaitService`(Kotlin,`dataSync` 类型),作用只有两个:保活进程让 Dart 侧的会话 SSE 继续收事件 + 通知栏常驻「正在等电脑」;这一轮 `turn_end`(或离开页面)→ `stopService` 立刻停。结果通知只在 **App 不在前台**时发(完成 / 出错 / 断线),避免自己看着还响。**不引入 flutter_foreground_task / flutter_local_notifications**,通道沿用 M6 OTA 的 `jingling/*` 原生模式(Android 13+ 需 `POST_NOTIFICATIONS` 运行时权限,拒绝则只保活不发通知,设置页提供授权入口)。同一时刻只有一条等待(会话与任务共用),因为单用户不会同时等两件事 |
| 2026-11-16 | M3.6 实现坑 | ①`startService` 在 App 进后台后会被限制,停服务要用 `stopService`;前台服务的通知在 `stopService` 路径下不一定会自动消失,得在 `onDestroy` 里 `stopForeground(STOP_FOREGROUND_REMOVE)`;②Android 14+ 必须给前台服务声明 `foregroundServiceType` 并在 `startForeground` 传类型,否则直接崩;③通知权限被拒时启动前台服务会得到一个"看不见的通知",所以先用 `canNotify()` 判断,拒了就干脆不启动;④权限申请的 `await` 期间这一轮可能已经结束,`start` 回来后要再检查一次等待态,否则会留下一个空转的服务 |
| 2026-11-17 | **砍掉 `run_code` 沙箱(v1.5),把「手机原生提醒」提前到 v1.5**(用户 2026-11-17 拍板)。理由:①dsh 桥已覆盖"真跑代码"(真实仓库/真实环境/逐条审批),"验证代码"不需要服务器沙箱;②服务器自身在 Docker 容器内,再开容器要挂 `/var/run/docker.sock`,等于把宿主 root 交给本服务,与"隔离"目的相反;③DESIGN 原定用途是"算数/数据处理/画图",而客户端目前没有图片渲染,画图回传要另做生成/存储/下载/渲染四件事;④手机 + 自有电脑常在的场景下,增量只剩"电脑不在线时算个数"。而 agent 说「提醒我 8 点」目前什么都不发生,缺口更硬 |
| 2026-11-18 | **M7 手机原生提醒交付(v1.3.0)** | 三件套工具 `reminder_create/cancel/list` + `reminder` 表(会话删除 `SET NULL`,提醒不随会话消失)+ SSE `reminder`/`reminder_cancel` + 每次请求前置「当前时间(Asia/Shanghai)」system 消息;手机端 Kotlin `setAlarmClock`(requestCode = id 哈希,天然幂等)+ `ReminderReceiver`(通知带「稍后 10 分钟」「完成」)+ `BootReceiver`,设置页新增「提醒」列表。**真机实测**:锁屏息屏到点弹通知(`jingling_reminder`,importance=4)、取消即消、过期行收尾成 `fired`;**MIUI 默认拦第三方自启动**,重启后要靠「自启动」权限才能自动重建,退路是打开一次 App 自动补排(已验证)。测试 server 43 / app 48 |
| 2026-11-18 | **M8 前端重设计交付(v1.4.0,方向 A「素净」)** | 用户从三套方向(A 素净 / B 控制台 / C 书卷)里选 A,并放开信息架构。落地:①**设计令牌**(`lib/design/tokens.dart`,颜色/字号/间距/圆角/动效;浅深两套)与主题(`theme.dart`,含 `AppPalette` 扩展);②**内置 Noto Sans SC 可变字体**(GB2312 全字表子集 3.61MB,`FontVariation` 取字重)—— 之前界面全盘跟着手机系统字体走(手写体),现在不受影响;③**会话列表**重排:置顶/今天/昨天/本周/更早分组、本地搜索、顶栏收成「＋/⋯」(临时对话/记忆/电脑/用量/设置进 ⋯)、有电脑任务时顶部横幅;④**对话页**:顶栏只留标题 + ⋯(朗读这条/重命名/置顶/删除),自动朗读开关移入设置,输入区重排为「＋ [输入框] [发送]」,发送钮三态(空禁用/可发/生成中=停止);⑤统一空状态组件与卡片列表行;⑥预览文本去 Markdown 记号。守卫测试:分组纯函数、令牌自洽、`lib/` 无裸 `Color(0x…)`(白名单只有令牌与语法高亮色板)。APK 19.5→21.2MB(+1.7MB),测试 app 65 条 |



