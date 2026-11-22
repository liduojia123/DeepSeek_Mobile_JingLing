# 鲸灵 · 当前状态交接(2026-11-22)

> 新会话开工请先读:`AGENTS.md` → `docs/DESIGN.md`(权威)→ 本文件 → 相关 `docs/HANDOFF-*.md`
> 本文件只记录「现在在哪、下一步做什么」,设计细节以 DESIGN 为准。

## 一、版本与发布

- App 版本:**1.7.0+26**(versionCode=26)
- GitHub Release:每个版本都有,标签 `v<版本>`(当前 v1.7.0)
- 服务器 OTA:`/opt/jingling/data/app/jingling.apk` + `release.json`(version_code 必须递增)
- 手机端「设置 → 更新来源」可选 **自己的服务器 / GitHub Releases**;「检查更新」按所选来源比对
- 发布纪律见 `AGENTS.md`「发布纪律」:改版本号 → 测试 → 构建 → commit/push → `gh release create` → 同步服务器 OTA

## 二、已完成(全部可运行)

| 模块 | 状态 |
|---|---|
| M0 服务端骨架 | ✅ Fastify + SQLite + 配对/设备令牌 + SSE 协议 |
| M1 客户端核心 | ✅ 会话/流式/思考折叠/Markdown/分支切换/编辑重发/重新生成/置顶重命名删除/临时对话 |
| M2 联网搜索与文件 | ✅ 搜索/深度搜索过程卡片+引用、读链接、PDF/Office/图片解析上传 |
| M3 dsh 远程开发 | ✅ 插件(bridge-dsh/)+ 服务器中继 + 手机电脑页(工作区/会话/历史/派任务/流式/权限/逐条确认) |
| M4 语音 | ✅ ASR/TTS 服务端 + **聊天页内联连续语音**(免按住、VAD 断句、自动播报、可打断) |
| M5 工具与用量 | ✅ memory(存/查/列 + 记忆页)、http_request(白名单)、每日预算熔断、用量看板 |
| M6 打包发布 | ✅ release 签名、应用图标、启动页、每日备份、健康监控 |
| 增值 | ✅ OTA(双来源)、拍照提问、相册多选(≤6)、联网/深度思考开关、Markdown 流式渲染 |
| v1.0.10 收口 | ✅ 代码块语法高亮(14 种语言+复制)、输出侧拒答标识(`safety_block.source=output`,落库)、设备令牌吊销(设置→设备管理) |
| v1.1.0 会话级桥接 | ✅ 手机进电脑上同一个 dsh 会话:同一份历史+实时、跑的时候「插话」、结束「接着说」、手机新建会话、断线按 seq 续传 |
| v1.1.1 检查更新修复 | ✅ 「检查更新」不再静默失败:区分有新版本/已是最新/查询失败,失败弹窗带原因+当前版本+来源;GitHub 侧补超时/限流/无资产原因 |
| v1.2.0 等待期通知(M3.6) | ✅ 派任务/等会话时通知栏常驻「正在等电脑」;跑完/出错/电脑断线在后台发通知;需要确认的操作也提醒;结束即停服务,不做常驻后台 |
| v1.3.0 手机原生提醒(M7) | ✅ 说「20 分钟后提醒我」→ 手机系统精确闹钟,锁屏息屏到点弹通知(稍后 10 分钟/完成);`reminder_cancel`/`reminder_list` 可用;设置→提醒 可查看/取消;重启后靠自启动权限自动重建,否则打开 App 补排 |
| v1.4.0 前端重设计(M8) | ✅ 方向 A「素净」:设计令牌(色/字/距/圆角/动效)+ 内置 Noto Sans SC(界面不再跟系统字体变)+ 会话列表分组(置顶/今天/昨天/本周/更早)+ 本地搜索 + 顶栏 ＋/⋯ + 对话页 ⋯ 菜单 + 输入区「＋」收附件、发送三态 + 统一空状态;测试 65 条 |
| v1.5.0 会话全局搜索 | ✅ v2 主线第一项(`docs/HANDOFF-SEARCH.md`):会话列表搜索框升级为**服务端全量历史搜索**(标题+活跃路径消息正文),结果按会话分组、关键词高亮摘要、点击跳到命中消息并短暂高亮;`GET /v1/search`;测试 server 54 / app 69 |
| v1.5.1 应用图标换新 | ✅ 蓝底白鲸(气泡尾+星光+右下 Change 签名)替换「鲸」字图标;自适应图标底色取样 `#144DEA`,前景构图缩 80% 兜进圆形/圆角方形两种遮罩(严格 66.7% 圆遮罩下签名也完整);`flutter_launcher_icons` 重新生成全部密度 |
| v1.5.2 会话批量管理 | ✅ 长按任意会话进入多选(行首勾选圈、顶栏「已选 N 个」+ 退出),底部操作栏 **全选/重命名(单选时)/置顶/取消置顶/删除**;删除有「N 个会话」确认弹窗;批量操作逐个调既有单条接口(服务端零改动),失败不打断其余并汇总提示;搜索态与多选互斥;测试 74 条 |
| v1.5.3 个人 API Key | ✅ 设置 → 服务器 → **API Key**:录入自己的 DeepSeek key(保存前服务端打 `GET /models` 验真),只存服务端 `app_setting` 表、只回尾号、不进日志;对话/文件/ASR/TTS 全部走 `effectiveApiKey()`(个人 key 优先,清除回落 `.env`);安全红线口径已修订(AGENTS.md);只做 DeepSeek key,第三方模型接入明确不做(见 DESIGN §10);测试 server 60 / app 76 |
| v1.6.0 输入优先首页 | ✅ 导航重排(照用户截图):**打开 App 即见首页**(logo + 「欢迎回来,想从哪里开始?」+ 底部完整输入区),发消息自动建会话进对话页并发出首条消息;「深度思考/智能搜索」药丸开关随身;「＋」= 语音模式(直接进对话开聊)/拍照/相册/文件(附件首页先传随首条带走);**历史会话收进左上角抽屉**(全局搜索/分组/置顶/批量管理/电脑横幅全保留);⋯ 菜单(临时对话/记忆/电脑/用量/设置)留首页顶栏;测试 78 条(新增首页冒烟 2 条) |
| v1.6.1 语音入口挪位 | ✅ 语音入口从「＋」菜单挪到**输入框右侧麦克风**(照用户标注):对话页点按开/关语音模式(激活时变蓝色 mic);首页点按直接进对话开语音;「＋」只剩 拍照/相册/文件 |
| v1.6.2 键盘遮挡修复 | ✅ 修用户截图 bug:首页键盘弹起后输入区被键盘盖住——输入区从 `bottomNavigationBar` 挪进 body(`bottomNavigationBar` 不随键盘上浮),现在键盘弹起输入区/开关自动上浮 |
| v1.7.0 声音回答移除 | ✅ 按用户决定:**删掉 TTS 声音回答,回答只出文字**。移除:自动朗读(设置项+偏好)、「朗读这条回答/朗读此回答」入口、语音模式自动播报与打断按钮、`audioplayers` 播放链路;**语音输入(麦克风/免按住连续语音)保留**,语音模式变为「语音进、文字出」;服务端 `/v1/tts` 保留备用未删 |

## 三、下一步候选(按建议顺序)

1. **v1.2.0 真机验收(2026-11-17 已做 4/6,剩 2 项待补)**:
   - ✅ 派任务 → HOME → 常驻通知「鲸灵 · 正在等电脑」+ 前台服务;结束 → 服务消失 + 结果通知「电脑上的这一轮结束了」
   - ✅ 前台等结束 → 只停服务、**不发**通知
   - ⏳ **锁屏专属**未验:adb 熄屏后小米 3–5s 自动亮屏(App 回到前台,本就不该响);需人工按电源键锁屏后别碰手机再试
   - ⏳ **断线通知**未验:需要断开桥接(关 dsh 会连带杀掉本机正在做验收的 AI 会话),仅单元测试覆盖
2. **手机原生提醒(v1.3.0,已交付)**:真机验收已在小米 24129PN74C 上完成(见 `docs/HANDOFF-M7.md` §7.9);剩余可选:在设备上打开「自启动」后再验一次重启自动重建
3. ~~run_code 沙箱~~ **已砍**(2026-11-17,理由见 DESIGN §10):要"真跑代码"用 dsh 桥
4. **v2 剩余**:个人知识库 RAG、网页端、手机原生工具桥(剪贴板/日历/FCM 推送)
5. **存量小优化(backlog)**:用量/预算按 UTC 分桶(应改 Asia/Shanghai,`usage.ts` 与 `agent/tools.ts` 两处同步)、会话列表 preview N+1、`flutter_markdown` 停维护迁 `flutter_markdown_plus`(先在分支验证)

## 四、关键路径与环境(本机)

- 仓库:`D:\DPAPP`(`server/` `app/` `bridge-dsh/` `docs/` `deploy/`)
- Flutter:`D:\dev\flutter`;JDK:`D:\dev\jdk-17`;Android SDK:`D:\dev\android-sdk`
- 构建:`cd app; flutter build apk --release --target-platform android-arm64`
- 测试:`cd server; npm test`(60 条)/ `cd app; flutter analyze` + `flutter test`(78 条)
- 注意:`server` 的测试入口用 tsx(会 spawn esbuild 服务进程),受限沙箱里会 EPERM,需要正常权限运行
- 发布签名:`app/android/key.properties` + `jingling-release.jks`(均不入库)
- **密钥/服务器凭据在仓库外**:`D:\dev\deploy\`(`keystore-info.txt`、设备令牌、发布脚本);生产 `server/.env` 在服务器 `/opt/jingling/.env`
- 客户端默认服务器地址由用户在配对页填写;服务器固定配对码见服务器 `PAIRING_CODE`

## 五、已知坑(踩过,别再踩)

1. `image_picker_android` 的 lintVital 在 AGP+JDK17 下会崩 → release 关闭 `lintVital`(已配)
2. dsh 插件热重载不清旧实例 → 改插件后重启 dsh,否则旧的确认门仍生效
3. OTA 的 version_code 必须严格递增,否则手机端永远「已是最新」
4. ~~`record` 录音权限 + `audioplayers` 播放中断~~(v1.7.0 起 audioplayers 已整体移除,声音回答不再有,此坑作废):语音打断本来就用按钮,不做回声自动 barge-in
5. ~~语音模式与聊天页自动朗读互斥~~(v1.7.0 起自动朗读与播报都已移除,此坑作废)
6. 图片只发不写字:服务端已放宽「content 或 file_ids 至少一个」
7. 生产部署:`D:\dev\deploy` 打包源码 tar → pscp → `docker compose up -d --build`;发布目录随 `data` 卷挂载
8. 输出侧拒答是**启发式**(上游无结构化信号):只能保证真实样本命中,改写过的客气拒答可能漏判;漏判只是没标识,正文照常显示
9. flutter_markdown 已停止维护(改名为 flutter_markdown_plus),升级前先在分支上验证代码块 builder 与 Material 3 样式
10. 本 App 的 ThemeData 来自 `material_ui`,`MarkdownStyleSheet.fromTheme` 类型不兼容 → 样式表必须手工构造(见 `app/lib/widgets/markdown_view.dart`)
11. **cordis 事件默认按上下文过滤**:插件 ctx 收不到本地用户会话的 `session/event`,必须 `ctx.on(name, cb, {global:true})`;M3 的 agent 事件之所以"看起来能用",是因为那些 agent 是插件自己建的
12. **改插件后必须重启 dsh** 才生效(热重载会残留旧实例);M3.5 之后还要在 dsh 里确认 `~/.dsh/jingling-bridge.json` 指向的服务器已部署新版本
13. 会话流有两个序号:服务器 `seq`(手机续传用)和 dsh `dsh_seq`(去重用),混用会出现重复消息
14. **不要再让「检查更新」返回可空值**:失败与「已是最新」混成 null 会静默失败(v1.1.1 修的就是这个)。新代码用 `UpdateCheck`(available / upToDate / failed),失败必须带原因
15. 用 sealed class 的 `switch` 给 late final 局部变量赋值会触发 Dart VM linearstack 崩溃(`error: unreachable code`,Gradle 报 `compileFlutterBuildRelease` 失败)→ 改成 `if (x is …)` + 可空局部变量
16. Android 前台服务:停服务用 `stopService`(后台 `startService` 会被限制);`onDestroy` 里要 `stopForeground` 清通知;14+ 必须声明并传入 `foregroundServiceType`;没有通知权限就别启动(否则得到"看不见的通知")
17. 国产系统会额外限后台:收不到通知时去「应用信息 → 省电策略」设无限制 + 允许自启动(小米/HyperOS 尤其)
18. **MIUI 默认拦第三方自启动**:重启后 `BOOT_COMPLETED` 根本进不了 App(logcat 里 `BroadcastQueueInjector: Unable to launch app ...`),提醒闹钟不会自动重建。要么在「应用信息 → 自启动」里允许鲸灵,要么靠"打开一次 App 自动补排"(已用 `FLAG_NO_CREATE` 校验真实闹钟是否存在)
19. **清数据/重装会把通知权限重置成拒绝**:`pm clear` 后 POST_NOTIFICATIONS 变 denied,提醒和等待通知都会静默不响 → 设提醒前必须先 `canNotify()`/申请权限,别假设有权限

## 六、验证过的生产事实

- 生产地址与证书:见 `docs/DEPLOY.md`(不在仓库写内网/主机地址)
- 备份:每日 03:30 自动,`/opt/jingling/backups` 保留 7 天;健康检查每 5 分钟
- 真实 API 已验证:搜索/引用、文件解析、ASR/TTS、memory 保存与命中、预算熔断、dsh 桥接(枚举/派任务/审批/权限)
- 2026-11-15 真实 key 复验:输出侧拒答两例均被识别(`safety_block source=output` / `stop_reason=refusal` / `message.safety_json` 落库),正常代码问答未被误标
- 2026-11-15 生产已升级 v1.0.10:服务器重新构建部署(`/v1/devices` 实测返回设备列表)、OTA 清单 `version_code=11` 与 APK 同尺寸(19298557)、GitHub Release 资产已上传
- 2026-11-16 v1.1.0:会话级桥接已完成代码与自动化测试(server 34/34、app 28/28);**已在生产 + 本机真实 dsh 上端到端验证**:真实电脑会话补发 301 条历史、新建会话、followup("收到")、steer("收到插话")、断线按 seq 重放。插件通过 `plugin_manager` 禁用→启用即加载新代码(不必重启整个 dsh)
- 2026-11-16 v1.2.0:等待期通知(app 37/37,含通道契约与后台结束通知的测试);Kotlin 前台服务编译通过、manifest 校验通过
- 2026-11-17 **v1.2.0 真机验收(小米 24129PN74C / HyperOS,已配对生产,app 1.2.0+14)**,用 `adb dumpsys` 取证:
  - 派任务(电脑会话)后 → `ActivityManager` 里有 `WaitService`,通知栏 `id=4101 channel=jingling_wait flags=ONGOING|FOREGROUND_SERVICE`,标题「鲸灵 · 正在等电脑」、正文「<会话名> 正在执行,可以锁屏」;按 HOME 后仍在(说明保活生效)
  - 本轮结束(实测 15–27s)→ `WaitService` 消失、4101 随之消失(**服务随结束自动收掉**),同时后台收到 `id=4102 channel=jingling_result`,`android.title=电脑上的这一轮结束了`、`android.text=新会话 · 已完成`
  - App **在前台**等结束 → 服务停、4101 消失、4102 **从未出现**(不打扰,符合设计)
  - 期间无 `FATAL EXCEPTION` / `ANR in com.jingling`,结束后无残留通知(4101/4102 计数归零)
  - ⏳ 未验两项:**锁屏专属**(adb 熄屏后小米 3–5s 自动亮屏,App 回前台;需人工按电源键且不碰手机)、**电脑断线通知**(要断开桥接,关 dsh 会杀掉本机执行验收的 AI 会话,仅单元测试「电脑断线且正在等 → 通知」覆盖)
  - 文案与施工单不一致:HANDOFF-M3.6 写「电脑上跑完了」,实测结果是「电脑上的这一轮结束了 · 已完成」(以实测为准)
- 2026-11-16 副作用提醒:重载插件时 dsh 会重新 apply 整个 profile,`dsh-pet` 因缺 `@electron/get` 没能重新激活(`fiberPhase=null`,`enabled=true`)。与鲸灵无关,修复方式:在 `C:\Users\liduo\.dsh\profiles\desktop` 里 `npm i @electron/get` 后再次启用 dsh-pet(或忽略,只是桌面宠物)
- 2026-11-22 **v1.5.0 会话全局搜索发布完毕**:GitHub Release v1.5.0(APK 22,181,795 字节,SHA-256 见 `build-release/notes-1.5.0.md`);生产已部署服务端 `/v1/search` 并重建容器(healthy);**公网实测**:搜索真实历史返回 2 个会话组(命中消息+摘要+角色/时间正确)、OTA 清单 `version_code=19` 与 APK 同尺寸、`/v1/app/download` 鉴权正常。部署方式照旧:`D:\dev\deploy` 打包 tar → pscp → `docker compose up -d --build` + 传 `jingling.apk`/`release.json` 到 `/opt/jingling/data/app/`(服务器凭据在仓库外 `生产环境.md`,**不入库**)




