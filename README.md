# Typeforme

Typeforme is a local-first voice typing tool. The Mac app owns recording, speech recognition, text refinement, and the Bridge service; the iOS host app and keyboard extension can connect to a Mac Bridge to use the same dictation and rewriting capabilities on iPhone.

The default configuration prefers on-device models. When more compute is needed, text refinement can be forwarded to a user-configured LM Studio or OpenAI-compatible endpoint.

## Features

- Speech recognition: Qwen3-ASR GGUF or NVIDIA Nemotron ASR.
- Text refinement: local Qwen3.5 GGUF, or a user-configured LM Studio / OpenAI-compatible endpoint.
- Output modes: Clean, Polish, Polish+, Structure+, Formal+.
- Triggers: global hotkey, double-tap-and-hold modifier key, iOS keyboard button.
- Text commit: macOS inserts text via Accessibility by default; the clipboard is only a manual fallback.
- Selection editing: dictate a repair for the current selection, or rewrite the selection / focused field with a spoken command.
- Voice Draft: insert the recognized text as a draft first, then keep refining or rewriting it.
- Live Preview: show the Apple Speech partial transcript while recording; it can also serve as supplementary context for the refinement model.
- User vocabulary: feeds refinement context and can sync to iOS pinyin candidates.
- iOS keyboard: English and Simplified Chinese input; Chinese input is built on Rime pinyin with typo correction, touch learning, and the user vocabulary.
- Bridge API: lets the iOS keyboard extension and other Mac clients connect to a Mac server.

## Audio and privacy

- Mac and iOS both record temporary M4A / AAC files.
- Local recordings on a Mac server go straight into the local ASR and refinement pipeline.
- iOS and Mac clients upload temporary audio to the user-paired Mac Bridge.
- The server transcodes to 16k mono WAV before ASR as each provider requires.
- Normal logs avoid user text. With Debug mode enabled, audio and processing results are written to the local `DebugCaptures/` folder for troubleshooting.
- Network access comes from three kinds of operations: model downloads, the user-configured Mac Bridge, and the user-configured external refinement endpoint.

## Requirements

- macOS 14+, Apple Silicon.
- Xcode, to build the macOS app, iOS app, and keyboard extension.
- Microphone permission.
- macOS Accessibility permission, for automatic text insertion.
- iOS 17+; the keyboard extension needs Full Access.
- Local Qwen3.5, Qwen3-ASR, and NVIDIA Nemotron ASR need significant memory and disk; on smaller machines start with the smaller models.

## Quick start

Prepare the llama.cpp runtime before using Qwen3-ASR GGUF or local Qwen3.5. NVIDIA Nemotron ASR additionally needs the local helper; an LM Studio endpoint does not depend on the bundled `llama-server`.

```sh
scripts/vendor-llama.sh <path-to-llama.cpp/build/bin>
scripts/build-nvidia-nemotron-helper.sh
```

Build the macOS app:

```sh
scripts/build-app.sh debug
scripts/build-app.sh debug --install
scripts/build-app.sh release
IDENTITY="Developer ID Application: ..." scripts/build-app.sh release
```

Run the macOS tests:

```sh
scripts/run-tests.sh
```

Build and install the iOS app and keyboard extension onto a paired iPhone:

```sh
scripts/build-rime-ios-data.sh
scripts/deploy-ios.sh
```

The public repository defaults to the non-personal bundle prefix `com.example`. For local device signing, create a git-ignored `iOS/LocalSigning.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = <your-team-id>
TYPEFORME_BUNDLE_PREFIX = <your-reverse-dns-prefix>
```

Or inject them as script environment variables:

```sh
TEAM=<your-team-id> TYPEFORME_BUNDLE_PREFIX=<your-reverse-dns-prefix> scripts/deploy-ios.sh
```

You can also open `iOS/TypeformeIOS.xcodeproj` in Xcode and build there; the project picks up `iOS/LocalSigning.xcconfig` automatically.

## Pairing iOS

1. Switch the Mac app to Server mode and enable Bridge.
2. For LAN access, enable LAN access and pick `All adapters` or a specific LAN adapter.
3. For public, tunnel, VPN, or reverse-proxy access, enable Public Bridge URL.
4. Copy the Pairing JSON into the iOS host app and save.
5. Enable the Typeforme keyboard in iOS Settings and turn on Full Access.

## Runtime files

`scripts/vendor-llama.sh` copies `llama-server-arm64` and its dynamic libraries into `vendor/`. `scripts/build-app.sh` packages them into `dist/Typeforme.app`.

Runtime data lives by default in:

```text
~/Library/Application Support/Typeforme/
```

Main subdirectories:

- `Models/`: local refinement models.
- `Models/Qwen3ASR/`: Qwen3-ASR GGUF and mmproj.
- `Models/NvidiaNemotron/`: NVIDIA Nemotron ASR model files.
- `prompts/`: custom prompt overrides.
- `Bridge/`: temporary audio uploaded to the Bridge.
- `ASRWork/`: temporary transcoded audio ahead of ASR.
- `DebugCaptures/`: diagnostic captures kept while Debug mode is on.
- `Logs/`: local service logs.

## Project layout

```text
Sources/Typeforme/
  App/             macOS app lifecycle and DictationCoordinator
  ASR/             Qwen3-ASR, NVIDIA Nemotron, audio transcoding
  Audio/           macOS recording
  Bridge/          local HTTP Bridge and remote Bridge client
  Hotkey/          hotkeys and double-tap modifier monitoring
  LLM/             refinement backends and llama-server management
  Memory/          settings, paths, model downloads, user vocabulary
  Prompts/         built-in prompts and the override store
  TextCommit/      text insertion and the clipboard fallback
  UI/              Settings, HUD, menu bar UI

iOS/
  TypeformeIOS.xcodeproj
  TypeformeIOS/       iOS host app
  TypeformeKeyboard/  custom keyboard extension
  Shared/             models shared by the host app and keyboard extension

Tests/TypeformeTests/
Resources/
scripts/
vendor/
dist/
AGENTS.md
```

## Verification

Baseline verification:

```sh
scripts/run-tests.sh
```

iOS or shared Bridge changes need an iOS simulator build:

```sh
scripts/verify-ios-simulator.sh
```

Bridge and iOS keyboard behavior need verification over a real device link.

## Development notes

- iOS keyboard recording is owned by the host app. The code keeps three audio paths: host UI recording, keyboard-triggered recording, and background reachability.
- The Host audio session setting in Keyboard Settings controls how long keyboard dictation stays ready; fresh installs default to 15 minutes.
- Use Release builds for on-device keyboard extension verification.
- Without `vendor/llama-server-arm64`, local GGUF features report themselves unavailable.

## Known limitations

- The iOS keyboard extension needs Full Access to talk to the host app / Mac Bridge.
- Large models use significant memory and disk space.
- A full iOS build requires Xcode.

## License

Typeforme's own code is licensed under the Apache License 2.0; see `LICENSE`.

Third-party dependencies, optional local runtimes, model files, and user-provided assets are covered by their respective upstream licenses. See `THIRD_PARTY_NOTICES.md` for the current third-party license summary.

The Rime integration is built on `librime` (BSD-3-Clause) plus Typeforme's own wrapper code. Typeforme does not include GPL-3.0 Rime frontend code such as Squirrel or ibus-rime.

Thanks to the Rime project for its open input method engine and ecosystem — Typeforme's Chinese input is built on `librime`.
