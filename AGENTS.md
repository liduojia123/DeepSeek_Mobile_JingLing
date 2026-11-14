# AGENTS.md — 鲸灵(JingLing)编码 Agent 工作规范

本仓库的编码工作由 AI agent(DeepSeek Harness 等)执行。产品名**鲸灵(JingLing)**,目录代号 DPAPP(保持不变)。开工前按顺序读完:

1. `docs/DESIGN.md`(v1.1)——产品定位、架构、功能范围、决策记录,**一切以它为准**
2. 当前里程碑的施工单(现为 `docs/HANDOFF-M0-M1.md`)

## 项目一句话

鲸灵(JingLing):手机 APK 瘦客户端 + 自有服务器上的 Agent 大脑(DeepSeek 全家桶 API)+ dsh 远程开发桥(插件)。个人自用、专业级标准。

## 技术栈约定(锁定,不擅自更换)

- **server/**:Node.js ≥ 20、TypeScript(strict)、Fastify、better-sqlite3、zod
- **app/**:Flutter、riverpod、http、flutter_secure_storage、flutter_markdown
- 协议单一来源:server `src/deepseek/events.ts`(zod schema)。**任何协议改动必须同步** `app/lib/models/events.dart`,并在两处文件顶部注释中互相指向

## 代码风格

- 与周围代码保持一致;注释密度低而准,只在"为什么"处注释
- 不引入未在施工单列出的重型依赖;确需新增,先在施工单对应里程碑的验证一节说明理由
- 每个里程碑结束:跑完施工单的验证清单,并在 `docs/DESIGN.md` §10 决策记录表追加完成记录

## dsh 插件专项(M3,重要)

`bridge-dsh/` 插件是写给 dsh 运行时自己的插件:

- 遇到文档/设计假设与实际插件 API 不符时,**直接查本机 dsh 安装与 deepseek-ai/deepseek-harness 源码为准**,修通即算数
- 修通后把实际可用的接口(方法名、事件名、确认拦截路径)记录回 `docs/DESIGN.md` §4.4,替换"五项能力假设"
- 插件保持独立模块:只依赖 dsh 公开插件机制与出站 WebSocket,不把 dsh 内部类型泄漏进 server/ 或 app/
- 不使用 headless 自动化模式(风控风险),驱动标准运行时

## 验证纪律

- 每完成施工单一个步骤,立即跑对应验证命令,不攒到最后
- 开发与测试优先 `MOCK=1`;真实 `DEEPSEEK_API_KEY` 由用户提供,写入 `server/.env`(该文件不入库)
- 提交前:`npm test`(server)与 `flutter analyze`(app)零报错

## 安全红线

- `DEEPSEEK_API_KEY` 只允许出现在 `server/.env` 与服务器环境变量,**绝不进入代码、git 历史、客户端代码、日志**
- 设备令牌/桥接令牌数据库中只存 sha256;明文只在创建响应中出现一次
- 任何"确认类"操作(dsh 工具调用批准)默认拒绝:超时未确认不执行
- 不要为了"方便调试"在客户端写死任何密钥、内网地址或豁免认证的逻辑

## 里程碑地图

M0 后端骨架 → M1 客户端核心 → M2 搜索/文件 → M3 dsh 远程开发桥 → M4 语音 → M5 工具/用量 → M6 打包发布。每里程碑单独施工单,完成后向用户确认再进入下一个。
