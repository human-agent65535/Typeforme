# Typeforme

Typeforme 是一套以 Mac 为算力中心的本地语音输入系统：在本机完成语音识别、文本整理与选区改写，并通过统一的 Bridge HTTP API 将上述能力开放给本机 Mac、其它 Mac Client 与 iOS 键盘扩展。默认链路完全离线，模型在 Apple Silicon 上本机运行；如需更高算力，可将整理工作转发至局域网或公网上的 LM Studio / OpenAI-compatible endpoint。

首次启动进入 Client mode；切换至 Server mode 后可启用 Bridge、本地语音识别与文本整理。

## 亮点

- **全本地、可审计**：WhisperKit 与本地 Qwen3.5 组合下，音频与文本不离开本机；无第三方分析 SDK，无设备指纹；网络出口仅 HuggingFace 模型下载、用户配置的 Mac Bridge、可选的 LM Studio endpoint 三类，均由用户主动触发。代码以 Apache-2.0 开源。
- **超越听写的选区改写**：选中错误片段后录音修复（`repair_selection`），或以语音指令让模型重写选区 / 输入框（`command`），改写保留 10 分钟撤销窗口。
- **iOS 键盘内置完整拼音纠错栈（核心支持英文与简体中文）**：六套 Rime schema、Gutter Rime probe、按键 2D Gaussian 触点学习、Backspace 反向纠错信号 —— 多层组合，在开源 iOS 键盘中较为罕见。详见下文「拼音落键纠错」。
- **两端共用一条 Bridge**：iOS 键盘扩展与其它 Mac Client 通过同一套 8 个 REST + SSE 端点接入 Mac Server，token 鉴权，LAN-first 并发探测，叠加 Public Bridge URL 即可走 VPN / 隧道 / 反向代理。
- **多触发与实时预览**：支持全局快捷键、双击修饰键按住说话；HUD 同步展示 Apple Speech 端上实时预览，本机 ASR 出结果后无缝替换；同一段预览作为 `alternate_transcript` 提供给整理模型辅助纠错。
- **Voice Draft（beta）**：识别结果以选中草稿形态落入焦点输入框，Style / Wand 可一次替换或继续重写，无需切换焦点。
- **五种整理模式与可定制 prompt、词典联动**：Clean / Polish / Polish+ / Structure+ / Formal+；通过 `system.md` 与 `mode-*.md` 覆盖内置 prompt；用户词典同时进入 corrector 上下文与 iOS Rime 候选词。

## 功能

- 语音识别：WhisperKit 或 Qwen3-ASR GGUF（含 mmproj），按 provider 自动转 16k mono WAV。
- 文本整理：本地 Qwen3.5 2B / 4B / 9B GGUF，或 LM Studio / OpenAI-compatible endpoint。
- 输出模式：Clean、Polish、Polish+、Structure+、Formal+ 五档；支持自定义 prompt 覆盖内置版本。
- 触发方式：全局快捷键（默认 `⌘⇧Space`）、双击修饰键按住说话（右 ⌥/⌘/⇧/⌃、左 ⌥、Fn 可选）。
- 文本提交：默认通过 Accessibility 合成 Unicode 文本输入；剪贴板仅作为手动 fallback。
- 选区编辑：两种 intent —— `repairSelection` 听写修复选区，`command` 按语音指令改写选区或当前输入框；改写保留 10 分钟撤销窗口。
- Voice Draft（beta）：识别文本以选中草稿形态落入焦点输入框，Style / Wand 可 in-place 替换或继续改写，Esc 取消。
- Live preview：开启后录音过程中由 Apple Speech 提供端上实时部分转录，并在 HUD 同步显示；同一段预览作为 `alternate_transcript` 提供给整理模型辅助纠错。
- 用户词典：以本机 JSON 形式存储，同时进入 corrector prompt、`/v1/edit-text` 上下文以及 iOS Rime 用户词典。
- iOS 键盘：核心支持英文与简体中文；提供 Tap-to-speak / Hold-to-speak、选区修复、Wand 指令改写与模式切换；中文输入基于 Rime 拼音并内置多层落键纠错（详见下文）。
- Bridge HTTP API：
  - `GET  /v1/health`
  - `GET  /v1/pairing`
  - `GET  /v1/settings`
  - `POST /v1/settings`
  - `POST /v1/dictate`
  - `POST /v1/restyle`
  - `POST /v1/edit-text`
  - `GET  /v1/jobs/:jobID/events`（Server-Sent Events）
- Pairing JSON：包含 `token`、启用的 LAN URL 候选与启用的 Public Bridge URL；语言、默认模式与模型状态由 iOS 通过 `/v1/settings` 拉取。

## 音频处理

- Mac 与 iOS 均录制临时 M4A / AAC 音频文件。
- iOS 与 Mac Client 将临时音频上传至 Mac Bridge；Mac Server 本机录音直接进入本机语音识别与文本整理流程。
- Bridge 使用 `multipart/form-data` 接收音频文件。
- Server 侧在进入 ASR 前按 provider 需要转码为 16k mono WAV。
- 启用 Debug mode 时，音频与处理结果会复制至 `DebugCaptures/`；常规处理流程使用临时文件，并在处理结束后清理。

## 拼音落键纠错

iOS 键盘核心支持英文与简体中文；中文输入基于 Rime 拼音。从落键到候选过程叠加了多层纠错机制，整体组合在开源 iOS 键盘中较为罕见：

1. **Rime schema 自带的拼音纠错**：六套 schema（标准 / 扩展 / 大词库 × 纠错开关），覆盖常见拼音错音；由 Pinyin Correction 设置统一启停（`iOS/TypeformeKeyboard/RimeInputController.swift:49-68`）。
2. **Gutter Rime probe（基于语言学的触点歧义解决）**：两键交界 6pt 以内的触点会启动独立的 Rime probe session，依次将候选字母传入并判断哪一个可延续当前音节；probe 返回 `.extend` / `.split` / `.unknown` 三种结果（`iOS/TypeformeKeyboard/KeyboardViewController.swift:1143-1223`、`iOS/TypeformeKeyboard/RimeInputController.swift:631-694`）。
3. **按键 2D Gaussian 触点学习**：每个按键维护一份高斯偏移分布（σx≈0.34、σy≈0.70），持续学习用户在水平与垂直方向的击键偏置。Probe 返回 `.unknown` 时由 Gaussian 模型给出判定（`iOS/TypeformeKeyboard/KeyboardViewController.swift:8594-8836`）。
4. **Backspace 反向纠错信号**：约 500ms 内若用户连续按下 backspace 与邻近键，原始触点将以 3× 权重的 correction sample 反向训练 Gaussian，使用户的纠错动作直接回灌至触点模型（`iOS/TypeformeKeyboard/KeyboardViewController.swift:1264-1366`）。
5. **Drag rescue**：从首键拖出 14pt 后落到另一个文本键时，提交目标键而非首键，以允许中途纠错（`iOS/TypeformeKeyboard/KeyboardViewController.swift:802-823`）。
6. **用户词典自动生成拼音编码**：Mac 端自定义词条同步至 iOS 后，通过 `CFStringTransform(kCFStringTransformMandarinLatin)` 转写为全拼与首字母两种码，以 100k / 90k 双档权重写入 Rime `typeforme_custom_phrase.txt`（`iOS/TypeformeKeyboard/RimeInputController.swift:747-836`）。
7. **iOS 键盘扩展 hit-test 兼容**：键间空隙采用 0.01-alpha 覆盖层接管命中测试，避免触点泄漏至 host app；文本键经由 overlay 坐标路由处理，不依赖 UIButton hit-test（`iOS/TypeformeKeyboard/KeyboardViewController.swift:391-394`）。

其中最具区分度的是 #2 与 #4：Gutter probe 将语言学正确性嵌入硬件触点的歧义解决过程 —— 并非在 Rime 接收输入之后再纠错，而是在字母尚未确认前即结合 IME 上下文作出选择；Backspace 信号则将用户的纠错动作回灌至触点模型，使按键分布随使用持续逼近实际击键习惯。

## 系统要求

- macOS 14+，Apple Silicon。
- Xcode，用于构建 macOS app、iOS app 与 KeyboardShortcuts 资源。
- 麦克风权限。
- Accessibility 权限，用于提交整理后的文本。
- iOS 17+；键盘扩展需开启 Full Access。
- 模型尺寸参考：Qwen3.5 2B 适用于 16GB 机型，Qwen3.5 4B / 9B 与 Qwen3-ASR 1.7B BF16 建议 32GB 以上内存。Qwen3-ASR 与本地 Qwen3.5 依赖内置 `llama-server`；WhisperKit 与 LM Studio endpoint 不依赖内置 `llama-server`。

## 快速开始

使用 Qwen3-ASR GGUF 或本地 Qwen3.5 前，请先准备本地 llama.cpp 运行时。WhisperKit 与 LM Studio endpoint 不依赖内置 `llama-server`。

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

构建并安装 iOS app 与键盘扩展至已配对 iPhone：

```sh
scripts/build-rime-ios-data.sh
scripts/deploy-ios.sh
```

亦可在 Xcode 中打开 `iOS/TypeformeIOS.xcodeproj` 构建。键盘扩展的真机验证建议使用 Release 构建。

## 配对 iOS

1. 在 Mac app 切换至 Server 模式并启用 Bridge。
2. 需要局域网访问时启用 LAN access，并选择 `All adapters` 或具体 LAN adapter。
3. 需要公网、隧道、VPN 或反向代理访问时启用 Public Bridge URL，填入客户端实际访问的 URL。
4. 复制 Pairing JSON 至 iOS host app 并保存。
5. iOS 在 Wi-Fi 下并发探测 LAN URL（1.5s 超时），首个可达即返回；LAN 不可达时回落至 Public Bridge URL（3.0s 超时）。网络变化后将重新探测。

## 运行时文件

`scripts/vendor-llama.sh` 将 `llama-server-arm64` 及相关动态库复制至 `vendor/`。`scripts/build-app.sh` 将这些文件打包至 `dist/Typeforme.app`，并在可用时签名内置 `llama-server`。

缺少 `vendor/llama-server-arm64` 时，相关本地 GGUF 功能将报告不可用。

设置存放于 `UserDefaults` 域 `com.example.typeforme.mac`。运行数据默认位于：

```text
~/Library/Application Support/Typeforme/
```

主要子目录：

- `Models/`：Qwen3.5 correction 模型。
- `Models/WhisperKit/`：WhisperKit cache。
- `Models/Qwen3ASR/`：Qwen3-ASR GGUF 与 mmproj。
- `prompts/`：`system.md` 与 `mode-*.md` prompt override。
- `Bridge/`：临时上传音频。
- `ASRWork/`：ASR 前的临时转码音频。
- `DebugCaptures/`：Debug mode 下保留的最近记录。
- `Logs/`：本地服务日志。

模型自动安装由 `ModelAutoInstaller` 负责：支持断点续传与 SHA256 校验，超时上限为 4 小时。

## 项目结构

```text
Sources/Typeforme/
  App/             macOS app lifecycle 与 DictationCoordinator
  ASR/             WhisperKit、Qwen3-ASR、音频转码
  Audio/           macOS M4A 录音
  Bridge/          本地 HTTP Bridge 与远端 Bridge client
  Hotkey/          快捷键与双击修饰键监听
  LLM/             文本整理后端、llama-server 管理、输出校验
  Memory/          AppSettings、AppPaths、模型下载、用户词典
  Models/          领域模型与 enum
  Prompts/         内置 prompt、prompt builder、override store
  TextCommit/      文本输入提交与剪贴板 fallback
  UI/              Settings、HUD、菜单栏 UI
  Diagnostics/     Debug capture

iOS/
  TypeformeIOS.xcodeproj
  TypeformeIOS/       iOS host app
  TypeformeKeyboard/  自定义键盘扩展（含 Rime 拼音输入）
  Shared/             host app 与键盘扩展共用模型

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

iOS 或共享 Bridge 改动需执行 iOS simulator build：

```sh
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project iOS/TypeformeIOS.xcodeproj \
  -scheme TypeformeIOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios-derived \
  build
```

Benchmark 脚本改动需通过 Swift typecheck：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swift -frontend -typecheck \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
  scripts/benchmark-correctors.swift
```

Bridge 与 iOS 键盘行为需真机链路验证。

## Benchmark

Benchmark 环境：本机 Apple M4 Max 16-core / 64GB，远端 LM Studio 测试机为 RTX 5090。数据记录 warm path；首次下载、首次 Metal 编译与进程冷启动不计入。

ASR benchmark 使用 Bridge `/v1/dictate` 执行标准应用流程，音频样本来自本机 `DebugCaptures/*/audio.m4a`。表内 ASR latency 取自 Bridge response 的 `transcription_latency_ms`；`Median wall` 为脚本端到端耗时。运行期间，脚本将文本整理后端临时设置为 `qwen35_2b`，并将 `correction_timeout_ms` 设置为 `100`，结束后恢复原设置。

| ASR 模型 | Median ASR | P95 ASR | Median wall | Median RTF |
|---|---:|---:|---:|---:|
| WhisperKit large-v3_947MB (Whisper v3 full) | 4044 ms | 6976 ms | 4773 ms | 0.323 |
| Qwen3-ASR 1.7B BF16 | 738 ms | 1134 ms | 2139 ms | 0.062 |

ASR 表记录性能指标。

文本整理 benchmark 需连接正在运行的 Typeforme Bridge。`scripts/benchmark-correctors.swift` 通过 `/v1/settings` 切换后端，并通过 `/v1/restyle`、`/v1/edit-text` 覆盖 app 内部的 settings、PromptBuilder、CorrectorFactory、validator、post-processor 与 Bridge response path。

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

`TYPEFORME_BENCHMARK_TIMEOUT_MS`、`TYPEFORME_BENCHMARK_LOCAL_LMSTUDIO_*`、`TYPEFORME_BENCHMARK_REMOTE_LMSTUDIO_*` 将临时更新 Bridge server 的 correction timeout 与 LM Studio URL/model，脚本结束后通过 `/v1/settings` 恢复原设置。脚本输出 latency summary 与 per-sample JSONL。

## 隐私

代码层面可证明的本地优先；下列每项措施均附其用途：

- **全管道本地化运行**：在 WhisperKit 与本地 Qwen3.5 组合下，`DictationCoordinator` 依次执行 `asr.transcribe` 与 `corrector.correct`，整个流程位于进程内（`Sources/Typeforme/App/DictationCoordinator.swift:324-334`）。
  - *用途*：保证完全离线工作流下，音频与文本无任何外发路径。
- **无第三方分析 / Crash 上报 / Telemetry SDK**：仓库内未引用 Mixpanel、Amplitude、Segment、PostHog、Sentry、Crashlytics 或 Firebase。
  - *用途*：消除 SDK 自带的隐形外发与采样上报。
- **无 IDFA / `identifierForVendor` / 设备指纹追踪**。
  - *用途*：阻断跨应用与跨会话的用户标识能力。
- **网络出口仅三类，均由用户主动触发**：(1) HuggingFace 模型下载（断点续传 + SHA256 校验，仅在首次安装时触发）；(2) 用户配置的 Mac Bridge URL（Mac Client / iOS 键盘 → Mac Server）；(3) 可选的 LM Studio / OpenAI-compatible endpoint（默认关闭）。
  - *用途*：将外发路径压缩至最小且可枚举的三种，便于审计。
- **日志默认屏蔽正文**：常规日志通过 OSLog `privacy:` 注解屏蔽用户文本；仅在启用 Debug mode 后，原始音频与文本才会写入 `DebugCaptures/`，且仅落盘于本机用户目录。
  - *用途*：即使第三方取得运行日志，也无法还原用户原话。
- **凭据本地化**：iOS 配对 token 存储于 Keychain；Mac 端 token、prompt、词典与模型均位于本机用户目录，不参与 iCloud / 跨设备同步。
  - *用途*：避免 token 或个性化内容随云端同步扩散。
- **iOS 键盘 Full Access 范围受限**：键盘扩展自身仅通过 `KeyboardLocalClient` 连接 `ws://127.0.0.1:18082/keyboard`（硬编码 localhost），与 iOS host app 之间走本地 WebSocket + App Group；对 Mac Bridge 的请求由 host app 发出，目标为用户配置的 URL（`iOS/TypeformeKeyboard/KeyboardLocalClient.swift:4`）。
  - *用途*：使用户授予 Full Access 的实际效果限定为"键盘可达本机 host app"，外发完全由 host app 控制。
- **代码以 Apache-2.0 开源**，可供审计；第三方依赖（SwiftNIO、Hummingbird、WhisperKit、librime、llama.cpp）均采用宽松许可。
  - *用途*：上述所有断言可独立审计。

## 平台约束与 workaround

下列实现细节并非过度设计，而是 iOS 键盘扩展与 macOS 沙箱所施加的约束所致。直接简化会破坏对应功能：

- **0.01-alpha 命中测试覆盖层**（`iOS/TypeformeKeyboard/KeyboardViewController.swift:391-394`）
  - *原因*：iOS 自定义键盘扩展按像素 alpha 决定 hit-test 命中。若使用 `.clear`，键间空隙的触点会泄漏给 host app，键盘无法接管该区域。0.01 alpha 满足 iOS 的最小可命中阈值，又对用户不可见。
- **键盘扩展真机测试使用 Release 构建**
  - *原因*：Debug 构建会被 Swift 拆分为 stub + dylib，而 iOS 键盘扩展守护进程无法独立加载该 dylib，使用 Debug 构建会导致键盘加载失败。
- **StandbyKeeper 后台静音音频循环**（`iOS/TypeformeIOS/Recording/StandbyKeeper.swift`）
  - *原因*：iOS 不允许键盘扩展长时间维持后台；host app 通过播放 44.1kHz / Float32 / 0.001 音量的静音流维持 audio session 活跃，保证键盘需要录音或通讯时 host app 仍可即时响应。
- **三条独立的 iOS 音频路径**（host UI `AudioRecorder` prewarm、键盘扩展 `StandbyAudioSession`、后台 `StandbyKeeper`）
  - *原因*：iOS 设计上麦克风访问由 host app 持有，三条路径分别对应"host UI 直接录音"、"键盘扩展请求录音"、"键盘扩展后台维持可达"三种场景，合并会丢失其中至少一种触发能力。`AGENTS.md` 将此列为不变量。
- **`typeforme://` URL scheme + Darwin notification + App Group 三段联动**（`iOS/TypeformeIOS/KeyboardHostHandoff.swift:252-294`、`iOS/TypeformeKeyboard/KeyboardViewController.swift:4658-4665`）
  - *原因*：iOS 键盘扩展无法直接调用 host app API，跨进程协调只能通过 URL scheme 唤起、Darwin notification 同步状态、App Group 共享数据三者配合完成。
- **键盘扩展不直接对外发起 HTTP**（`iOS/TypeformeKeyboard/KeyboardLocalClient.swift:4`）
  - *原因*：键盘扩展自身仅连接本机 `ws://127.0.0.1:18082/keyboard`，对 Mac Bridge 的请求由 host app 转发。这同时降低了键盘扩展的攻击面，并使 Full Access 在实际效果上仅意味着"键盘可达本机 host app"。
- **0.55s 最小按压时长 + 1.25s 选区 TTL**（`iOS/TypeformeKeyboard/KeyboardViewController.swift:297, 303`）
  - *原因*：0.55s 用于区分 hold 与 tap；1.25s 选区 TTL 用于在键盘焦点暂时丢失时仍保留 selection 上下文，防止用户的选区被网络往返期间的事件清除。
- **14pt drag rescue 阈值**（`iOS/TypeformeKeyboard/KeyboardViewController.swift:106`）
  - *原因*：经验阈值；小于此距离视为手指抖动并维持首键，超过则视为有意拖动并切换至目标键。对应"首键粘性 vs 中途纠错"的取舍。
- **ad-hoc 签名的内置 `llama-server`**
  - *原因*：开发与个人分发场景下不强制 Developer ID 签名；首次运行可能被 macOS Gatekeeper 拦截，需要用户在系统设置中放行。正式分发应改为 Developer ID 签名。
- **模型自动安装走断点续传 + SHA256 校验**（`Sources/Typeforme/Memory/ModelAutoInstaller.swift`）
  - *原因*：HuggingFace 上的 GGUF 文件可达 GB 级，网络中断时全量重下成本高；安装过程使用 4 小时超时窗口并按 SHA256 校验完整性。

## 授权

Typeforme 自有代码以 Apache License 2.0 授权，详见 `LICENSE`。

第三方依赖、可选本地运行时、模型文件与用户提供的资产适用各自的上游授权。当前第三方授权摘要见 `THIRD_PARTY_NOTICES.md`。

Rime 集成基于 `librime`（BSD-3-Clause）与 Typeforme 自有 wrapper 代码。在当前 Apache-2.0 授权模型下，Typeforme 不包含 Squirrel、ibus-rime 等 GPL-3.0 Rime 前端代码。若分发具有独立授权的 Rime schema 或数据包，应作为第三方资产随包提供上游授权文本与归属声明。

## 作者

- Author: human agent
- UX/UI lead: Claude
- Coding lead: Codex

## 已知限制

- iOS 键盘扩展须开启 Full Access 方可与 host app / Mac Bridge 通讯。
- Qwen3.5 9B、Qwen3-ASR 1.7B BF16 占用较高内存与磁盘空间。
- 完整 iOS 构建需 Xcode。

平台层面的约束与对应 workaround 见上文「平台约束与 workaround」。
