# 鲸灵施工单 · M7 手机原生提醒(精确闹钟 + 系统通知)

> 状态:**已实现**(2026-11-17),server 42/42、app 48/48、`flutter analyze` 零 issue;真机验证待手机接回 USB。
> 实现偏差见 §7。
>
> 前置:`docs/DESIGN.md` §3 v1.5(G1)、§4.2、§10;`docs/HANDOFF-M3.6.md`(原生通道与通知的既有模式);`AGENTS.md`
> 目标:用户在手机上跟 agent 说「20 分钟后提醒我关火」「明天 8 点叫我」→ **到点手机真的响**(自己的通知 + 提示音),不依赖 App 当时在前台。
> 拍板:2026-11-17 用户定 **AlarmManager(精确闹钟 + 通知)**,不做系统日历(提醒≠日程)。文档经两轮独立评审("照它干活的人"提问题),结论已吸收。

## 0. 范围

**做**

- 服务端工具:`reminder_create`(建)、`reminder_cancel`(删)、`reminder_list`(查)——用户能说"取消我刚才那个提醒""我都设了啥"。
- 服务端落库 + 在本次对话 SSE 流里下发 `reminder` / `reminder_cancel` 事件。
- 手机端 `AlarmManager.setAlarmClock()` 注册精确闹钟;到点 `BroadcastReceiver` 发通知(有声音),带「稍后 10 分钟」「完成」。
- 重启后重建闹钟(`BOOT_COMPLETED`);App 启动/回前台时**全量补排**(服务端 pending + scheduled)。
- 设置 →「提醒」列表:已排/已取消,可取消;列表时间**以手机本地已排闹钟为准**。

**不做(non-goals)**

- 不做系统日历、不做重复提醒(每天/每周)、不做全屏闹钟弹窗、不做 iOS。
- 不做电脑端 dsh 会话里设提醒(手机没参与,无人接收;要覆盖得先有"设备工具通道")。
- 不做 FCM/APNs;事件投递是 best-effort,靠补排兜底。
- 不新增 mock 工具合成:`MOCK=1` 不模拟模型调 `reminder_create`;可测性靠 server 单测 + Flutter 假通道。
- 单手机假设:不分设备,两台手机都补排会各响一次。

**约束**

- 协议单一来源:`server/src/deepseek/events.ts` ↔ `app/lib/models/events.dart`,顶部注释互指。
- 不引第三方插件:原生侧 `ReminderScheduler` + `ReminderReceiver` + `BootReceiver`,沿用 `jingling/installer`、`jingling/wait` 的 MethodChannel 模式。
- 对话里的提醒卡片**只是本轮反馈**,不进消息树(现有工具卡片同样是瞬时的,`providers.dart` 每轮结束会清 `streamingToolTraces`)。撤销的常驻入口是 设置→提醒,或直接对 agent 说"取消"。

## 1. 数据模型(server)

```sql
CREATE TABLE IF NOT EXISTS reminder (
  id              TEXT PRIMARY KEY,
  conversation_id TEXT REFERENCES conversation(id) ON DELETE SET NULL,  -- 会话删了提醒还在(见 §6)
  text            TEXT NOT NULL,
  fire_at         TEXT NOT NULL,   -- UTC 存储,线上按 ISO8601 带偏移传输
  status          TEXT NOT NULL DEFAULT 'pending',  -- pending | scheduled | fired | cancelled
  native_alarm_id TEXT,
  created_at      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_reminder_status ON reminder (status, fire_at);
```

`conversation_id` 可空:`db.ts` 开了 `foreign_keys = ON`,临时会话会被定期清扫;提醒是用户显式产物,**不随会话消失**,所以用 `ON DELETE SET NULL`(不是 CASCADE)。

状态由手机回传推进:`POST /v1/reminders/:id/ack` body `{status, native_alarm_id?, fire_at?}`。`fire_at` 可选:稍后提醒时手机回写新时间。

## 2. 服务端

### 2.1 工具声明(`server/src/agent/tools.ts`)

```jsonc
// reminder_create
{ "name": "reminder_create",
  "description": "为用户设置到点提醒(手机本地精确闹钟+系统通知)。用户说「提醒我…」「X 分钟后叫我」「明天 8 点提醒我」时调用。fire_at 必须是把相对时间换算后的、带时区偏移的 ISO8601;拿不准先问。",
  "parameters": { "text": {"type":"string","description":"提醒内容,简短,如「关火」"},
                  "fire_at": {"type":"string","description":"触发时间,ISO8601 带偏移"}},
  "required": ["text","fire_at"] }

// reminder_cancel
{ "name": "reminder_cancel",
  "description": "取消一个已设的提醒。用户说「取消提醒」「别提醒了」时用;先用 reminder_list 找到 id,只匹配到一条就直接取消。",
  "parameters": { "reminder_id": {"type":"string","description":"reminder_list 返回的 id"} },
  "required": ["reminder_id"] }

// reminder_list
{ "name": "reminder_list",
  "description": "列出用户还没响的提醒(取消前先查)。",
  "parameters": { "limit": {"type":"number","description":"默认 10,最大 50"} } }
```

### 2.2 执行(`executeClientTool`,签名加 `emit`)

- `reminder_create`:校验 `fire_at` 可解析且 `>= now + 10s`(过去/太近返回失败文本让模型纠正);同 `(conversation_id, text, fire_at)` 且状态非 cancelled 时**复用不重复 emit**;写行 → `emit({type:'reminder',...})` → 返回「已设置提醒 20:30 关火(约 20 分钟后)」。
- `reminder_cancel`:按 id 找 `pending|scheduled` 行 → 置 `cancelled` → `emit({type:'reminder_cancel', reminder_id})` → 返回「已取消:20:30 关火」。找不到/已取消 → 返回失败文本。
- `reminder_list`:查 `status IN ('pending','scheduled') AND fire_at > now` 按时间升序。

### 2.3 当前时间要喂给模型

`loop.ts` 组请求时在最前面插一条 system(仅当 tools 非空):

```
当前时间:2026-11-17T18:10+08:00(Asia/Shanghai)。用户说「20 分钟后」「明天 8 点」等相对时间时以此为准。
```

用显式 `Asia/Shanghai` 格式化,不依赖容器 TZ;加测试断言存在且格式正确、其余消息顺序不变。

### 2.4 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/v1/reminders?status=active` | **补排**:返回 `pending` + `scheduled` 且 `fire_at > now`(同 id 重排是幂等的,见 §3.1) |
| POST | `/v1/reminders/:id/ack` | `{status, native_alarm_id?, fire_at?}` |

### 2.5 协议(`server/src/deepseek/events.ts`)

```ts
export const ReminderEvent = z.object({
  type: z.literal('reminder'), reminder_id: z.string(), text: z.string(), fire_at: z.string(),
});
export const ReminderCancelEvent = z.object({
  type: z.literal('reminder_cancel'), reminder_id: z.string(),
});
```

并入 `DpappEvent`;`message_end` 仍是唯一终止事件;未知事件客户端忽略。

## 3. 客户端

### 3.1 原生(Kotlin)

`ReminderScheduler.kt`

- `schedule(id, text, fireAtMs)`:`requestCode = id.hashCode()`;`PendingIntent.getBroadcast(..., FLAG_UPDATE_CURRENT or FLAG_IMMUTABLE)`;`setAlarmClock(AlarmClockInfo(fireAtMs, showIntent), pending)` —— 同 id 重排**天然覆盖**,这是补排可以无脑重发的原因。
- `cancel(id)`:cancel PendingIntent,并清本地副本(SharedPreferences `jingling_reminders`)。
- 精确闹钟:`canScheduleExactAlarms()`(API 31+)为 false → 返回 `error="exact_alarm_denied"`,由 Dart 引导去 `ACTION_REQUEST_SCHEDULE_EXACT_ALARM`。

`ReminderReceiver.kt`(exported=false):取 extra(id/text)→ 发通知(渠道 `jingling_reminder`,IMPORTANCE_HIGH),action「稍后 10 分钟」= 再 schedule 到 now+10min 并 `ack(fire_at=新时间, status='scheduled')`,action「完成」= 取消本地副本 + `ack(fired)`(由 Dart 在下次前台补做;原生不联网)。

`BootReceiver.kt`(RECEIVE_BOOT_COMPLETED,exported=false):读 SharedPreferences 里未来提醒重建闹钟,过期的丢弃。

`MainActivity` 通道 `jingling/reminders`:`schedule` / `cancel` / `listScheduled` / `canScheduleExact` / `openExactAlarmSettings`;通知权限复用 M3.6 的实现。

`AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM" android:maxSdkVersion="32" />
<uses-permission android:name="android.permission.USE_EXACT_ALARM" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
<receiver android:name=".ReminderReceiver" android:exported="false" />
<receiver android:name=".BootReceiver" android:exported="false">
  <intent-filter><action android:name="android.intent.action.BOOT_COMPLETED" /></intent-filter>
</receiver>
```

> `USE_EXACT_ALARM` 是闹钟类自动授予的权限,上架 Play 受限;本项目侧载自用,用它省掉手动授权。Android 12 走 `SCHEDULE_EXACT_ALARM` + 跳设置页兜底。

### 3.2 Dart

- `app/lib/models/events.dart`:镜像 `reminder` / `reminder_cancel`。
- `app/lib/core/reminders.dart`:`RemindersChannel`,吞 `MissingPluginException`。
- 会话控制器:收到 `reminder` → `schedule()` → 成功 `ack(scheduled)`;收到 `reminder_cancel` → `cancel()` → `ack(cancelled)`。失败(权限/精确闹钟未允许)→ 卡片显示原因 +「去授权」「重试」。
- **补排**:App 启动 + 回前台 →`GET /v1/reminders?status=active` → 逐条 schedule(幂等)→ ack。客户端维护**本地取消墓碑**(SharedPreferences 里 `cancelledIds`):补排遇到墓碑里的 id 直接跳过并重试 `ack(cancelled)`,避免"取消没 ack 成功、下次又被排回来"。
- **过期判定**:只对 `fire_at <= now` 且**本地没有已排闹钟**的条目 `ack(cancelled)`;有本地闹钟的(比如刚稍后过的)不动,避免误杀 snooze。
- 设置 →「提醒」页:`listScheduled()` 为时间真相,服务端 `pending` 补位;右侧「取消」→ `cancel()` + 墓碑 + `ack(cancelled)`。

### 3.3 UI

- 对话内:一条小卡片(复用工具卡片样式)⏰「20:30 · 关火」+ 状态,底部一句「要改或取消,去 设置→提醒,或直接跟我说」。**卡片不进历史**(§0 约束)。
- 通知:`jingling_reminder`,标题「鲸灵提醒」,正文 = 提醒文本,点击进 App,两个 action(稍后 10 分钟 / 完成)。

## 4. 验证清单

**server(单测)**

1. `reminder_create`:过去时间被拒;成功写库 + emit `reminder`;同(会话,文本,时间)不重复 emit。
2. `reminder_cancel`:状态置 cancelled + emit `reminder_cancel`;已取消再取消返回失败文本。
3. `reminder_list`:只返回 `fire_at > now` 的 pending/scheduled。
4. ack 流转:`scheduled` / `cancelled` / `fired`,以及带 `fire_at` 的 snooze 回写。
5. `GET ?status=active` 同时返回 pending 与未来的 scheduled。
6. system 当前时间消息存在、格式正确;删除会话后提醒仍在(`ON DELETE SET NULL`)。

**app(单测/假通道)**

7. `reminder` / `reminder_cancel` 事件解析。
8. 收到事件 → 调 `schedule`/`cancel`(断言 id/text/fireAtMs)。
9. `exact_alarm_denied` → 卡片走"未授权"分支,不 ack。
10. 补排:2 条 active → schedule 两次;墓碑里的 id 跳过并 ack cancelled;已过期且本地无闹钟 → ack cancelled。

**真机(小米 24129PN74C)**

11. 说「1 分钟后提醒我喝水」→ `adb shell dumpsys alarm | grep jingling` 有闹钟;等一分钟,**App 已 HOME 退出、屏幕已锁** 时收到通知并响。
12. 点「稍后 10 分钟」→ 10 分钟后再次响;设置→提醒 显示的是稍后后的时间。
13. 重启手机 → `dumpsys alarm` 里闹钟仍在(BOOT_COMPLETED 生效)。
14. 设置→提醒 取消 → 到点不响。
15. 说「取消提醒」→ agent 调 `reminder_cancel`,到点不响。
16. 说「提醒我昨天 8 点」→ 模型收到"时间已过"并反问,不写库。

## 5. 发版

`app/pubspec.yaml` → `1.3.0+15`;按 `AGENTS.md` 发布纪律(测试 → 构建 → commit/push → `gh release create` → 服务器 OTA 同步);`DESIGN.md` §10 追加完成记录,`CURRENT.md` 更新版本与已完成表。

## 6. 风险与已知限制
- **强制停止会清闹钟**:系统里「强行停止」或国产系统清理会清掉 AlarmManager(重启能恢复,强停不能);设置页能看到"将要响的提醒",取消/重设靠它。
- **精确闹钟权限**:Android 12 无 `USE_EXACT_ALARM` 时需用户手动允许;被拒**不做退化**,直接提示去授权。
- **会话删除不清提醒**:用户删了会话,提醒仍会响(提醒是显式产物);文本里已含内容,不依赖会话。
- **电脑端设提醒覆盖不到**(non-goal,等"设备工具通道")。
- **时间解析**:靠 system 当前时间 + "不能是过去"兜底;模型算错时用户会看到卡片上的具体时间,可立即取消重设。

## 7. 实现偏差(2026-11-17 落地时定)

1. **不新增独立"提醒卡片"**:对话里靠已有的工具卡片(`tool_result` 摘要「设置提醒 11-18 08:00 关火」)+ 一行 info 提示(「已设置提醒:…」「提醒没能排进系统闹钟:…」)。理由:现有工具卡片本身就是流内瞬时元素(M5 memory 卡片同理),再叠一张卡片会重复;常驻入口是 设置→提醒。
2. **「稍后 10 分钟」是设备本地的**:`ReminderReceiver` 直接排到 now+10min,不联网。新的 `fire_at` 由**下次前台补排**时的 `syncReminders` 回写(发现本地时间≠服务端时间就 ack),所以列表显示真实时间,服务端最多延迟一次「打开 App」才对齐。
3. **响过就删本地副本**:服务端那行会在下次补排时被 ack 成 `fired`(已过期且本地没有闹钟),不会无限重排。
4. **精确闹钟权限**:清单同时声明 `USE_EXACT_ALARM`(Android 13+,闹钟类自动授予)与 `SCHEDULE_EXACT_ALARM`(`maxSdk=32`);被拒时只提示、不降级成不精确闹钟。
5. **新增文件**:`server/src/time.ts`(Asia/Shanghai 格式化,不依赖容器 TZ)、`server/src/routes/reminders.ts`;`executeClientTool` 增加可选第 4 参 `{emit, conversationId}`(原有三参调用不受影响)。
6. **测试**:server 42/42(新增 `test/reminders.test.ts` 9 条)、app 48/48(新增 `test/reminders_test.dart` 11 条)、`flutter analyze` 零 issue。
