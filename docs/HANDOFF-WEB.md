# 鲸灵施工单 · Web 端(双栏桌面布局)

> 依据:`docs/DESIGN.md` §3「v2:网页端客户端(复用同一后端)」。用户已拍板:**双栏桌面布局**(左会话栏 + 右对话区)。
> 发布为 **v1.8.0+27**(APK 与 Web 同版本号)。

## 0. 一句话目标

浏览器打开 `https://<服务器>/jingling/web/` 即用鲸灵:左边常驻会话栏,右边对话区,配对一次即可,复用全部后端能力。

## 1. 现状(实测)

- `flutter build web` **一次通过、零报错**(2026-11-23 实测,36.5s);M1 起 Chrome 就能跑,代码库跨平台干净。
- API 走绝对地址(设置里的服务器地址),Web 产物与 API **同域同证书**(Caddy `/jingling/*` 反代)→ **无 CORS 问题**,证书信任也一致。
- 浏览器不支持/不该出现的能力:APK OTA 更新、原生提醒闹钟、等待通知、`dart:io`/path_provider 系(语音录音管道用)。
- 长按手势在 Web 偶发不触发(M1 已知)——消息已有 `⋯` 按钮兜底,会话行长按多选在 Web 改为**行内 ⋯ 或点击提示**?(见 §4.3,兜底:多选入口保留长按 + 行尾小按钮)。

## 2. 目标 / 非目标

**目标**
1. 响应式壳:宽屏(≥1000px)双栏——左 `ConversationPane` 会话栏(320px,含搜索/分组/批量管理/电脑横幅),右嵌套 Navigator(首页草稿区 / 对话页,带返回)。窄屏走现有单栏(抽屉)。
2. 部署:服务器托管 `flutter build web` 产物于 `/jingling/web/`(服务端 `/web/*` 静态路由,**在鉴权域之外**),`--base-href /jingling/web/`。
3. 平台适配:Web 隐藏 检查更新/更新来源/等待通知 三个设置项与麦克风(语音输入 v1 不做);其余功能全量可用。
4. 体验糖:Web 端配对页服务器地址**预填**当前来源(从 `Uri.base` 推导 API 前缀)。

**非目标**
- 不做独立前端框架/重写(就用 Flutter Web 产物)。
- Web 语音输入(录音管道依赖 dart:io 路径,后续单独做)。
- 不做 PWA/离线、不做多用户。

## 3. 服务端

- `server/src/routes/web.ts`:`GET /web/*` 静态托管 `config.webDir`(env `WEB_DIR`,默认 `./web`)。
  - MIME 表(html/js/css/json/png/jpg/svg/ico/woff2/woff/ttf/map/wasm);目录/无扩展名 → `index.html`(SPA 回退);带扩展名缺文件 → 404;路径穿越归一化校验。
  - 缓存:`index.html` `no-store`;其余静态(文件名带 hash)`max-age=31536000`。
  - **不进鉴权作用域**(网页壳要先加载才能配对)。
- 注册在 `index.ts` 公开区(`/health` 与 `/v1/pair` 旁边)。
- 测试:目录/SPA 回退/404/穿越/MIME,`npm test` 追加。

## 4. 客户端

### 4.1 响应式壳(`app/lib/pages/shell.dart`)
- `AppShell`:LayoutBuilder,宽屏 ≥1000 → 双栏;否则 `HomePage`(现状)。
- 双栏 = Row[会话栏 | 1px 分隔 | Expanded(嵌套 Navigator:HomePage(wide) ⇄ ChatPage)]。
- 会话栏打开会话/搜索跳转 → 右栏 push `ChatPage(conversationId, focusMessageId)`;返回箭头回到首页草稿区;关闭后刷新会话栏。

### 4.2 ConversationPane 拆分
- `conversation_drawer.dart` 拆出 `ConversationPane`(现抽屉全部内容);`ConversationDrawer` = `Drawer(child: ConversationPane(...))`。
- `onClose` 可空:空则不显示收起按钮(双栏用)。

### 4.3 平台适配
- `kIsWeb` 隐藏:设置里 检查更新/更新来源/等待结果时通知我;首页/对话页输入框麦克风。
- 会话行长按多选在 Web:长按保留,同时**行尾加一个小「多选」图标**(hover/常显均可,实现者定),避免长按不可靠。
- `HomePage` 加 `wide` 参数:双栏时不带 drawer/汉堡。

### 4.4 配对页预填
- Web 下默认服务器地址 = `Uri.base` 推导(`…/jingling/web/` → `…/jingling`),仍可手改。

## 5. 测试与验收

1. `cd server && npm test` 全绿(新增 web 静态托管用例);`flutter analyze` 零 issue;`flutter test` 全绿(新增:宽屏壳渲染双栏/窄屏单栏)。
2. `flutter build web --release --base-href /jingling/web/` 成功。
3. 浏览器实测:打开 `https://<服务器>/jingling/web/` → 配对(地址已预填)→ 双栏出现 → 发消息流式回答、全局搜索跳转、批量删除、分支/编辑重发可用;窄窗口(拖窄/手机浏览器)自动单栏。
4. 不回归:APK 同版本号发布,手机端功能不受影响(kIsWeb 隐藏只影响 Web)。
5. 发布纪律全套 + **服务器部署**(静态路由进镜像需要重建一次)。

## 6. 风险

- `flutter_secure_storage`/`image_picker` 等插件的 Web 实现与移动端行为差异 → 配对态、传图实测兜底。
- 嵌套 Navigator 的弹窗/返回栈语义:弹窗走根 Navigator(现状行为),验收时留意。
- Web 语音 v1 不做,明确留口子(麦克风隐藏),后续用 `record` 的 Web 流式接口另做。

## 7. 交给实现者的判断

- 双栏断点(1000px)、会话栏宽度(320px)、右栏首页是否保留 logo(建议保留)。
- 静态文件缓存头的具体值、MIME 表覆盖范围。
- 会话行「多选」入口的形态(行尾图标 vs 溢出菜单)。
