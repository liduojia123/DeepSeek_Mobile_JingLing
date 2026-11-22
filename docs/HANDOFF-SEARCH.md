# 鲸灵施工单 · 会话全局搜索(v2 主线第一项)

> 依据:`docs/DESIGN.md` §3「v2:全局对话搜索」。本单只做**搜索**,不做文件夹、不做 RAG。
> 实现完成后按 `AGENTS.md` 发布纪律出 **v1.5.0+19**。

## 0. 一句话目标

会话列表的搜索框从「本地过滤(标题+预览)」升级为「服务端全量历史搜索(标题+全部消息正文)」,结果分组展示、点击跳到那条消息。

## 1. 现状(实测)

- `app/lib/pages/conversation_grouping.dart` 的 `filterConversations`:只在**已加载**的会话列表里按标题+preview 过滤(M8 明确"只过滤已加载")。搜不到历史消息正文,也搜不到没进 preview 的内容。
- 消息正文在 `message.blocks_json`(`[{type:'text',text}…]`),纯文本提取函数 `blocksToText` 已有(`server/src/routes/conversations.ts`)。
- 消息有分支树,展示内容 = `conversation.active_leaf_id` 回溯的活跃路径(`activePath`,同文件已有)。
- 列表接口的 preview 是每会话查一次消息(已知 N+1,本单**不动**它)。
- `ChatPage` 消息列表是 `ListView(children: items)`,消息 `key: ValueKey(node.id)`,只能滚到底部(`_scrollToBottom`),没有"跳到指定消息"。

## 2. 目标 / 非目标

**目标**

1. 服务端 `GET /v1/search`:按关键词搜**会话标题 + 活跃路径消息正文**,返回分组结果(每组带摘要 snippet)。
2. 会话列表搜索框升级为全局搜索:输入即搜(debounce),结果分组展示;点结果打开对话并**滚动定位到命中的消息**,短暂高亮。
3. 全部走设计令牌(浅/深色),不新增第三方依赖。

**非目标(明确不做)**

- 不搜 thinking(正文为准,思考是噪音);不搜文件解析产物;不做拼音/正则/语义检索(RAG 另议)。
- 不搜临时会话(列表本就不含,且会被清扫)。
- 不搜非活跃分支(搜到也跳不过去;切分支后再搜即可)。
- 不动 preview N+1(个人量级可接受,已在 backlog)。
- 不改 SSE 协议 → `events.ts` / `events.dart` **零改动**。

## 3. 服务端

### 3.1 接口

`GET /v1/search?q=<关键词>&limit=<组数上限>`(Bearer 设备令牌,进现有鉴权作用域)

- `q`:trim 后 1–100 字符;空 → 400 `validation_error`。
- `limit`:会话组数上限,默认 20,1–50。
- 匹配:大小写不敏感子串匹配(中文不受影响)。**全表扫描 + JS 侧匹配**(性能口径与列表 preview 一致,个人量级够用;JSON 特殊字符 `"\` 等天然不受影响,因为不走 SQL LIKE)。将来量大再上 `search_text` 列或 FTS5 trigram。
- 会话命中条件:标题含 q **或**活跃路径任一消息正文含 q;`ephemeral = 0`。

### 3.2 响应

```json
{
  "query": "关键词",
  "groups": [
    {
      "conversation": { "id": "…", "title": "…", "pinned": false, "updated_at": "…" },
      "hits": [
        { "message_id": null, "field": "title", "role": null, "created_at": "…", "snippet": "" },
        { "message_id": "m3", "field": "message", "role": "assistant", "created_at": "…", "snippet": "…前 32 字 [命中] 后 32 字…" }
      ]
    }
  ]
}
```

- `hits`:标题命中(若有)放第一条(`message_id: null`);正文命中按时间**倒序**取前 5 条。正文只有标题命中时 `hits` 仅 title 一条。
- `snippet`:命中处前后各约 32 字的纯文本窗口(总量约 80),多处命中只按**第一处**开窗;空白折叠为单空格。**不含**任何高亮记号——客户端自己按关键词做大小写不敏感高亮(避免转义/记号注入问题)。
- 组排序:组内最新 hit 的 `created_at` 倒序(纯标题命中组用 `updated_at`,自然排在有正文命中的组之后同规则排序,不特判)。

### 3.3 代码落点

- 新文件 `server/src/routes/search.ts`:`registerSearchRoutes(app, { db })`;`blocksToText`/`activePath` 从 `conversations.ts` 提出来共用(导出或挪到小工具文件,避免复制粘贴两份)。
- `server/src/index.ts`:鉴权作用域内注册。
- 测试:`server/test/search.test.ts`(新文件,加进 `package.json` 的 `test` 脚本)。

## 4. 客户端

### 4.1 数据层

- `app/lib/models/models.dart`:`SearchHit` / `SearchGroup`(`fromJson` 与现有模型同风格)。
- `app/lib/core/api.dart`:`Future<List<SearchGroup>> search(String query)`,`_guard` + `_decode` 同现有写法。

### 4.2 会话列表(改造 `conversations_page.dart`)

- 搜索框行为:**输入非空 → 全局搜索态**(debounce 400ms;请求竞态用自增序号丢弃过期响应)。空查询 → 原分组列表。
- 搜索态渲染:加载中(顶部细进度,不清空旧结果)、错误(EmptyState + 重试)、无结果(EmptyState「没有找到…」)、结果(按组出卡片,行=会话标题行 + 命中行)。
- 命中行:`field=title` 显示「标题匹配」;`field=message` 显示 角色徽标 + snippet(关键词高亮,超出部分省略)。点击 → `ChatPage(conversationId, focusMessageId: hit.message_id)`。
- 会话标题行点击 → 直接打开该会话(不带 focus)。
- 删除 `filterConversations` 及其测试(职责被全局搜索取代);`groupConversations`/`conversationTimeLabel`/`plainPreview` 保留。
- 时间戳沿用 `conversationTimeLabel`。

### 4.3 跳转定位(改造 `chat_page.dart`)

- `ChatPage` 新增可选 `focusMessageId`。
- 消息 key 从 `ValueKey(node.id)` 改为 `GlobalObjectKey(node.id)`(同 id 生成等值 key,不影响 diff);首次渲染完成后 `Scrollable.ensureVisible` 定位到该消息(对齐约 0.3),找不到(已删/已切分支)就按原行为停底部。
- 命中消息短暂高亮约 2s 渐隐(浅色 `accentSoft` 系、深色同令牌;尊重系统「移除动画」时直接不闪)。`MessageBubble` 加 `highlighted` 参数或包裹层,别改其内部排版。

### 4.4 高亮组件

- 小组件(建议 `app/lib/widgets/search_snippet.dart`):纯文本 + 关键词,大小写不敏感地把**所有**出现处加粗/换 accent 色;q 为空或未命中则原文输出。纯函数逻辑抽出来便于单测。

## 5. 测试与验收

**测试(全部新增/更新)**

1. server(`search.test.ts`):
   - 标题命中(仅 title hit、`message_id: null`)、正文命中(snippet 窗口、role/created_at 正确)。
   - 大小写不敏感;关键词含 `"`/`%`/`_` 等字符能正常搜(不走 LIKE 的回归保障)。
   - **活跃路径限定**:同一位置编辑/重新生成后,旧分支正文搜不到,新分支能搜到。
   - 临时会话(ephemeral=1)不出现在结果;空 q → 400;limit 生效;每组最多 5 条正文命中。
2. app:高亮纯函数(多处命中、大小写、中文);搜索结果模型解析;ChatPage focus 定位(消息在视野内的基本断言,做不到就退化为"构造不抛错 + 参数透传"级测试,标注原因)。
3. 移除 `filterConversations` 测试。

**验收清单**

1. `cd server && npm test` 全绿;`cd app && flutter analyze` 零 issue;`cd app && flutter test` 全绿。
2. 真机/Chrome:输入三个月前聊过的词 → 出分组结果 → 点击跳到那条消息并高亮;中英文混合、大小写混合可搜;断网/服务端错误显示可重试;深色模式可读。
3. 不回归:会话列表分组/置顶/横幅/新建/行菜单、对话页分支切换/编辑重发/重新生成/语音/朗读、临时对话入口、删除类操作。
4. 发布纪律全套(版本号 1.5.0+19 → 测试 → 构建 → push → `gh release create` → 服务器 OTA 同步)。

## 6. 风险

- **全表扫描性能**:消息量上万后搜索变慢。个人量级(千级)实测无感;升级路径已写在 §3.1。
- **跳转定位失败**:目标消息不在活跃路径(用户搜完又切了分支)→ 静默停底部,不报错。
- **搜索期望管理**:本地过滤时代"输入即筛",升级后每次输入有一次网络往返——debounce 400ms + 序号防竞态;离线时给错误+重试,不静默。

## 7. 交给实现者的判断

- `blocksToText`/`activePath` 的提util放哪(`conversations.ts` 导出 vs 新建 `server/src/messages.ts`)。
- snippet 窗口 ±32 字的具体上下取整;空白折叠规则与 `previewOf` 保持一致即可。
- 高亮的视觉(accent 色加粗 vs 底色),浅深色各一版,别引新依赖。
- 搜索态下搜索框是否常驻顶部(建议常驻,和现在一致)。
