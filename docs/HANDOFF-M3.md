# 鲸灵(JingLing)施工单 · M3 dsh 远程开发桥

> 执行者:DeepSeek Harness(dsh)· 前置:`docs/DESIGN.md` §4.4、`AGENTS.md`、本文件
> 范围:F13 dsh 远程开发(完整控制)。M4 及之后另出单。

## 0. Spike 结论(2026-11-15,以本机 dsh 3.x Desktop 源码为准)

原来的「五项能力假设」已逐项落到真实 API(来源:`app.asar/dsh/node_modules/@deepseek-ai/` 下的包 README,
经 Electron-as-node 读取;运行时装在 `D:\DeepSeek Harness\resources\app.asar\dsh`,profile=`desktop`):

| # | 能力 | 真实接口 | 备注 |
|---|---|---|---|
| 1 | 枚举工作区/会话 | `ctx.workspaceRegistry.list()`(工作区实体:title、目录、会话投影)<br>`ctx.sessionQuery.listSessions()`(全部逻辑会话,newest first,带 `live`/`persisted`) | 枚举不需要会话变 live |
| 2 | 订阅会话事件 | `agent/assistant-stream`(一次 assistant attempt 的 start / chunk / end 帧,chunk 从 0 稠密编号)<br>`agent/created`、`agent/disposed`、`agent/status`<br>`agent/inbox/inserted|claimed|discarded`<br>`session/event`(持久日志事件)、`turn/end`、`assistant/message`、`tool/result` | 展示层用 stream;可靠状态用持久事件(`assistant/message`/`tool/result`/`turn/end`) |
| 3 | 注入用户输入 | `agent.followup({ content:[{type:'text',text}], source:{kind:'user'} })`(排队下一轮并唤醒)<br>`agent.steer()`(下一步输入)<br>`agent.cancel({kind:'user'})`(停止) | `followup` 是「派任务」;`steer` 是「追问/纠偏」;`cancel` 是「停止」 |
| 4 | **拦截工具调用确认** | 注册 `approval/request` waterfall answerer:`ctx.on('approval/request', handler)`;返回 `allowed-once` / `rejected` / `cancelled`,非本插件的请求 `return next()` 委托;无 terminal answerer 时解析为 `unavailable`(**fail-closed**,与我们「超时未确认不执行」的红线一致) | 请求携带:agent/session、工具名、reason、可选 `callId`、abortSignal;**不携带工具参数**(已知限制,手机上只能展示工具名+理由) |
| 5 | 出站 WebSocket | 插件运行在 Host(Electron Node)进程,可直接出站;无入站端口 | 断线重连由插件自己背 |

其它关键事实:

- 插件包形态:`package.json` 里 `dsh.bundle.patch` 指向 `cordis.patch.yml`,patch 里 `insert` 一行插件 id + `name` + `config`;`index.js` 导出 `apply(ctx, config)`(可选 `export const inject = [...]`、`export const Config`)。
- 安装走 `plugin_manager` 的 `install_bundle`(绝对路径),或用户在 **Plugins > Add plugin** 里手动加本地目录。
- Agent 事件与注册要在对的 context 上:`agent/created` 里用 `agent.ctx` 注册 per-agent 监听,并在插件自己的 effect 里保留 disposer。
- 审批策略:会话级 `ask`/`never`;`never` 会在服务层直接拒,不经过 answerer。因此桥接场景要保持会话为 `ask`,由我们的 answerer 负责转发到手机。
- 请求只在 turn 内有效;手机回传慢于超时即按 fail-closed 处理(返回 `rejected`/`unavailable`)。

## 0.1 实测补充(2026-11-15,已在本机真实运行时验证)

插件装到 desktop profile 后,用真机路径实测到的细节(与上文一起作为实现依据):

| 项 | 实测结果 |
|---|---|
| 插件安装 | `plugin_manager install_bundle` 可用,`application: applied` 立即生效(本地目录是链接,改代码后 `set_plugin` 禁用→启用可加载新代码;**整个宿主进程重启前不会自动热更**) |
| 出站 WS | ✅ 插件 `new WebSocket()` 直连服务器成功(Electron 44/Node 24,全局 WebSocket 可用,无需 `ws` 依赖) |
| 枚举 | ✅ `ctx.workspaceRegistry.list()` 返回 5 个真实工作区;`ctx.sessionQuery.listSessions()` 是**异步**,返回 `{header:{id,createdAt,cwd,parentSession,isSeeded,origin,delegationDepth,agentPreset}, live, persisted}` |
| 注入输入 | ✅ `agents.get(id)` / `agents.resume({ resumeSessionId })`(注意参数名不是 sessionId,写错会抛 `Cannot read properties of undefined (reading 'length')`)→ `agent.followup({content:[{type:'text',text}],source:{kind:'jingling'}})` 真实执行,输出经 `agent/assistant-stream` 的 `text-delta` 回传,任务状态 done |
| 服务访问 | **Cordis 服务必须声明 `inject` 或使用 `ctx.get(name)`**;直接 `ctx.workspaceRegistry` 会抛 `cannot get property "workspaceRegistry" without inject` |
| 审批 answerer | 注册方式确认:`ctx.on('approval/request', async (req, next) => outcome)`,outcome ∈ `allowed-once/rejected/cancelled/unavailable`;`req = {agent, toolName, callId?, reason?, displayReason?, signal?}`(**无工具参数**);未被插件接管的请求必须 `return next()` |
| 会话策略 | 每个 Session 有自己的审批策略(`approval/policy` 事件);历史里是 `never` 的会话不会走 answerer,需要 `ctx.approval.setPolicy(agent,'ask')` 切回 |
| 新建会话 | `agents.create({ sessionId:'session-<uuid>', agentOptions:{provider,model}, meta:{cwd, agentPreset} })`;**必须给模型路由,且 agentPreset 决定工具集**,否则新会话"无工具可用" |
| 插件生命周期坑 | 热重载会残留旧实例(多个 WS 同时在线)。已加:①进程级单例守卫;②hello 上报 `capabilities:['v2',…]`,服务器优先选 v2 节点;③服务器对同机旧连接发 `stand_down`,插件收到后自我停止 |

**尚未端到端验证**:审批卡片真实触发(需要一个"有工具 + 策略 ask + 可恢复"的会话;本机历史会话存在策略为 never、或恢复校验失败的情况)。answerer 代码已按上述契约实现,下一步用新建会话(继承 preset)验证。
## 1. 架构(定稿)

```
手机 App ──HTTPS+SSE──▶ 鲸灵服务器 ──outbound WSS──▶ dsh 桥插件(运行在 dsh Host 进程)
   │                    │  /v1/harness/bridge                │
   │                    │  /v1/harness/workspaces            ├─ workspaceRegistry / sessionQuery 枚举
   │                    │  /v1/harness/tasks (followup/steer)├─ agent.followup/steer/cancel
   │                    │  /v1/harness/tasks/:id/events(SSE) ├─ agent/assistant-stream + 持久事件
   │                    └  /v1/harness/tasks/:id/confirm     └─ approval/request answerer(转发手机)
```

- 电脑不开任何入站端口;插件主动外连,断线指数退避重连。
- 桥接用**独立 bridge token**(与设备令牌分离),只存在服务器与插件配置里。
- 手机端确认卡片:**默认拒绝**,15s 未确认 → `rejected`(fail-closed)。
- 事件流与手机端 SSE 沿用 DPAPP 协议的新事件类型(见 §4)。

## 2. 插件(`bridge-dsh/`,独立模块)

1. **包骨架**:`bridge-dsh/{package.json,cordis.patch.yml,index.js,locale/{zh,en}.json,icon.svg,docs/DETAIL.md}`;`Config` 用 schemastery 声明 `serverUrl`、`bridgeToken`、`nodeName`、`reconnect` 参数。
2. **连接层**:出站 WSS 到 `${serverUrl}/v1/harness/bridge?token=...`;首帧 `hello{node,platform,version}`;心跳 ping/pong;断线指数退避(1s→30s 上限)。
3. **RPC**:服务器下发 `{type:'rpc', id, method, params}` → 插件回 `{type:'rpc-result', id, ok, result|error}`。方法:
   - `workspaces.list` → 工作区 + 各自会话(标题、id、cwd、最近活动)
   - `sessions.list` / `sessions.get`
   - `tasks.start` → 对指定 session `agent.followup({content, source:{kind:'jingling'}})`(会话不存在则 `agents.resume` 或 `create`)
   - `tasks.steer` / `tasks.cancel`
   - `events.subscribe` / `events.unsubscribe`(按 session 订阅)
4. **事件上行**:订阅中的会话,把 `agent/assistant-stream` 的 start/chunk/end 归一化成 DPAPP 事件;`assistant/message`、`tool/result`、`turn/end` 作为可靠终态补发;带上 `task_id`/`session_id` 便于服务器落 `harness_event`。
5. **审批 answerer**:`ctx.on('approval/request', ...)`;把请求转成 `confirm_request` 上行(带 request id、session、tool、reason),等待服务器回 `confirm_result`;超时/断线 → 返回 `rejected`(并在日志与审计里注明 fail-closed)。非本插件的其它请求 `return next()`。
6. **卸载干净**:所有监听/定时器在 `apply` 返回的 disposer 里清理;per-agent 注册用 `agent.ctx` 并保留 disposer。

## 3. 服务器(`server/src/routes/harness.ts`)

1. **WS 接入**:`GET /v1/harness/bridge`(用 `@fastify/websocket` 或原生 ws),鉴权用 bridge token(env `BRIDGE_TOKEN`,库里只存 sha256 的话需要建 `harness_node` 表——见下);节点上线 `last_seen`、状态。
2. **节点/任务表**(DESIGN §5.2 已预留):`harness_node`、`harness_task`、`harness_event`;任务 id 由服务器生成,事件按到达顺序落库 + 同时推给手机的 SSE。
3. **REST**(手机用):
   - `GET /v1/harness/nodes` — 已连接节点
   - `GET /v1/harness/workspaces` — 代理 `workspaces.list`
   - `POST /v1/harness/tasks` `{session_id|workspace, prompt}` → `task_id`,并发起 `tasks.start`
   - `GET /v1/harness/tasks/{id}/events`(SSE)— 实时输出/工具调用/确认请求/完成
   - `POST /v1/harness/tasks/{id}/confirm` `{approval_id, decision}` — 批准/拒绝;**未确认超时按拒绝**
   - `POST /v1/harness/tasks/{id}/stop`
4. **确认路径**:服务器收到插件 `confirm_request` → 写 `harness_event` → 推给手机 SSE → 手机 POST confirm → 服务器回 WS `confirm_result`;手机在 15s 内没回或断线 → 服务器回 `rejected`,同时给手机补一条 `confirm_timeout` 事件。
5. **成本与安全**:桥接流量不经过 DeepSeek(只转发),但任务本身消耗电脑上的 dsh 额度——按任务记录起止时间;bridge token 泄漏只影响桥接。

## 4. DPAPP 协议扩展(手机端)

新增事件(与现有 SSE 同一条通道,`source: 'harness'`):
```
event: harness_node     {node_id, name, online, last_seen}
event: harness_task     {task_id, session_id, status: running|done|error|stopped}
event: harness_output   {task_id, text}            # assistant 文本增量
event: harness_tool     {task_id, tool, phase}     # 可选:工具开始/结束提示
event: harness_confirm  {task_id, approval_id, tool, reason, timeout_sec}
event: harness_done     {task_id, stop_reason}
```
`harness_confirm` 必须能被手机以 `POST /v1/harness/tasks/{id}/confirm` 回答;超时即拒。

## 5. 手机端(Flutter 电脑页)

1. 入口:会话列表页加「电脑」页(或设置里的入口);页面拉 `nodes`/`workspaces`。
2. 工作区 → 会话列表 → 选会话 → 输入任务(`followup`)→ 实时输出流。
3. 确认卡片:收到 `harness_confirm` 弹卡片,显示工具名与理由(参数拿不到,这是 dsh 的已知限制),15s 倒计时;**批准/拒绝**,超时显示已自动拒绝。
4. 停止按钮 → `POST .../stop`(插件侧 `agent.cancel`)。
5. 断线状态:节点离线时页面置灰并提示。

## 6. 验证清单

1. 插件能安装并在 Plugins 里看到(标题/描述/图标齐全),启用后 WS 连上服务器(服务器日志有 `hello`)。
2. `GET /v1/harness/workspaces` 返回本机真实工作区与最近会话。
3. 手机派一个简单任务(“列出当前目录前 5 个文件”)→ 手机上能看到流式输出 → 任务 done。
4. 派一个**需要确认**的任务(比如写文件/执行命令)→ 手机收到确认卡片 → 拒绝 → 插件侧工具调用被拒、会话继续;批准 → 工具执行。
5. 15s 不确认 → 自动拒绝(fail-closed),会话里能看到拒绝结果。
6. 断线重连:拔网/重启服务器 → 插件指数退避重连成功,节点重新上线。
7. 真机:用生产服务器(`https://www.example.com:8000/jingling`)完成 2–4。

## 7. 完成定义(DoD)

- 插件源码在 `bridge-dsh/`,独立模块,不把 dsh 内部类型泄漏进 `server/`/`app/`;
- 验证清单 1–6 通过,7 真机通过;
- 把真实接口回填 `DESIGN.md` §4.4(替换五项假设),新增 `harness_*` 表与接口进 §5.1/§5.2;
- 密钥纪律:bridge token 只在服务器 env 与插件配置;`DEEPSEEK_API_KEY` 不出现。

## 8. 明确不做

- 远程控制 dsh 的 GUI 操作(只做会话/任务级别);
- 多节点负载均衡(先支持一个节点,多节点留字段);
- 通过桥接下载电脑上的文件(M6 后另议)。

## 0.2 未完成项(2026-11-15 实测记录)

**审批卡片端到端触发尚未复现**。已排除的原因:
- answerer 已按 `approval/request` 契约注册(代码在 `bridge-dsh/index.js`),但需要「会触发审批的工具调用」才会被调用;
- 本机历史会话里,有些会话在 dsh 侧恢复校验失败(`session event at seq N lacks an identified message`),不能用来测试;
- 新建会话(`agents.create`)的工具集取决于 `meta.agentPreset`,实测传入 `standard` 后新会话仍只拿到全局工具(ego-browser 等),没有 fs/bash 沙箱工具,于是模型改用 ego 的 Node heredoc 直接写文件——绕过了审批通道。

下一步:**先验证 agentPreset 是否真的落到新会话 header**(`session.header.agentPreset`),必要时改用 `agents.create({ meta:{agentPreset} })` 之外的方式(例如从 live agent 继承 preset、或用 `setup` 回调安装工具),再跑一次「越界写文件」触发 `confirm_request`。

## 0.3 电脑页与「live 会话优先」(2026-11-15)

- 手机端「电脑页」已实现并验证渲染:节点在线状态、真实工作区列表(5 个)、工作区内会话列表(带「运行中」标记)、派任务输入框。
- **历史会话恢复受限**:本机 32 个历史会话里,绝大多数 `agents.resume({resumeSessionId})` 会因 dsh 侧会话校验失败被拒(`session event at seq N lacks an identified message` / `not found`),少数能 resume 的也无法保证带完整预设工具。
- 因此桥接的产品口径调整为:**优先操作 dsh 当前 live 的会话**(`agents.get(sessionId)`);对非 live 会话保留 `resume` 作为尽力而为,失败时把 dsh 的错误透传给手机。
- 审批端到端仍待验证:需要「live + 带 fs/pwsh 工具 + 策略 ask」的会话;建议由用户在电脑上开着一个会话时验证。

## 0.4 工具调用确认(已打通,生产验证)

**结论:用 `tools/pre-execute` 而不是 `approval/request` 做确认拦截。**

- `approval/request` 在 preset 隔离域里注册位置敏感(需在 `agent/created` 里注册到 `agent.ctx`),且**不携带工具参数**;实测在远程新建 agent 上不稳定。
- `tools/pre-execute`(waterfall)可拿到工具名 + 完整参数,返回 `next()` 放行、`{kind:'deny', reason}` 拒绝。已在生产验证:
  - 拒绝:手机收到 `tool=write` + 参数(file_path/content/sandbox_permissions/justification),拒绝 → 文件未写入 ✅
  - 超时:15s 不回应 → 服务端自动 `confirm_result{decision:reject,timeout:true}` → 文件未写入 ✅(fail-closed)
- 同一调用会再触发一次沙箱升级的 `approval/request`,已用 `rootCallId` 关联:手机批准过的调用在 approval seam 自动 `allowed-once`,避免二次弹卡。
- **未完成**:手机「批准」后,`write` 到工作区外仍然被 dsh 沙箱拒绝(两次工具调用均失败,文件未创建)。说明沙箱升级不是 approval 可放行的路径,需要在会话级切换权限预设(等同用户在 dsh 里选 danger-full-access),或接受"远程只能执行沙箱内允许的操作"。下一步验证 `permission-presets` 的会话级 API。

## 0.5 权限模式 + 批准后真正执行(生产验证通过,2026-11-15)

**结论:`tools/pre-execute` 负责逐条确认,`ctx.permissionPresets.set(session, preset)` 负责让批准的操作真的能执行。**

- 会话级权限开关:`)permissionPresets.set(agent.session, 'workspace-write' | 'danger-full-access')`,对应 dsh 的「权限预设」(沙箱 + 审批策略一起切)。
- 任务创建接口新增 `permission_mode`,插件在 agent 就绪后先切权限、再派任务;REST `GET/POST /v1/harness/tasks/:id/permission` 可查/改。
- 端到端实测(生产):
  1. `permission_mode=danger-full-access` + `require_approval=true` + `agent_preset=standard` 新建会话
  2. 模型调用 `write` → 手机收到确认(带 file_path/content/sandbox_permissions/justification)
  3. 手机批准 → 文件**真的写入成功**(内容 `hello-fullaccess`)
  4. 随后 `read` 调用也逐条弹确认 → 批准 → 读取成功
  5. 拒绝/超时路径此前已验证:文件不写入(fail-closed)
- 注意:
  - 只切 `danger-full-access` 会把审批策略一并设成 `never`,但**我们的 pre-execute 确认门是独立 waterfall,不受影响**,手机上照样逐条确认。
  - 权限预设切换后 dsh 侧可能显示 `custom`(沙箱与审批组合不匹配预设表),但沙箱模式已生效。
  - 目前所有工具(含 read)都会弹确认;后续可按工具白名单降低打扰。
- 客户端:电脑页新增「权限」开关(沙箱内 / 完全访问),派任务时随请求带上;`flutter analyze` 0、测试 11/11。
