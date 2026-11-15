# 鲸灵(JingLing)施工单 · M4 语音

> 执行者:DeepSeek Harness(dsh)· 前置:`docs/DESIGN.md` §3 F6、§5.2 /v1/asr /v1/tts
> 状态:主体完成(2026-11-15),真机麦克风验收待做

## 0. 真实接口(已按官方文档核实)

| 能力 | 接口 | 约束 | 计费 |
|---|---|---|---|
| ASR | `POST {base}/v1/tools/asr`(multipart `file`) | 16-bit PCM WAV 或 Ogg Opus;≤8 MiB;≤120 秒;10 分钟上传;返回 `{text, duration_ms}` | 0.39 元/小时(精确到秒) |
| TTS | `POST {base}/v1/tools/tts`(JSON) | `{text, voice_id: stella|tide, format: wav|pcm, filter_markdown}`;≤10,000 计费字符;音频流式返回 | 1.5 元/万字符(**汉字算 2 字符**) |

- TTS 另有 WebSocket 流式接口(`wss://…/v1/tools/tts`),v1 未用(整段合成已够)。
- ASR 无语言参数,自动识别;TTS 也无语言参数。

## 1. 服务端(已完成)

- `server/src/routes/voice.ts`
  - `POST /v1/asr`:multipart → 上游 → `{text, duration_ms}`;**multipart 插件只在 files.ts 注册一次**(重复注册会 `FST_ERR_DEC_ALREADY_PRESENT`)。
  - `POST /v1/tts`:JSON → 上游 → 直接透传 `audio/wav` 流(hijack);失败映射 400/502。
  - 两者都写 `usage_log`:`kind=asr`/`tts`,`quantity` 分别为秒数与计费字符数。
- `config`:新增 `ASR_PRICE_CNY_PER_HOUR=0.39`、`TTS_PRICE_CNY_PER_10K_CHARS=1.5`。
- MOCK 模式:ASR 返回固定文本;TTS 返回 0.3s 静音 WAV(播放链路可测)。
- 测试:`test/smoke.test.ts` 新增 2 条(MOCK ASR 上传、TTS 计费字符=汉字×2),共 23/23 通过。

## 2. 手机端(已完成)

- 依赖:`record`(录音)、`audioplayers`(播放)、`path_provider`(临时文件);AndroidManifest 增加 `RECORD_AUDIO`。
- `app/lib/core/voice.dart`:16kHz 单声道 WAV 录音;播放可 await(播完/被打断都返回),`stop()` 立即静音。
- 聊天页:
  - **按住说话**:长按麦克风开始录音 → 松开上传 ASR → 识别文本填入输入框(可编辑)→ 点发送(符合 DESIGN 的「文字确认」)。
  - **自动朗读**:回答完成后自动 TTS 朗读最后一条回答,默认开;AppBar 图标可关/开(持久化 `jingling.auto_speak`);朗读中显示停止按钮,发送新消息会打断。
  - **朗读此回答**:长按消息菜单新增(助手消息)。
- `api.dart`:`transcribe(wav)`、`synthesize(text)`。

## 3. 验证记录

- 真实 API(本地与生产都跑过):
  - TTS 合成 → ASR 回读:`你好，我是鲸灵。` → 识别 `你好，我是精灵。`(同音字差异,可接受)
  - 用量:asr 3.36s ≈ 0.000364 元;tts 31 字符 ≈ 0.00465 元
- 生产:`/jingling/v1/tts` 返回 200 audio/wav(92KB);`/jingling/v1/asr` 返回文本。
- 真机:APK 已装,聊天页可见 🎤 按钮与自动朗读图标;**麦克风录音 → 识别 → 播放**闭环需人工验收。

## 4. 已知限制 / 后续

- TTS 目前是「整段合成后再播」,首字延迟≈整句合成时间;如需更顺滑,可改 WebSocket 流式合成(文档已确认可用)。
- 录音上限:ASR 单次 ≤120 秒;按住说话超过 120 秒会被上游拒绝,后续可加自动分段。
- 连续语音对话(免按住)属 v2 范围。
- 播放中若 App 切后台,系统可能停掉音频;与手机厂商策略有关。

## 8. 连续语音模式(免按住,2026-11-15)

用户反馈:手机输入法已自带语音转文字,按条 ASR 价值有限 → 升级为「像打电话」的连续语音对话。

- **第二次修订**:用户明确「不要按条语音转文字、不要全屏遮挡回答」→ 语音改为**聊天页内联**:
  - 删除输入框左侧的按住录音/点按录音与识别后回填输入框的逻辑
  - 输入框左侧图标改为**语音模式开关**:点一下开始连续对话,再点退出
  - 语音状态条占据输入框上方一行(显示阶段 + 音量条 + 打断/退出),**对话与回答照常可见**
- 状态机(`lib/core/voice_session.dart`):聆听 → 静音 900ms 自动断句 → ASR → 自动发送 → 等回答 → TTS 播报 → 自动继续聆听
- 录音音量流(`record.onAmplitudeChanged`)做 VAD:阈值 -38 dBFS,20s 无人说话自动重听,60s 强制断句
- 打断:播报中点「打断」按钮 → 立即停播并回到聆听(受手机回声消除限制,未做"被声音自动打断")
- 与聊天页自动朗读互斥:语音模式激活时不再重复播报
- 版本:1.0.4+5,已通过 OTA 发布到生产
