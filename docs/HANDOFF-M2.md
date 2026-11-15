# 鲸灵(JingLing)施工单 · M2 搜索与文件

> 执行者:DeepSeek Harness(dsh)· 前置阅读:`docs/DESIGN.md`(v1.1)、`AGENTS.md`、本文件
> 范围只到 M2(F3 联网搜索 / F4 读链接 / F5 文件输入 / F7 模型安全 / F1 标题升级)。M3 及之后另行出单。
> 起始状态:M0 后端与 M1 客户端已完成并真机验证(见 DESIGN §10)。

## 0. 本单的依据:已用真实 key 抓到的 Chat Completions 形态

下面的字段是 2026-11-14 用真实 `deepseek-flash` 抓包确认的,**不是文档推测**。实现按这个来;若实测与此不符,以实测为准并回填本节。

**请求参数**(Chat Completions):

```json
{
  "model": "deepseek-flash",
  "thinking": { "type": "enabled" },
  "tools": [
    { "type": "deepseek_web_search", "name": "deepseek_web_search" },
    { "type": "deepseek_read_url",   "name": "deepseek_read_url" }
  ],
  "safety_check": { "level": "high" },
  "title": { "enabled": true },
  "messages": [{ "role": "user", "content": "…" }],
  "stream": true
}
```

- 关闭思考 = 普通联网搜索;开启思考 + 声明 `deepseek_web_search` = 深度思考搜索。
- `tool_choice` 不能强制指定这两个工具(400);`none` 会关掉全部工具。
- 声明工具后,以下参数被服务端忽略:`temperature`、`top_p`、`frequency_penalty`、`presence_penalty`、`stop`、`seed`、`n`、`preserve_thinking`、`parallel_tool_calls`。
- 文件输入:先 `POST https://api.deepseek.com/files`(multipart,**`purpose` 字段必须写在 `file` 之前**)上传解析,拿到 `file_id`;对话里用户消息内容用数组引用:
  ```json
  [{"type":"document","source":{"type":"file","file_id":"file-api-xxx"}},{"type":"text","text":"总结这份文档"}]
  ```

**流式 chunk 的新增字段**(实测):

| 位置 | 字段 | 说明 |
|---|---|---|
| `choices[0].delta` | `reasoning_content` | 思考增量(已有,M0 已解析) |
| `choices[0].delta` | `content` | 正文增量(已有) |
| `choices[0].delta` | `annotations` | `[{type:"url_citation", url_citation:{url,title,start_index,end_index}}]`,正文引用角标 |
| `choices[0].delta` | `server_tool_calls` | 见下,一次下发的完整工具调用块(不分片) |
| `choices[0].delta` | `title` | 服务端生成的会话标题(开启 `title` 时) |
| `choices[0]` | `server_tool_event` | `{type:"step_reasoning_done"\|"call_started"\|"call_completed", step}` |
| 末尾 chunk | `usage` | 新增 `prompt_tokens_details.cached_tokens`、`completion_tokens_details.reasoning_tokens`、`completion_tokens_details.safety_tokens`、`prompt_cache_hit_tokens`/`miss_tokens`、`server_tool_use{tool_search,tool_fetch,tool_image_search}` |

`delta.server_tool_calls` 的真实形状:

```json
[{
  "index": 0,
  "reasoning_content": "用户想知道…我需要搜索",
  "calls": [{
    "index": 0,
    "id": "srvtoolu_ds_00_…",
    "type": "deepseek_web_search",        // 或 deepseek_read_url
    "kind": "search | deep_search | read_link | image_search | deep_image_search",
    "action": { "type": "search", "queries": ["…","…"] },   // 或 open_page{url} / find_in_page{url,pattern} / read_link{url}
    "status": "completed",
    "sources": [{ "type":"url", "url":"…", "title":"…", "snippet":"…", "site_name":"…", "site_icon":"…", "published_at":"…" }]
  }]
}]
```

其它实测事实:

- `finish_reason` 在 Chat Completions 下是 `stop`(不是 Messages 的 `end_turn`);拒答/截断的取值需在 spike 中确认。
- 一次深度思考搜索可能产生 400+ chunk、上百 KB;必须在服务端归一化后再下发,不能把原始 chunk 转发给手机。
- 搜索结果/打开网页/思考**不会**进入后续轮次上下文,只保留回答正文;`read_link` 的网页正文加密在 `signature` 里,**只有原样回传该块,网页内容才会拼回后续上下文**。
- 计费:网页搜索按“查询词条数”计次(3 个 queries = 3 次),抓取按成功网页数计次,文件解析按页数计次;`usage.server_tool_use.tool_search/tool_fetch` 是计费次数。
- 联网工具可以单独作为 Search/Fetch/OCR API 调,但**本单不用**,统一走对话接口(服务端工具由 DeepSeek 执行,零维护)。

## 0.1 Spike 结论(2026-11-14 实测,已替代上文“需确认”项)

| # | 问题 | 结论 | 对实现的影响 |
|---|---|---|---|
| 1 | 多轮回传 | ✅ 可用:把上一轮 assistant 按 `{role:"assistant", content:"…", server_tool_calls:[…原样…]}` 放进 messages,追问网页细节能答(实测问“语音接口有哪些”,答出 ASR/TTS) | 落库时把 `server_tool_calls` 块原样存起来(含块内 signature),组装历史时原样回传;不需要切 Messages API |
| 2 | 拒答形态 | ⚠️ CC 下**没有结构化拒答信号**:`finish_reason` 仍是 `stop`,`safety_tokens` 为 0,模型只是在正文里说“我无法提供…”。输入命中审核时服务端会返回 **400 `Content Exists Risk`** | `safety_block` 事件改为映射「输入 400 Content Exists Risk」这一种情况;输出侧拒答不做特殊 UI(就当普通回答展示),DESIGN F7 的“拒答标识”按此收敛并记录 |
| 3 | 文件引用 | ⚠️ Chat Completions **不认 `document` 块**,报 `unknown variant,expected text/image_url/file`;正确形状是 `{"type":"file","file_id":"file-api-…"}`(实测命中文档内暗号) | 用户消息 content 用 `[{type:"file",file_id},{type:"text",text}]`;解析 purpose 仍是 `text_recognition`/`rich_layout_recognition` |
| 4 | 文件错误码 | 伪造 PDF → 400 “file format is not supported”;`purpose` 放在 `file` 之后 → 400 且报错明确指出顺序 | 服务端转发时**先写 purpose 再写 file**,并把上游 400 原样转成客户端可读错误 |

另:上传成功的响应形如 `{id:"file-api-…", object:"file", bytes, created_at, filename, purpose}`,无解析状态字段(解析是同步的,成功才返回 id)。

> **2026-11-15 补充(v1.0.10)**:第 2 条结论不变(上游仍无结构化拒答信号),但已在服务端用启发式识别补上「输出侧拒答」标识(`safety_block.source="output"` + `message.safety_json` 落库),正文照常展示。判据与真实 fixture 见 `DESIGN.md` §10 与 `server/src/agent/safety.ts`。

## 1. Spike 闸门(M2 第一天,先做后写)

四条里任何一条结论不同,先改本文件再动代码:

1. **多轮回传形态(最关键)**:第一轮让模型 `read_link` 读一个 URL,把 assistant 消息(正文 + `server_tool_calls`)按 Chat Completions 的格式原样回传;第二轮追问该网页细节,确认网页内容确实拼回了上下文。
   - 能过 → 按“原样回传 `server_tool_calls`(含 `signature`)”实现。
   - 不能过 → 二选一并在 DESIGN §10 记录:(a) 该能力改用 Messages API(`POST /anthropic/v1/messages`,DESIGN §2 决策 B 已预留协议抽象);(b) 降级为“不回传网页内容”,并在 DESIGN 写明限制。
2. **拒答形态**:构造一条会命中内容审核的请求,确认 Chat Completions 下拒答如何体现(`finish_reason` 取值、是否有 `safety_tokens`、正文是否有拒答标识),据此决定 `safety_block` 事件的触发点。
3. **Files API 与对话引用**:上传一个小 PDF(`purpose=text_recognition`)→ 拿到 `file_id` → 在 Chat Completions 用户消息里引用 → 确认能基于文档作答。
4. **限制与错误**:>100MiB 返回 413、加密 PDF 返回 400、`purpose` 写错位置的行为;把这四条结论写进本文件。

## 2. 服务端步骤

1. **配置**:`config.ts` 增加 `enableWebSearch`/`enableReadUrl`/`safetyLevel('off'|'high')`/`titleEnabled`(env:`ENABLE_WEB_SEARCH`、`ENABLE_READ_URL`、`SAFETY_LEVEL`、`TITLE_ENABLED`,默认全开、safety=high);`.env.example` 同步。
2. **上游调用**:`deepseek/client.ts` 组装 `tools`/`safety_check`/`title`;`events.ts` 增加对 `annotations`、`server_tool_calls`、`server_tool_event`、`title`、扩展 `usage` 的归一化。原始块要**保留**,供回传与落库。
3. **协议扩展(单一来源,同步 `app/lib/models/events.dart`)**:
   - `tool_progress` 扩展为 `{tool, phase: searching|reading|fetching|finding, action_type, queries?, url?, pattern?, step?}`
   - `tool_result` 扩展为 `{tool, call_id, status, results:[{title,url,site_name?,snippet?,published_at?,image_url?}]}`
   - `citation` 扩展为 `{index, url, title, start_index?, end_index?}`
   - `message_start` 增加 `user_message_id`(已有);新增 `event: title {title}`(标题生成)
   - `message_end.usage` 增加 `tokens_cached`、`search_calls`、`fetch_calls`
   - 拒答:`event: safety_block` + `message_end.stop_reason='refusal'`
4. **上下文与回传**:`agent/loop.ts` 组装历史时,assistant 消息带 `server_blocks_json` 的按 spike 结论回传;用户消息带 `file_ids` 的用 document 数组引用;活跃路径语义不变(M0 已定稿)。
5. **文件路由**:`POST /v1/files`(multipart,`multipart/form-data`;单文件上限 100MiB,类型白名单 PDF/DOC/DOCX/PPT/PPTX/PNG/JPEG/WebP/GIF/BMP/TIFF + txt/md/csv/json/xlsx/epub)→ 转发 DeepSeek `/files` → 落 `file` 表(已有:`file_id`、mime、size、parse_status);`GET /v1/files/{id}` 查状态;附件与消息关联。
6. **用量与费用**:`usage_log` 写 `search`/`fetch`/`ocr` 三种 kind(数量 + 费用),价格按 DESIGN §8(搜索 5 元/千次、抓取 5 元/千次、OCR 1.5 元/千页);`/v1/usage` 按 kind 汇总,前端看板可直接用。
7. **标题**:`titleEnabled` 时用 `delta.title` 覆盖 M0 的截断标题(已有值不覆盖;失败时回退截断)。
8. **测试**(`server/test`):伪造上游 SSE 覆盖 `server_tool_calls`/`annotations`/`title`/拒答;断言归一化后的 DPAPP 事件序列符合 DESIGN §5.1;多轮回传的 messages 组装正确;文件上传的 413/400 分支;`/v1/usage` 三类 kind 汇总。

## 3. 客户端步骤

1. **协议同步**:`app/lib/models/events.dart` 与 server 逐字段同步(含新增可选字段);`flutter test` 补协议解析用例。
2. **过程卡片**:助手消息里按 `tool_result` 渲染搜索卡片(标题 + 站点 + 摘要)和读链接卡片;同一 `call_id` 的 `tool_progress` 与 `tool_result` 合并成一张卡片。M1 已有 `_ToolTraceCard`,扩展为可展开。
3. **引用角标**:正文用 `annotations.start_index/end_index` 渲染上标;点击滚动/展开到引用列表(M1 已有引用列表,补角标映射)。
4. **文件**:新增依赖 `file_picker`(选系统文件;**理由**:需要系统文件选择器,无法用现有依赖实现,属轻量 UI 插件,非重型框架);上传走 `/v1/files`,显示文件卡片(名称/大小/解析中/失败可重试),发送时带 `file_ids`。
5. **拒答 UI**:收到 `safety_block` 后把正文换成拒答样式,不显示模型输出。
6. **标题**:收到 `title` 事件后更新 AppBar 与列表(退出再进来也一致,服务端已落库)。
7. **真机要点**:文件选择器需要在 `AndroidManifest.xml` 确认存储权限策略(Android 13+ 用系统相册/文件选择器,通常无需额外权限);`flutter build apk` 验证。

## 4. 端到端验证清单

1. **MOCK 全链路**(`MOCK=1`):伪造搜索/读链接/文件事件流,curl 与 Flutter 客户端都能看到过程卡片、引用、文件卡片。
2. **真实 key 三条硬指标**:
   - 提问“总结 https://api-docs.deepseek.com/zh-cn/news/news261113 讲了什么” → 出现读链接卡片 + 回答带引用;
   - 提问需要联网的问题 → 出现搜索卡片(含查询词与结果条数),回答带角标引用;
   - 上传一份 PDF → 提问“总结这份文档” → 能基于文档作答,文件卡片显示解析成功。
3. **拒答**:构造触发安全审核的输入 → 客户端显示拒答标识,`/v1/usage` 有 `safety_tokens` 记录。
4. **多轮回传**:读链接后追问网页细节能答(spike 结论落地)。
5. **成本核对**:`/v1/usage` 中 search/fetch/ocr 次数与金额非零,且与真实请求次数对得上。
6. **回归**:M0 `npm test` 全绿、M1 `flutter analyze` 0 问题 + `flutter test` 全绿;真机再走一遍配对→对话→分支切换。

## 5. 完成定义(DoD)

- `npm test`(server)与 `flutter analyze` / `flutter test`(app)零报错;
- 验证清单第 2 条三条硬指标真机通过;第 1、3、4、5 条通过;
- `docs/DESIGN.md` §10 追加一行“M2 完成 <日期>”+ 把 §0 的四条 spike 结论回填(替换“需确认”);
- 协议任何改动双侧同步(server `events.ts` ↔ app `events.dart`);
- 密钥纪律不变:`DEEPSEEK_API_KEY` 只在 `server/.env`。

## 6. 本单明确不做

- Search/Fetch/OCR 独立接口直调(用不上,服务端工具已覆盖);
- 知识库/RAG、多文件批量解析、文档预览器;
- 拍照/相册入口(v1.5 G3);
- 图片搜索的图库展示(先只展示站点与标题)。

## 0.2 实现期踩到的坑(施工时已修,后续里程碑别重犯)

1. **Chat Completions 的文件块是 `{type:"file", file_id:"file-api-…"}`**,不是 Messages API 的 `{type:"document", source:{type:"file"}}`——照抄文档会 422 `unknown variant`。
2. **转发文件时不要 `new Uint8Array(buffer)`**:Node 的 Buffer 是共享内存池上的视图,这样构造会取到整个 8KB 池,上传给上游的是垃圾字节,表现为模型回答“文档内容为空”。正确写法 `Uint8Array.from(buffer)`(或按 byteOffset/byteLength 构造)。这个 bug 曾一度被误判成“思考模式与文件不兼容”。
3. 工具结果块(`server_tool_calls`)是**整块下发**的,不要按 chunk 拼接;原样落库、下一轮原样回传,阅读链接的网页内容靠块内 `signature` 才能拼回上下文。
4. 工具费用按**查询词条数**(不是调用次数)与**成功抓取网页数**计,`usage.server_tool_use.tool_search/tool_fetch` 才是计费口径。
