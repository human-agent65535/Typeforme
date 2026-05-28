# iOS Agent Map

## Scope

- Host app source lives in `TypeformeIOS/`; keyboard extension source lives in `TypeformeKeyboard/`; host/keyboard shared models live in `Shared/`.
- macOS/iOS Bridge protocol DTOs that are intentionally shared live in `../Sources/Typeforme/Bridge/BridgeProtocolModels.swift`.

## Verification

- For iOS source, shared iOS models, or Bridge DTO changes, run from the repository root:

```sh
scripts/verify-ios-simulator.sh
```

- Before simulator UI checks, preserve user simulator state: reuse a booted simulator if one exists; otherwise boot only the configured `iPhone 17 Pro Max`.
- Recording, keyboard standby, URL handoff, Darwin notifications, or `AVAudioSession` changes still need the flow checks in root `AGENTS.md`; microphone behavior also needs a real-device deploy.

## Boundaries

- iOS keyboard dictation is host-owned. Keep the three audio paths separate unless a replacement is verified: host UI `AudioRecorder` prewarm, keyboard `StandbyAudioSession`, and `StandbyKeeper` silent background reachability.
- Private API host-wake code in `TypeformeKeyboard/KeyboardViewController.swift` is an intentional non-App-Store workaround. Do not remove it as a publication cleanup.
- Treat `KeyboardViewController.swift` as orchestration. Prefer adding tested pure helpers for new text-keyboard, Rime, touch-learning, or rewrite logic instead of adding more standalone state-machine code to the controller.
