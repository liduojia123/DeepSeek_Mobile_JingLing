# 鲸灵 · 当前状态交接(2026-11-15)

> 新会话开工请先读:`AGENTS.md` → `docs/DESIGN.md`(权威)→ 本文件 → 相关 `docs/HANDOFF-*.md`
> 本文件只记录「现在在哪、下一步做什么」,设计细节以 DESIGN 为准。

## 一、版本与发布

- App 版本:**1.0.9+10**(versionCode=10);构建产物 18.4 MB(release + R8)
- GitHub Release:每个版本都有,标签 `v<版本>`(当前 v1.0.9)
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

## 三、下一步候选(按建议顺序)

1. **收口 v1 小洞**:代码语法高亮(flutter_markdown 单色)、输出侧拒答结构化标识、设备令牌吊销接口
2. **run_code 沙箱**(v1.5):Docker 隔离执行,agent 能跑代码验证
3. **手机原生提醒**:日历/闹钟/通知推送(让「提醒我」真正可用)
4. **个人知识库 RAG**、网页端、会话全局搜索(v2)
5. **M3 真机验收遗留**:电脑页「越界写文件 → 手机批准 → 真实写入」完整点验

## 四、关键路径与环境(本机)

- 仓库:`D:\DPAPP`(`server/` `app/` `bridge-dsh/` `docs/` `deploy/`)
- Flutter:`D:\dev\flutter`;JDK:`D:\dev\jdk-17`;Android SDK:`D:\dev\android-sdk`
- 构建:`cd app; flutter build apk --release --target-platform android-arm64`
- 测试:`cd server; npm test`(27 条)/ `cd app; flutter analyze` + `flutter test`(11 条)
- 发布签名:`app/android/key.properties` + `jingling-release.jks`(均不入库)
- **密钥/服务器凭据在仓库外**:`D:\dev\deploy\`(`keystore-info.txt`、设备令牌、发布脚本);生产 `server/.env` 在服务器 `/opt/jingling/.env`
- 客户端默认服务器地址由用户在配对页填写;服务器固定配对码见服务器 `PAIRING_CODE`

## 五、已知坑(踩过,别再踩)

1. `image_picker_android` 的 lintVital 在 AGP+JDK17 下会崩 → release 关闭 `lintVital`(已配)
2. dsh 插件热重载不清旧实例 → 改插件后重启 dsh,否则旧的确认门仍生效
3. OTA 的 version_code 必须严格递增,否则手机端永远「已是最新」
4. `record` 录音权限 + `audioplayers` 播放中断:语音打断用按钮,不做回声自动 barge-in
5. 语音模式与聊天页自动朗读互斥(语音模式激活时不再重复播报)
6. 图片只发不写字:服务端已放宽「content 或 file_ids 至少一个」
7. 生产部署:`D:\dev\deploy` 打包源码 tar → pscp → `docker compose up -d --build`;发布目录随 `data` 卷挂载

## 六、验证过的生产事实

- 生产地址与证书:见 `docs/DEPLOY.md`(不在仓库写内网/主机地址)
- 备份:每日 03:30 自动,`/opt/jingling/backups` 保留 7 天;健康检查每 5 分钟
- 真实 API 已验证:搜索/引用、文件解析、ASR/TTS、memory 保存与命中、预算熔断、dsh 桥接(枚举/派任务/审批/权限)
