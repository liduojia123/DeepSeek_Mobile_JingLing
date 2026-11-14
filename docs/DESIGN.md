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

**插件五项能力假设**(M3 spike 必须逐项验证):
1. 枚举工作区与会话列表
2. 订阅会话事件流(文本输出、工具调用)
3. 注入用户输入(派任务、追问)
4. **拦截工具调用确认请求**→转发手机→回传批准/拒绝→运行时继续
5. 发起出站 WebSocket 连接

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
| `/v1/conversations/{id}/stop` | POST | 中断当前生成 |
| `/v1/files` | POST | 上传文件(multipart)→ file_id 与解析状态 |
| `/v1/asr` | POST | 上传录音 → 识别文本 |
| `/v1/tts` | POST | 文本 → 音频流(mp3) |
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
| M2 搜索与文件 | 搜索过程卡片、引用、文件上传解析 | 带 URL 能读网页;传 PDF 能答 | 届时另出 |
| M3 dsh 远程开发桥 | spike→插件→服务器中继→电脑页 | 手机派任务+批准工具调用,任务完成 | §4.4 + 届时另出 |
| M4 语音闭环 | ASR/TTS 管道、录音 UI、播放打断、长按朗读 | 全程语音完成一轮问答 | 届时另出 |
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

**当前状态**:M0 已交付(见 §10,2026-11-14),真实 key 复测待补。下一步 M1 客户端核心,按 `docs/HANDOFF-M0-M1.md` §M1 执行。

## 11. 参考资料

- DeepSeek 全家桶应用 API 发布公告:https://api-docs.deepseek.com/zh-cn/news/news261113
- 构建 Chatbot 指南(SSE 事件示例):https://api-docs.deepseek.com/zh-cn/guides/build_a_chatbot
- Create Chat Completion API(tools / server_tool_calls):https://api-docs.deepseek.com/zh-cn/api/create-chat-completion
- DeepSeek Harness 官网:https://www.deepseek.com/zh/harness · 下载:https://www.deepseek.com/zh/download
- Harness 仓库:https://github.com/deepseek-ai/deepseek-harness(架构深读:#1103)
- 官方开源 Demo(参考实现):https://github.com/deepseek-ai/chat-demo
