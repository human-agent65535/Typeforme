# Typeforme

Typeforme 是一个本地优先的语音输入工具。Mac app 负责录音、语音识别、文本整理和 Bridge 服务；iOS host app 与键盘扩展可以连接到 Mac Bridge，在 iPhone 上使用同一套听写和改写能力。

默认配置优先使用本机模型。需要更高算力时，可以把文本整理转发到用户配置的 LM Studio 或 OpenAI-compatible endpoint。

## 功能

- 语音识别：WhisperKit 或 Qwen3-ASR GGUF。
- 文本整理：本地 Qwen3.5 GGUF，或用户配置的 LM Studio / OpenAI-compatible endpoint。
- 输出模式：Clean、Polish、Polish+、Structure+、Formal+。
- 触发方式：全局快捷键、双击修饰键按住说话、iOS 键盘按钮。
- 文本提交：macOS 默认使用 Accessibility 输入文本；剪贴板仅作为手动 fallback。
- 选区编辑：支持听写修复选区，以及用语音指令改写选区或当前输入框。
- Voice Draft：先把识别结果作为草稿插入，再继续整理或改写。
- Live Preview：录音时显示 Apple Speech 部分转录，并可作为整理模型的辅助上下文。
- 用户词典：用于文本整理上下文，也可同步到 iOS 拼音候选词。
- iOS 键盘：支持英文和简体中文输入；中文输入基于 Rime 拼音，包含拼音纠错、触控学习和用户词典。
- Bridge API：供 iOS 键盘扩展和其他 Mac Client 连接 Mac Server。

## 音频与隐私

- Mac 与 iOS 都录制临时 M4A / AAC 文件。
- Mac Server 本机录音直接进入本机 ASR 与文本整理流程。
- iOS 与 Mac Client 会把临时音频上传到用户配对的 Mac Bridge。
- Server 会在 ASR 前按 provider 需要转码为 16k mono WAV。
- 常规日志避免记录用户正文。启用 Debug mode 后，音频和处理结果会写入本机 `DebugCaptures/` 供排查使用。
- 网络访问主要来自三类操作：模型下载、用户配置的 Mac Bridge、用户配置的外部文本整理 endpoint。

## 系统要求

- macOS 14+，Apple Silicon。
- Xcode，用于构建 macOS app、iOS app 与键盘扩展。
- 麦克风权限。
- macOS Accessibility 权限，用于自动提交文本。
- iOS 17+；键盘扩展需要开启 Full Access。
- 本地 Qwen3.5 与 Qwen3-ASR 需要较多内存和磁盘空间；小内存机器建议先使用较小模型或 WhisperKit。

## 快速开始

使用 Qwen3-ASR GGUF 或本地 Qwen3.5 前，先准备 llama.cpp 运行时。WhisperKit 与 LM Studio endpoint 不依赖内置 `llama-server`。

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

公开仓库默认使用非个人化 bundle prefix `com.example`。本机真机签名请创建被 git 忽略的 `iOS/LocalSigning.xcconfig`：

```xcconfig
DEVELOPMENT_TEAM = <your-team-id>
TYPEFORME_BUNDLE_PREFIX = <your-reverse-dns-prefix>
```

也可以在脚本环境变量中注入：

```sh
TEAM=<your-team-id> TYPEFORME_BUNDLE_PREFIX=<your-reverse-dns-prefix> scripts/deploy-ios.sh
```

也可以在 Xcode 中打开 `iOS/TypeformeIOS.xcodeproj` 构建；项目会自动读取 `iOS/LocalSigning.xcconfig`。

## 配对 iOS

1. 在 Mac app 切换到 Server mode 并启用 Bridge。
2. 需要局域网访问时启用 LAN access，并选择 `All adapters` 或具体 LAN adapter。
3. 需要公网、隧道、VPN 或反向代理访问时启用 Public Bridge URL。
4. 复制 Pairing JSON 到 iOS host app 并保存。
5. 在 iOS 设置中启用 Typeforme 键盘并开启 Full Access。

## 运行时文件

`scripts/vendor-llama.sh` 会把 `llama-server-arm64` 及相关动态库复制到 `vendor/`。`scripts/build-app.sh` 会把这些文件打包进 `dist/Typeforme.app`。

运行数据默认位于：

```text
~/Library/Application Support/Typeforme/
```

主要子目录：

- `Models/`：本地文本整理模型。
- `Models/WhisperKit/`：WhisperKit cache。
- `Models/Qwen3ASR/`：Qwen3-ASR GGUF 与 mmproj。
- `prompts/`：自定义 prompt override。
- `Bridge/`：Bridge 临时上传音频。
- `ASRWork/`：ASR 前的临时转码音频。
- `DebugCaptures/`：Debug mode 下保留的诊断记录。
- `Logs/`：本地服务日志。

## 项目结构

```text
Sources/Typeforme/
  App/             macOS app lifecycle 与 DictationCoordinator
  ASR/             WhisperKit、Qwen3-ASR、音频转码
  Audio/           macOS 录音
  Bridge/          本地 HTTP Bridge 与远端 Bridge client
  Hotkey/          快捷键与双击修饰键监听
  LLM/             文本整理后端与 llama-server 管理
  Memory/          设置、路径、模型下载、用户词典
  Prompts/         内置 prompt 与 override store
  TextCommit/      文本输入提交与剪贴板 fallback
  UI/              Settings、HUD、菜单栏 UI

iOS/
  TypeformeIOS.xcodeproj
  TypeformeIOS/       iOS host app
  TypeformeKeyboard/  自定义键盘扩展
  Shared/             host app 与键盘扩展共用模型

Tests/TypeformeTests/
Resources/
scripts/
vendor/
dist/
AGENTS.md
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

Bridge 与 iOS 键盘行为需要真机链路验证。

## 开发备注

- iOS 键盘录音由 host app 持有。相关代码保留了 host UI 录音、键盘触发录音、后台可达性三条音频路径。
- Keyboard Settings 里的 Host audio session 控制键盘听写保持就绪的时间；新安装默认 15 分钟。
- 键盘扩展真机验证建议使用 Release 构建。
- 缺少 `vendor/llama-server-arm64` 时，本地 GGUF 功能会报告不可用。

## 已知限制

- iOS 键盘扩展必须开启 Full Access 才能与 host app / Mac Bridge 通讯。
- 大模型会占用较高内存与磁盘空间。
- 完整 iOS 构建需要 Xcode。

## 授权

Typeforme 自有代码以 Apache License 2.0 授权，详见 `LICENSE`。

第三方依赖、可选本地运行时、模型文件与用户提供的资产适用各自的上游授权。当前第三方授权摘要见 `THIRD_PARTY_NOTICES.md`。

Rime 集成基于 `librime`（BSD-3-Clause）与 Typeforme 自有 wrapper 代码。Typeforme 不包含 Squirrel、ibus-rime 等 GPL-3.0 Rime 前端代码。
