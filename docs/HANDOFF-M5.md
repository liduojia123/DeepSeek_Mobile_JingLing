# 鲸灵(JingLing)施工单 · M5 工具与用量

> 执行者:DeepSeek Harness(dsh)· 前置:`docs/DESIGN.md` §3 F8/F9、§4 工具、§5.2
> 状态:完成(2026-11-15,生产已验证)

## 0. 目标(DoD)

1. `memory` 工具:存 / 查 / 列 个人记忆(SQLite `memory_note`),agent 可主动沉淀用户偏好与事实
2. `http_request` 工具:域名白名单内的 HTTP 调用(默认空名单,配 `HTTP_ALLOWLIST`)
3. **每日预算熔断**:一天累计费用超过 `DAILY_BUDGET_CNY`(默认 5 元)时,拒绝新的对话请求并明确提示
4. **用量看板**:按天、按类型(model/search/fetch/ocr/asr/tts + 工具)、按会话聚合 token 与费用,并显示今日预算剩余
5. 「记住我用 XX,下次直接用」真实生效

## 1. 关键技术点:客户端工具调用循环

DeepSeek 的 `deepseek_web_search`/`deepseek_read_url` 是**服务端工具**(模型调用、服务端执行、整块回传);
`memory`/`http_request` 是**客户端工具**,必须由我们实现标准 function calling 循环:

```
请求带 tools=[{type:'function', function:{name, description, parameters}}]
→ 流式 delta.tool_calls 分片(index/id/name/arguments 增量)
→ 累积成完整调用;finish_reason == 'tool_calls'
→ 本地执行(读写 SQLite / 白名单 HTTP)
→ 追加 assistant(tool_calls) + tool(tool_call_id, content) 消息
→ 再调模型(最多 3 轮),直到给出最终回答
```

要点:
- 流式 tool_calls 按 `index` 聚合,`arguments` 是 **JSON 片段拼接**,必须拼完再 parse。
- 历史回放:assistant 消息要带 `tool_calls`,紧跟 `role:'tool'` 结果消息,否则模型上下文断裂。落库新增 `message.tool_blocks_json`。
- 与思考/搜索/标题同时开启时,function tools 与 `deepseek_web_search` 并存(需实测)。
- 工具执行要计入 `usage_log`(kind 沿用现有集合,工具本身不产生费用,但 `http_request` 的调用次数进 tool 计数),并把工具过程用现有 `tool_progress`/`tool_result` 事件推给手机。

## 2. 工具定义

| 工具 | 参数 | 行为 |
|---|---|---|
| `memory_save` | `{content: string, tags?: string[]}` | 写入 `memory_note(content, tags, created_at, updated_at)`;返回「已记住」 |
| `memory_search` | `{query: string, limit?: number}` | `content LIKE %query%` 或 tags 匹配,按更新时间倒序,返回 JSON 列表 |
| `memory_list` | `{limit?: number}` | 最近记忆列表 |
| `http_request` | `{url, method?: GET/POST, headers?, body?}` | 域名必须在 `HTTP_ALLOWLIST`(逗号分隔,支持子域);超时 10s;响应截断 8KB;只允许 http/https |

安全:白名单为空 = 禁用该工具;`http_request` 不跟随跨域重定向到非白名单域;不回传二进制。

## 3. 预算熔断

- 每次对话开始前:`SELECT SUM(cost) FROM usage_log WHERE ts LIKE '今天%'`。
- `>= DAILY_BUDGET_CNY` → 不调模型,直接 SSE 返回错误事件 `{code:'budget_exceeded', message:'今日预算已用完(¥X/¥Y)'}`,`stop_reason='error'`。
- 预算值来自 config(`DAILY_BUDGET_CNY`,默认 5),设 0 表示不限制。
- 看板展示:今日已用 / 预算 / 剩余。

## 4. 用量看板(手机端)

- 入口:设置页 「用量看板」。
- 内容:今日费用与 token、今日预算进度条、近 7 天每日费用柱状(简单自绘)、按类型拆分(model/search/fetch/ocr/asr/tts)、按会话 Top 5。
- 数据:`GET /v1/usage?days=7` 扩展返回 `{today:{cost,tokens_in,tokens_out,budget_used_percent}, daily:[{date,cost,tokens}], by_kind:[...], top_conversations:[...]}`。

## 5. 验证清单

1. 说「记住:我用 DeepSeek Harness 开发鲸灵」→ 模型调用 `memory_save` → `memory_note` 有记录
2. 新会话问「我用什么开发鲸灵?」→ 模型 `memory_search` 命中并回答正确
3. `http_request` 白名单外域名 → 工具返回明确拒绝信息(不发起请求)
4. 白名单内 URL → 返回内容
5. `DAILY_BUDGET_CNY` 设很小值 → 次日请求被熔断,手机端看到明确提示
6. 看板数字与 `usage_log` 一致

## 6. 明确不做

- 记忆管理 UI(v1.5)
- `run_code` 沙箱(v1.5)
- 多轮工具并行调用(串行执行即可)

## 7. 完成记录(实测)

- 服务端:标准 function calling 循环(memory_save / memory_search / memory_list / http_request),流式分片按 index 聚合,`finish → 本地执行 → 再请求`,最多 3 轮
- 生产实测:说「记住:我是鲸灵项目的开发者…」→ `memory_save` 执行并落库;新会话问「我平时用什么工具开发鲸灵」→ `memory_search` 命中并正确回答
- 预算熔断:`DAILY_BUDGET_CNY`(生产 20 元),生成前检查,超出返回 402 `budget_exceeded`;看板显示今日已用/预算/剩余/进度
- 看板:`GET /v1/usage` 扩展 today/tool_calls/top_conversations/budget;手机端新增「用量看板」页(今日卡片+预算条+近 7 天柱状+按类型+Top 会话)
- 测试:服务端 26/26(新增 memory 落库/查询、预算熔断、http_request 白名单)
- 坑:① 客户端工具与 `deepseek_web_search` 可以并存(实测);② 流式 `tool_calls.arguments` 是 JSON 片段,必须拼完再 parse;③ 历史回放需要 `assistant(tool_calls)` + `tool` 消息成对,已落 `message.tool_blocks_json`