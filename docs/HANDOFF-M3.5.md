# 鲸灵施工单 · M3.5 dsh 会话级桥接(手机 = 第二窗口)

> 执行者:DeepSeek Harness(dsh)· 前置:`docs/DESIGN.md` §4.4、`AGENTS.md`、`docs/HANDOFF-M3.md`
> 目标:手机与电脑共用**同一个 dsh 会话**——进得去、看得见历史与实时、跑的时候能插话、跑完能追加、也能新开会话。
> 本单只做会话级能力;M3 的"任务级"接口保留(旧版 App 仍可用)。

## 0. 需求口径(用户确认,2026-11-15)

- 手机要接的**就是电脑上正开着的那个会话**(同一份对话),同时要有**新建会话**的能力。
- 使用场景:**离开电脑时**派任务/看进度,所以"任务跑在电脑上、手机不盯着也不丢消息"是硬要求。
- 要的体验:和电脑上差不多 —— 能看到工具调用过程,能中途插话改方向,任务结束能接着追问。

## 1. 已验证的 dsh 接口事实(信源:本机 `app.asar` 内 `@deepseek-ai/*` 源码与 `docs/subsystems/*`)

| 能力 | 真接口 | 备注 |
|---|---|---|
| 会话持久事件(历史+实时同一套) | `ctx.on('session/event', (session, event) => …)`;`event = {type, seq, time, data}` | seq 会话内单调,可作为"已看到哪"的游标 |
| 历史读取 | `sessionQuery.readSurface(sessionId)` → `{events: SurfaceEvent[], capturedThroughSeq}` | 事件自带 `seq`;含 `events` 是当前表层(被压缩/替换后的),适合手机时间线 |
| 会话实时增量 | `agent/assistant-stream` 的 `frame.chunk`:`text-delta` / `reasoning-delta` / `tool-call-delta` / `block-start` / `block-end` | 进程本地,不落库;只做"正在打字"的呈现 |
| 输入 | `agent.followup({content, source})` 排队下一轮;`agent.steer({content, source})` 交给下一步;`agent.cancel(cause)` 停止 | `agent.status` 只有 `idle` / `running` |
| 会话状态 | `agents.get(sessionId).status`;`permissionPresets.current(agent.session)` | |
| 新会话 | `agents.create({sessionId, agentOptions:{provider,model}, meta:{cwd, agentPreset}})` | preset 决定工具集(HANDOFF-M3 §0.2 遗留) |
| 待处理输入 | `agent/inbox/inserted|claimed|discarded` `{message}` | 用来给手机显示"插话排队中/已被采纳" |
| 内容块 | `text` / `reasoning` / `image` / `file` / `tool-call{id,name,arguments}` | |

**关键结论**:过去手机看不到电脑上的对话,是因为插件按 `task_id` 订阅(`taskIdOfSession()` 一关挡掉所有非手机任务)。改成按 `session` 订阅后,本地用户说的话也会经 `session/event` 流到手机 —— 这就是"同一份对话"。

## 2. 架构

```
手机会话页 ──SSE(GET /v1/harness/sessions/:id/stream?after_seq=N)──▶ 鲸灵服务器
                                                                     │  会话事件表(seq 游标)+ 观察者引用计数
手机输入 ──POST /v1/harness/sessions/:id/input {text,mode}──▶          │
                                                                     ▼
                                                      插件(电脑) ── session.watch.start / input.send
                                                        ├ ctx.on('session/event')  → 压缩后上行(持久)
                                                        ├ agent/assistant-stream   → 文本增量(瞬时)
                                                        ├ agent/status / inbox/*   → 状态与排队提示
                                                        └ agents.get/resume/create / followup / steer / cancel
```

- 一条 SSE = 一个会话。`after_seq` 之后的事件先补发(库里),再接实时,断线重连不丢。
- 服务器给每个会话维护自己的 `seq`(单调、落库),`dsh_seq` 单独存,用于去重(插件重连补发不会重复插入)。
- 观察者引用计数:有手机在看时才让插件 `session.watch.start`,最后一个断开就 `watch.stop`,不给电脑添无谓开销。

## 3. 服务端(`server/src/routes/harness.ts` + `db.ts`)

### 3.1 新表

```sql
CREATE TABLE IF NOT EXISTS harness_stream_event (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   TEXT NOT NULL,
  seq          INTEGER NOT NULL,          -- 服务器本地游标(每会话从 1 递增)
  dsh_seq      INTEGER,                   -- dsh 会话事件序号(瞬时事件为 NULL)
  kind         TEXT NOT NULL,             -- user_message / assistant_message / tool_call / tool_result / turn_start / turn_end
  payload_json TEXT NOT NULL,
  ts           TEXT NOT NULL,
  UNIQUE (session_id, seq)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_stream_session_dsh ON harness_stream_event(session_id, dsh_seq)
  WHERE dsh_seq IS NOT NULL;
```

### 3.2 端点(手机侧)

| 端点 | 说明 |
|---|---|
| `GET /v1/harness/sessions/{id}/stream?after_seq=N` | SSE;先补发 `seq>N` 的持久事件,再收实时;首帧 `harness_session_ready{session_id,last_seq,status,permission}` |
| `POST /v1/harness/sessions/{id}/input` `{text, mode: auto\|steer\|followup}` | 送入会话;`auto` = 电脑上正在跑就 steer,空闲就 followup。返回 `{mode, status}` |
| `POST /v1/harness/sessions/{id}/stop` | `agent.cancel({kind:'user'})` |
| `GET /v1/harness/sessions/{id}/state` | `{status, permission, model, inbox:{next_turn,next_step}, node}` |
| `PUT /v1/harness/sessions/{id}/permission` `{mode}` | 会话级权限(沙箱内 / 完全访问) |
| `POST /v1/harness/sessions` `{cwd, agent_preset?, permission?, node_id?}` | 新会话 → `{session_id}` |

### 3.3 SSE 事件(手机要理解的)

```
event: harness_session_ready   {session_id, last_seq, status, permission}
event: harness_session_event   {session_id, seq, dsh_seq, kind, payload}
      kind ∈ user_message | assistant_message | tool_call | tool_result | turn_start | turn_end
event: harness_session_live    {session_id, kind, ...}
      kind=text|reasoning {text} / status {status} / inbox {action} / input_echo {text, mode}
event: harness_session_confirm {session_id, approval_id, tool, reason, params?, timeout_sec}
event: harness_session_error   {session_id, message}
```

`payload` 结构(插件压缩后的统一形态,详见 §4.3):

- `user_message {text, source, message_id}`
- `assistant_message {text, reasoning, tools:[{call_id,name,arguments}], usage?, interrupted?, turn, step}`
- `tool_call {call_id, name, arguments}`
- `tool_result {call_id, name?, is_error, text, reason?}`
- `turn_start {turn}` / `turn_end {turn, reason}`

### 3.4 生命周期

1. 手机连 SSE → `after_seq` 补发(库里没有就 bootstrap:rpc `session.events` 拉最近 300 条,分配 seq 落库)→ `ready` → 订阅。
2. 订阅者从 0→1:rpc `session.watch.start`;从 1→0:rpc `session.watch.stop`。
3. 插件上行 `session_event{dsh_seq, kind, payload}` → 按 `(session_id,dsh_seq)` 去重 → 分配 seq → 落库 → 广播。
4. 插件上行 `live` → 直接广播,不落库。
5. 节点断开:给所有该节点的会话订阅者发 `harness_session_error{message:'电脑节点断开连接'}`(不结束 SSE,等重连后补发)。

## 4. 插件(`bridge-dsh/index.js`)

### 4.1 新增 RPC

| 方法 | 参数 | 返回 |
|---|---|---|
| `session.watch.start` | `{session_id}` | `{ok:true}` |
| `session.watch.stop` | `{session_id}` | `{ok:true}` |
| `session.events` | `{session_id, limit}` | `{events:[{seq,type,data}], captured_through_seq}`(压缩后) |
| `input.send` | `{session_id, text, mode}` | `{mode, status}` |
| `session.stop` | `{session_id}` | `{ok:true}` |
| `session.state` | `{session_id}` | `{status, permission, model, inbox}` |
| `session.create` | `{cwd, agent_preset?, permission?}` | `{session_id}` |

`input.send`:取 live agent(没有就 `resume`,失败再 `create`,沿用 M3 的逻辑);`mode=auto` 时看 `agent.status`;`steer` 走 `agent.steer`,否则 `agent.followup`;source 统一 `{kind:'jingling'}`。

### 4.2 上行

- **持久**:`ctx.on('session/event')` → 仅 `watched` 的会话 → 压缩 → `{type:'session_event', session_id, dsh_seq:event.seq, kind, payload}`。
- **瞬时**:`agent/assistant-stream` 的 `text-delta`/`reasoning-delta` → `{type:'live', session_id, kind:'text'|'reasoning', text}`;`agent/status` → `live kind='status'`;`agent/inbox/*` → `live kind='inbox'`(action: inserted/claimed/discarded)。
- 原有 task 级事件保留(旧客户端)。

### 4.3 压缩规则(只发手机需要的、且截断大字段)

| dsh 事件 | 处理 |
|---|---|
| `user/message` | `text`(text 块拼接)、`source=source.kind`、`message_id`;`source.kind` 不是 `user`/`jingling` 的(agent 注入上下文)丢弃 |
| `assistant/message` | `text`、`reasoning`、`tools[{call_id,name,arguments≤4000}]`、`usage`、`interrupted`、`turn/step` |
| `tool/call` | `{call_id, name, arguments≤4000}` |
| `tool/result` | `{call_id, is_error, text≤4000, reason}` |
| `turn/start`、`turn/end` | `{turn}`、`{turn, reason}` |
| 其余(system/developer/request/*/compaction/*) | 丢弃 |

## 5. 客户端(Flutter)

1. **会话页** `app/lib/pages/harness_session_page.dart`:
   - AppBar:会话标题 + 状态(空闲 / 电脑上正在跑)+ 权限入口 + 停止;
   - 时间线:历史与实时同一套渲染——用户气泡(带"手机"标记)、助手正文(复用 `ChatMarkdown`)、工具卡片(名称 + 参数可展开 + 结果)。
   - 输入框:单行/多行输入;`agent.status=running` 时按钮显示「插话」,否则「发送」;发送后本地显示待发气泡(输入回显),持久 `user_message` 到达后替换。
   - 断线:自动重连(指数退避),用 `last_seq` 续传。
2. **电脑页**:会话条目点击 → 进会话页;顶部新增「新会话」(选工作区 + 权限)→ 创建后直接进会话页。
3. **协议模型**:`app/lib/models/harness_stream.dart`(事件与时间线条目)。
4. **测试**:tokenizer 式纯逻辑测试(`HarnessTimeline.apply(event)`:用户/助手/工具合并顺序、tool_result 合并、重复 dsh_seq 幂等)+ 页面组件测试(渲染一条助手消息 + 工具卡片)。

## 6. 验证清单

1. `cd server && npm test` 全绿(新增:会话流 bootstrap/补发/去重/输入/mode 判定);
2. `cd app && flutter analyze` 0 issue、`flutter test` 全绿(新增时间线合并与页面渲染);
3. **真机/真 dsh**(需用户重启 dsh 加载新插件):
   - 电脑上打开一个会话说话 → 手机进入同一会话能看到刚才那句话和回答;
   - 手机发「插话」→ 电脑侧当前回合的下一步采纳,手机看到排队→采纳;
   - 回合结束后手机「发送」→ 新一轮开始,电脑上同步出现;
   - 手机关掉重开 → 历史仍在,断线期间的输出补齐;
   - 手机「新会话」→ 电脑侧出现新会话,可正常派活;
   - 工具确认仍然可用(批准/拒绝/超时)。
4. 旧接口回归:旧版 App 的 `/v1/harness/tasks/*` 仍可用。

## 7. 明确不做

- 手机端编辑/删除会话事件(只读时间线 + 输入);
- 附件上传到 dsh 会话(v1.5 再说);
- 多电脑同时观察同一会话(仍是单节点;`node_id` 字段预留);
- 手机端 fork / compaction 面板。
