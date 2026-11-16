# 鲸灵施工单 · M3.6 等待期通知(前台服务 + 系统通知)

> 前置:`docs/DESIGN.md` §4.4 / §10、`docs/HANDOFF-M3.5.md`、`AGENTS.md`
> 目标:离开电脑时,任务跑完 / 出错 / 电脑断线,**手机能主动响一声**,不用一直开着 App 盯着。

## 0. 需求与范围(用户 2026-11-16 拍板:选 B)

- **只在"你正在等"的时候开前台服务**:手机把输入送进 dsh 会话、且该会话在跑 → 起一个带常驻通知的前台服务;这一轮结束(或你离开会话页)→ 服务立刻停。
- 前台服务的作用只有两个:**让进程活着**(Dart 侧的 SSE 继续收事件)+ **常驻通知告诉你"还在等"**。
- 这一轮结束时,如果 App 不在前台 → 发一条**普通通知**(有声音/震动):跑完了 / 出错 / 电脑断线。
- 明确不做:常驻后台(不等待时不开服务)、FCM、远程推送、服务端轮询。

## 1. 技术选择

对比过三条路:

| 方案 | 取舍 |
|---|---|
| `flutter_foreground_task` + `flutter_local_notifications` | 现成,但要引两个插件、双引擎/隔离区状态同步复杂,通知样式也被插件框住 |
| 纯原生 Kotlin(选定) | 只加一个 Service + 两个通知渠道;不增加 Flutter 依赖;通道沿用 M6 OTA 已有的 `jingling/installer` 模式 |
| 服务端推送(FCM) | 国内网络不可靠、要 Google 服务与密钥,个人自用不划算 |

**为什么"进程活着"就够了**:M3.5 的会话流是 App 里的 Dart `Stream`(HTTP SSE)。Android 上只要进程在前台服务里活着,Dart 引擎就继续跑,SSE 事件照收;所以结果判定留在 Dart,原生只负责"保活 + 发通知"。

## 2. 原生侧(Kotlin)

新文件 `android/app/src/main/kotlin/com/jingling/jingling/WaitService.kt`:

- `onStartCommand`:`ACTION_START`(带 title/text)/ `ACTION_UPDATE` / `ACTION_STOP`;`startForeground(id, notification, FOREGROUND_SERVICE_TYPE_DATA_SYNC)`(API 29+ 带类型,14+ 必填)。
- 常驻通知:渠道 `jingling_wait`(IMPORTANCE_LOW,静音),标题「鲸灵 · 正在等电脑」,正文 = 会话名;带「结束等待」动作(直接停服务),点击打开 App。
- 结果通知:渠道 `jingling_result`(IMPORTANCE_DEFAULT,有声音),点击打开 App;由 `MainActivity` 的通道方法 `notifyResult(title, text)` 发出(不需要服务存活)。

`MainActivity` 增加通道 `jingling/wait`:`start` / `update` / `stop` / `notifyResult` / `requestPermission` / `canNotify`。

`AndroidManifest.xml` 补:
- `FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_DATA_SYNC`、`POST_NOTIFICATIONS`
- `<service android:name=".WaitService" android:foregroundServiceType="dataSync" android:exported="false" />`

## 3. Dart 侧

- `app/lib/core/wait_alert.dart`:`WaitAlert.start/update/stop/notifyResult/requestPermission`,全部吞掉 `MissingPluginException`(测试/Web 无通道)。
- `app/lib/core/app_visibility.dart`:`AppVisibility.foreground`(由 `main.dart` 的 `WidgetsBindingObserver` 维护),通知只在"不在前台"时发。
- `harness_session_provider.dart`:
  - 会话在跑 → `WaitAlert.start`(幂等);本轮结束(`turn_end`)或离开页面 → `WaitAlert.stop`;
  - 本轮结束且 App 不在前台 → `WaitAlert.notifyResult`(完成 / 出错);
  - 节点断线(`live kind=error`)且正在等 → 同样通知"电脑断线了";
  - 打开会话时若 `ready.status=running` → 也进入等待态。
- 通知权限:首次 `start` 前请求 `POST_NOTIFICATIONS`(Android 13+);被拒就只保活、不发通知,不打扰。

## 4. 验证清单

1. `cd app && flutter analyze` 0 issue、`flutter test` 全绿(新增 `WaitAlert` 通道调用的假通道测试 + `turn_end` 原因记录测试);
2. `flutter build apk --release` 通过(Kotlin 编译 + manifest 校验);
3. 真机:手机派一个要跑一会儿的任务 → 按 Home 键 → 通知栏有「正在等电脑」;任务结束 → 收到「电脑上跑完了」;
4. 真机:等待期间在电脑上断网/关 dsh → 收到「电脑断线了」;
5. 真机:回到 App 里等任务结束 → **不发**系统通知(避免自己看的时候还响);
6. 等待结束后前台服务消失(通知栏「正在等电脑」自动消失)。

## 5. 明确不做

- 不等待时也常驻后台(FCM/轮询都不做);
- 通知里带任务正文(只带会话名与结果,避免敏感内容进通知栏);
- 任务级确认卡片(确认仍走 M3 的任务视图,本次只做会话等待)。
