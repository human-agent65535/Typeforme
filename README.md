# Typeforme

Typeforme 是一套以 Mac 为算力中心的本地语音输入系统：在本机完成语音识别、文本整理和选区改写，再通过同一套 Bridge HTTP API 把这些能力开放给本机 Mac、其它 Mac Client 和 iOS 键盘扩展。整条链路默认离线，模型跑在 Apple Silicon 上；也可以把整理工作转发给同局域网或公网上一台更强的 Mac / GPU。

首次启动进入 Client mode。切换到 Server mode 后，可以启用 Bridge、本地语音识别和文本整理。

## 亮点

- **全本地、可审计**：WhisperKit + 本地 Qwen3.5 时音频和文本完全不出本机；零分析 SDK、零设备指纹；网络出口只有 HuggingFace 模型下载、用户自配的 Mac Bridge、可选 LM Studio endpoint 三种，全部是用户主动行为。Apache-2.0 开源。
- **不止听写，还能改写**：选中错误片段录一段语音直接修复（`repair_selection`），或者用一句话指令让模型重写选区 / 输入框（`command`），改写带 10 分钟撤销窗口。
- **iOS 键盘内置完整拼音纠错栈（核心支持英文 + 简体中文）**：六套 Rime schema、Gutter Rime probe、按键 2D Gaussian 触点学习、Backspace 反向纠错信号 —— 多层叠在一起，开源 iOS 键盘里相当罕见。详见下文「拼音落键纠错」。
- **两端共用一条 Bridge**：iOS 键盘扩展和其它 Mac Client 都通过同一套 8 个 REST + SSE 端点连接 Mac Server，token 鉴权，LAN-first 并发探测，叠加 Public Bridge URL 走 VPN / 隧道 / 反向代理。
- **多触发 + 实时预览**：全局快捷键、双击修饰键按住说话；HUD 同时展示 Apple Speech 端上实时预览，本机 ASR 出结果时无缝替换；同一段预览作为 `alternate_transcript` 喂给整理模型辅助纠错。
- **Voice Draft（beta）**：识别结果直接作为选中草稿落入焦点输入框，Style / Wand 一次替换或重写，避免切换焦点。
- **五种整理模式 + 可改 prompt + 词典联动**：Clean / Polish / Polish+ / Structure+ / Formal+；自定义 `system.md` 与 `mode-*.md` 覆盖内置 prompt；用户词典同时进入 corrector 上下文和 iOS Rime 候选词。

## 功能

- 语音识别：WhisperKit 或 Qwen3-ASR GGUF（含 mmproj），按 provider 自动转 16k mono WAV。
- 文本整理：本地 Qwen3.5 2B / 4B / 9B GGUF，或 LM Studio / OpenAI-compatible endpoint。
- 输出模式：Clean、Polish、Polish+、Structure+、Formal+ 五档；可定义自定义 prompt 覆盖内置版本。
- 触发方式：全局快捷键（默认 `⌘⇧Space`）、双击修饰键按住说话（右 ⌥/⌘/⇧/⌃、左 ⌥、Fn 可选）。
- 文本提交：默认通过 Accessibility 合成 Unicode 文本输入；剪贴板只作为手动 fallback。
- 选区编辑：两种 intent — `repairSelection` 听写修复选区，`command` 按语音指令改写选区或当前输入框；改写带 10 分钟撤销窗口。
- Voice Draft（beta）：识别文本以选中草稿形态落入焦点输入框，Style / Wand 可 in-place 替换或继续改写，Esc 取消。
- Live preview：开启后录音过程中由 Apple Speech 提供端上实时部分转录，HUD 实时显示；同一段预览作为 `alternate_transcript` 传给整理模型辅助纠错。
- 用户词典：本机 JSON 形式存储；同时进入 corrector prompt、`/v1/edit-text` 上下文，以及 iOS Rime 用户词典。
- iOS 键盘：核心支持英文和简体中文；提供 Tap-to-speak / Hold-to-speak、选区修复、Wand 指令改写、模式切换；中文走 Rime 拼音并自带多层落键纠错（见下文）。
- Bridge HTTP API：
  - `GET  /v1/health`
  - `GET  /v1/pairing`
  - `GET  /v1/settings`
  - `POST /v1/settings`
  - `POST /v1/dictate`
  - `POST /v1/restyle`
  - `POST /v1/edit-text`
  - `GET  /v1/jobs/:jobID/events`（Server-Sent Events）
- Pairing JSON：`token`、启用的 LAN URL 候选和启用的 Public Bridge URL；语言、默认模式和模型状态由 iOS 通过 `/v1/settings` 拉取。

## 音频处理

- Mac 和 iOS 都录制临时 M4A / AAC 音频文件。
- iOS 和 Mac Client 把临时音频上传到 Mac Bridge；Mac Server 本机录音直接进入本机语音识别和文本整理流程。
- Bridge 使用 `multipart/form-data` 接收音频文件。
- Server 侧进入 ASR 前按 provider 需要转成 16k mono WAV。
- Debug mode 开启时，音频和处理结果会复制到 `DebugCaptures/`；正常处理流程使用临时文件，并在处理结束后清理。

## 拼音落键纠错

iOS 键盘核心支持英文和简体中文；中文走 Rime 拼音。落键到候选这一段叠了几层纠错，开源 iOS 键盘里相当罕见：

1. **Rime schema 自带的拼音纠错**：六套 schema（标准 / 扩展 / 大词库 × 纠错开关），覆盖常见拼音错音；在 Pinyin Correction 开关里整体启停（`iOS/TypeformeKeyboard/RimeInputController.swift:49-68`）。
2. **Gutter Rime probe（语言学触点歧义解决）**：两键交界 6pt 以内的触点会启动一个独立的 Rime probe session，把候选字母分别 feed 进去看哪个能延续当前音节，再决定走哪个键；probe 区分 `.extend` / `.split` / `.unknown` 三种结果（`iOS/TypeformeKeyboard/KeyboardViewController.swift:1143-1223`，`iOS/TypeformeKeyboard/RimeInputController.swift:631-694`）。
3. **按键 2D Gaussian 触点学习**：每个按键维护一份高斯偏移分布（σx≈0.34、σy≈0.70），实时学习用户偏左 / 偏右 / 偏上 / 偏下的击键习惯。Probe 给不出明确答案时由 Gaussian 决定（`iOS/TypeformeKeyboard/KeyboardViewController.swift:8594-8836`）。
4. **Backspace 反向纠错信号**：~500ms 内若用户连按 backspace + 邻近键，原始触点被打 3× 权重的 correction sample 反向训练 Gaussian —— 把"我刚才打错了"的用户意图直接闭环回触点模型（`iOS/TypeformeKeyboard/KeyboardViewController.swift:1264-1366`）。
5. **Drag rescue**：从首键拖出 14pt 后落到另一个文本键时提交目标键而不是首键，允许中途纠错（`iOS/TypeformeKeyboard/KeyboardViewController.swift:802-823`）。
6. **用户词典自动生成拼音编码**：Mac 上的自定义词条同步到 iOS 后，按 `CFStringTransform(kCFStringTransformMandarinLatin)` 转写为全拼 + 首字母两种码，权重 100k / 90k 双档写入 Rime `typeforme_custom_phrase.txt`（`iOS/TypeformeKeyboard/RimeInputController.swift:747-836`）。
7. **iOS 键盘扩展 hit-test 兼容**：键间空隙用 0.01-alpha 覆盖层接管命中测试，避免触点漏到 host app；文本键由 overlay 走坐标路由，不走 UIButton hit-test（`iOS/TypeformeKeyboard/KeyboardViewController.swift:391-394`）。

最有特点的是 #2 与 #4：Gutter probe 把语言学正确性嵌进了硬件触点的歧义解决 —— 不是 Rime 输入后再纠错，而是在还没确认输入哪个字母之前就用 IME 上下文做选择；Backspace 信号把用户的纠错动作闭环回触点模型，多用几天键盘越准。

## 系统要求

- macOS 14+，Apple Silicon。
- Xcode，用于构建 macOS app、iOS app 和 KeyboardShortcuts 资源。
- 麦克风权限。
- Accessibility 权限，用于提交整理后的文本。
- iOS 17+；键盘扩展需要开启 Full Access。
- 模型尺寸参考：Qwen3.5 2B 适合 16GB 机器，Qwen3.5 4B / 9B 与 Qwen3-ASR 1.7B BF16 建议使用 32GB 以上内存。Qwen3-ASR 与本地 Qwen3.5 需要内置 `llama-server`；WhisperKit 与 LM Studio endpoint 不依赖内置 `llama-server`。

## 快速开始

使用 Qwen3-ASR GGUF 或本地 Qwen3.5 前，准备本地 llama.cpp 运行时。WhisperKit 与 LM Studio endpoint 不依赖内置 `llama-server`。

```sh
scripts/vendor-llama.sh <path-to-llama.cpp/build/bin>
```

构建 macOS app：

```sh
scripts/build-app.sh debug
scripts/build-app.sh debug --install
scripts/build-app.sh release
IDENTITY="Developer ID Application: ..." scripts/build-app.sh release
```

运行 macOS 测试：

```sh
scripts/run-tests.sh
```

构建并安装 iOS app 和键盘扩展到已配对 iPhone：

```sh
scripts/build-rime-ios-data.sh
scripts/deploy-ios.sh
```

也可以在 Xcode 中打开 `iOS/TypeformeIOS.xcodeproj` 构建。键盘扩展的真机验证建议使用 Release 构建。

## 配对 iOS

1. 在 Mac app 切到 Server 模式并打开 Bridge。
2. 需要局域网访问时打开 LAN access，并选择 `All adapters` 或具体 LAN adapter。
3. 需要公网、隧道、VPN 或反向代理访问时打开 Public Bridge URL，填入客户端实际访问的 URL。
4. 复制 Pairing JSON 到 iOS host app 并保存。
5. iOS 在 Wi-Fi 下并发探测 LAN URL（1.5s 超时），首个可达即返回；LAN 不可达时回落到 Public Bridge URL（3.0s 超时）。网络变化后重新探测。

## 运行时文件

`scripts/vendor-llama.sh` 将 `llama-server-arm64` 及相关动态库复制到 `vendor/`。`scripts/build-app.sh` 将这些文件打包到 `dist/Typeforme.app`，并在可用时签名内置 `llama-server`。

缺少 `vendor/llama-server-arm64` 时，相关本地 GGUF 功能会报告不可用。

设置存放在 `UserDefaults` 域 `com.example.typeforme.mac`。运行数据默认在：

```text
~/Library/Application Support/Typeforme/
```

主要子目录：

- `Models/`：Qwen3.5 correction 模型。
- `Models/WhisperKit/`：WhisperKit cache。
- `Models/Qwen3ASR/`：Qwen3-ASR GGUF 和 mmproj。
- `prompts/`：`system.md` 和 `mode-*.md` prompt override。
- `Bridge/`：临时上传音频。
- `ASRWork/`：ASR 前的临时转码音频。
- `DebugCaptures/`：debug mode 下保留的最近记录。
- `Logs/`：本地服务日志。

模型自动安装走 `ModelAutoInstaller`：断点续传 + SHA256 校验，4 小时超时上限。

## 项目结构

```text
Sources/Typeforme/
  App/             macOS app lifecycle 和 DictationCoordinator
  ASR/             WhisperKit、Qwen3-ASR、音频转码
  Audio/           macOS M4A 录音
  Bridge/          本地 HTTP Bridge 和远端 Bridge client
  Hotkey/          快捷键和双击修饰键监听
  LLM/             文本整理后端、llama-server 管理、输出校验
  Memory/          AppSettings、AppPaths、模型下载、用户词典
  Models/          领域模型和 enum
  Prompts/         内置 prompt、prompt builder、override store
  TextCommit/      文本输入提交和剪贴板 fallback
  UI/              Settings、HUD、菜单栏 UI
  Diagnostics/     Debug capture

iOS/
  TypeformeIOS.xcodeproj
  TypeformeIOS/       iOS host app
  TypeformeKeyboard/  自定义键盘扩展（含 Rime 拼音输入）
  Shared/             host app 和键盘扩展共用模型

Tests/TypeformeTests/
Resources/
scripts/
vendor/
dist/
AGENTS.md          coding agent 项目规则
```

## 验证

基础验证：

```sh
scripts/run-tests.sh
```

iOS 或共享 Bridge 改动需要执行 iOS simulator build：

```sh
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project iOS/TypeformeIOS.xcodeproj \
  -scheme TypeformeIOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios-derived \
  build
```

Benchmark 脚本改动需要通过 Swift typecheck：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swift -frontend -typecheck \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
  scripts/benchmark-correctors.swift
```

Bridge 和 iOS 键盘行为需要真机链路验证。

## Benchmark

Benchmark 环境：本机 Apple M4 Max 16-core / 64GB，远端 LM Studio 测试机为 RTX 5090。数据记录 warm path；首次下载、首次 Metal 编译和进程冷启动不计入。

ASR benchmark 使用 Bridge `/v1/dictate` 执行标准应用流程，音频样本来自本机 `DebugCaptures/*/audio.m4a`。表内 ASR latency 来自 Bridge response 的 `transcription_latency_ms`；`Median wall` 为脚本端到端耗时。运行期间，脚本将文本整理后端临时设置为 `qwen35_2b`，并将 `correction_timeout_ms` 设置为 `100`，结束后恢复原设置。

| ASR 模型 | Median ASR | P95 ASR | Median wall | Median RTF |
|---|---:|---:|---:|---:|
| WhisperKit large-v3_947MB (Whisper v3 full) | 4044 ms | 6976 ms | 4773 ms | 0.323 |
| Qwen3-ASR 1.7B BF16 | 738 ms | 1134 ms | 2139 ms | 0.062 |

ASR 表记录性能指标。

文本整理 benchmark 需要连接正在运行的 Typeforme Bridge。`scripts/benchmark-correctors.swift` 通过 `/v1/settings` 切换后端，并通过 `/v1/restyle`、`/v1/edit-text` 覆盖 app 内部的 settings、PromptBuilder、CorrectorFactory、validator、post-processor 和 Bridge response path。

| 文本整理后端 | Hardware | OK/Total | Median wall | P95 wall | Median app | P95 app |
|---|---|---:|---:|---:|---:|---:|
| Qwen3.5 2B Q4_K_M | Apple M4 Max 16-core / 64GB | 55/65 | 290 ms | 853 ms | 288 ms | 851 ms |
| Qwen3.5 4B Q4_K_M | Apple M4 Max 16-core / 64GB | 59/65 | 650 ms | 2121 ms | 648 ms | 2119 ms |
| Qwen3.5 9B Q4_K_M | Apple M4 Max 16-core / 64GB | 59/65 | 1084 ms | 3668 ms | 1082 ms | 3665 ms |
| LM Studio local qwen3.6-35b-a3b | Apple M4 Max 16-core / 64GB | 61/65 | 799 ms | 2480 ms | 797 ms | 2477 ms |
| LM Studio remote qwen3.6-27b-nvfp4 | RTX 5090 | 63/65 | 646 ms | 1403 ms | 644 ms | 1401 ms |

```sh
TYPEFORME_BRIDGE_URL="http://127.0.0.1:18081" \
TYPEFORME_BRIDGE_TOKEN="<bridge-token>" \
TYPEFORME_BENCHMARK_BACKENDS="qwen35_2b,qwen35_4b,qwen35_9b,lmstudio_local,lmstudio_remote" \
TYPEFORME_BENCHMARK_RUN_LABEL="mac-m4max-local-vs-5090-lmstudio" \
TYPEFORME_BENCHMARK_LOCAL_HARDWARE="Apple M4 Max 16-core / 64GB" \
TYPEFORME_BENCHMARK_LOCAL_LMSTUDIO_URL="http://127.0.0.1:1234/v1" \
TYPEFORME_BENCHMARK_LOCAL_LMSTUDIO_MODEL="qwen3.6-35b-a3b" \
TYPEFORME_BENCHMARK_REMOTE_HARDWARE="RTX 5090" \
TYPEFORME_BENCHMARK_REMOTE_LMSTUDIO_URL="http://<remote-lmstudio-host>:1234/v1" \
TYPEFORME_BENCHMARK_REMOTE_LMSTUDIO_MODEL="<remote-model-id>" \
TYPEFORME_BENCHMARK_TIMEOUT_MS=30000 \
TYPEFORME_BENCHMARK_HTTP_TIMEOUT_MS=60000 \
swift scripts/benchmark-correctors.swift
```

`TYPEFORME_BENCHMARK_TIMEOUT_MS`、`TYPEFORME_BENCHMARK_LOCAL_LMSTUDIO_*`、`TYPEFORME_BENCHMARK_REMOTE_LMSTUDIO_*` 会临时更新 Bridge server 的 correction timeout 和 LM Studio URL/model，脚本结束后通过 `/v1/settings` 恢复原设置。脚本输出 latency summary 和 per-sample JSONL。

## 隐私

代码层面可证明的本地优先：

- **全管道纯本地可跑通**：WhisperKit + 本地 Qwen3.5 时，`DictationCoordinator` 走 `asr.transcribe` → `corrector.correct` 全程进程内，音频和文本不出本机（`Sources/Typeforme/App/DictationCoordinator.swift:324-334`）。
- **零第三方分析 / Crash 上报 / Telemetry SDK**：仓库中没有 Mixpanel / Amplitude / Segment / PostHog / Sentry / Crashlytics / Firebase 任何引用。
- **零 IDFA / `identifierForVendor` / 设备指纹追踪**。
- **网络出口仅三类，全部为用户主动行为**：
  1. 模型下载（HuggingFace，断点续传 + SHA256 校验，仅在首次安装时触发）
  2. 用户自己配置的 Mac Bridge URL（Mac Client / iOS 键盘 → Mac Server）
  3. 可选的 LM Studio / OpenAI-compatible endpoint（默认关闭）
- **日志默认屏蔽正文**：正常日志通过 OSLog `privacy:` 注解处理用户文本；只有打开 Debug mode 才会把原始音频和文本写到 `DebugCaptures/`，且仅写到本机用户目录。
- **凭据本地化**：iOS 配对 token 存 Keychain；Mac 端 token、prompt、词典、模型都在本机用户目录下，不走 iCloud / cross-device 同步。
- **iOS 键盘 Full Access 范围**：键盘扩展自身只通过 `KeyboardLocalClient` 连接 `ws://127.0.0.1:18082/keyboard`（硬编码 localhost），与 iOS host app 之间走本地 WebSocket + App Group；对 Mac Bridge 的请求由 host app 发出，目标是用户自己配置的 URL（`iOS/TypeformeKeyboard/KeyboardLocalClient.swift:4`）。
- **代码 Apache-2.0 全部开源可审计**；第三方依赖（SwiftNIO、Hummingbird、WhisperKit、librime、llama.cpp）均为宽松许可。

## 授权

Typeforme 自有代码以 Apache License 2.0 授权，详见 `LICENSE`。

第三方依赖、可选本地运行时、模型文件和用户提供的资产适用各自的上游授权。当前第三方授权摘要见 `THIRD_PARTY_NOTICES.md`。

Rime 集成基于 `librime`（BSD-3-Clause）和 Typeforme 自有 wrapper 代码。当前 Apache-2.0 授权模型下，Typeforme 不包含 Squirrel、ibus-rime 等 GPL-3.0 Rime 前端代码。若分发具有独立授权的 Rime schema 或数据包，应作为第三方资产随包提供上游授权文本和归属声明。

## 已知限制

- iOS 键盘扩展必须开启 Full Access 才能和 host app / Mac Bridge 通讯。
- iOS 键盘扩展建议使用 Release 构建做真机测试。
- Qwen3.5 9B、Qwen3-ASR 1.7B BF16 占用较高内存和磁盘空间。
- 完整 iOS 构建需要 Xcode。
- ad-hoc 签名的内置 `llama-server` 首次运行可能被 Gatekeeper 拦截；正式分发应使用 Developer ID 签名。
