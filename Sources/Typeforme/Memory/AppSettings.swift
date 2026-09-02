import Foundation
import os.lock

/// Single source of truth for persisted settings. Non-secret values stay in
/// UserDefaults so SwiftUI `@AppStorage` and service-side reads stay in sync;
/// bearer tokens and API keys are stored in Keychain.
/// Keys are grouped by feature area; Settings UI may present them under a
/// different sidebar structure.
enum AppSettings {
    private static let currentMacDefaultsDomain = BundleIdentity.mainBundleIdentifier
    static let correctionContextSizeRange = 2_048...8_192

    enum Keys {
        // Recording
        static let maxRecordingDuration = "recording.maxDuration"   // seconds
        static let holdModifier         = "recording.holdModifier"  // HoldModifier raw
        static let voiceLivePreview     = "recording.voiceLivePreview" // Bool — show live transcript preview while recording
        static let voiceLivePreviewSource = "recording.voiceLivePreviewSource"
        static let soundFeedback        = "recording.soundFeedback" // Bool — start/stop/error cues
        static let launchAtLogin        = "app.launchAtLogin"
        static let showDockIcon         = "app.showDockIcon"

        // ASR
        static let asrQwenEnabled      = "asr.qwen3.enabled"
        static let asrNvidiaNemotronEnabled = "asr.nvidia.nemotron.enabled"
        static let asrAppleSpeechEnabled = "asr.appleSpeech.enabled"
        static let asrLanguageIDs       = "asr.languages"           // comma-separated ASRLanguageOption ids
        static let fastASRSource        = "asr.fast.source"
        static let asrNvidiaNemotronTimeoutSec = "asr.nvidia.nemotron.timeoutSec"
        static let asrNvidiaNemotronModelID = "asr.nvidia.nemotron.modelID"
        static let asrNvidiaNemotronEncoderPath = "asr.nvidia.nemotron.encoderPath"
        static let asrNvidiaNemotronEncoderDataPath = "asr.nvidia.nemotron.encoderDataPath"
        static let asrNvidiaNemotronDecoderJointPath = "asr.nvidia.nemotron.decoderJointPath"
        static let asrNvidiaNemotronTokenizerPath = "asr.nvidia.nemotron.tokenizerPath"
        static let asrNvidiaNemotronEncoderDownloadURL = "asr.nvidia.nemotron.encoderDownloadURL"
        static let asrNvidiaNemotronEncoderDataDownloadURL = "asr.nvidia.nemotron.encoderDataDownloadURL"
        static let asrNvidiaNemotronDecoderJointDownloadURL = "asr.nvidia.nemotron.decoderJointDownloadURL"
        static let asrNvidiaNemotronTokenizerDownloadURL = "asr.nvidia.nemotron.tokenizerDownloadURL"
        static let asrQwenLlamaTimeoutSec = "asr.qwen3.llama.timeoutSec"
        static let asrQwenLlamaModelID  = "asr.qwen3.llama.modelID"
        static let asrQwenLlamaMaxTokens = "asr.qwen3.llama.maxTokens"
        static let asrQwenLlamaModelPath = "asr.qwen3.llama.modelPath"
        static let asrQwenLlamaMMProjPath = "asr.qwen3.llama.mmprojPath"
        static let asrQwenLlamaModelDownloadURL = "asr.qwen3.llama.modelDownloadURL"
        static let asrQwenLlamaMMProjDownloadURL = "asr.qwen3.llama.mmprojDownloadURL"
        static let asrQwen06Q8ModelPath = "asr.qwen3.06q8.modelPath"
        static let asrQwen06Q8MMProjPath = "asr.qwen3.06q8.mmprojPath"
        static let asrQwen06Q8ModelDownloadURL = "asr.qwen3.06q8.modelDownloadURL"
        static let asrQwen06Q8MMProjDownloadURL = "asr.qwen3.06q8.mmprojDownloadURL"
        static let asrQwen06BF16ModelPath = "asr.qwen3.06bf16.modelPath"
        static let asrQwen06BF16MMProjPath = "asr.qwen3.06bf16.mmprojPath"
        static let asrQwen06BF16ModelDownloadURL = "asr.qwen3.06bf16.modelDownloadURL"
        static let asrQwen06BF16MMProjDownloadURL = "asr.qwen3.06bf16.mmprojDownloadURL"
        static let asrQwen17Q8ModelPath = "asr.qwen3.17q8.modelPath"
        static let asrQwen17Q8MMProjPath = "asr.qwen3.17q8.mmprojPath"
        static let asrQwen17Q8ModelDownloadURL = "asr.qwen3.17q8.modelDownloadURL"
        static let asrQwen17Q8MMProjDownloadURL = "asr.qwen3.17q8.mmprojDownloadURL"
        static let asrQwen17BF16ModelPath = "asr.qwen3.17bf16.modelPath"
        static let asrQwen17BF16MMProjPath = "asr.qwen3.17bf16.mmprojPath"
        static let asrQwen17BF16ModelDownloadURL = "asr.qwen3.17bf16.modelDownloadURL"
        static let asrQwen17BF16MMProjDownloadURL = "asr.qwen3.17bf16.mmprojDownloadURL"

        // Correction
        static let correctionBackend       = "correction.backend"   // CorrectionBackendKind raw
        static let aiWritingBackend        = "aiWriting.backend"
        static let correctionTimeoutMs     = "correction.timeoutMs"
        static let correctionColdTimeoutMs = "correction.coldTimeoutMs"
        static let correctionMaxTokens     = "correction.maxTokens"
        static let correctionContextSize   = "correction.contextSize"
        static let correctionMode   = "correction.mode"
        static let correctionAutoCommit    = "correction.autoCommit"
        static let numberOutputPreference  = "correction.numberOutputPreference"
        static let punctuationPreference   = "correction.punctuationPreference"
        static let llama2BPath             = "correction.llama2BPath"
        static let llama4BPath             = "correction.llama4BPath"
        static let llama9BPath             = "correction.llama9BPath"
        static let llama2BDownloadURL      = "correction.llama2BDownloadURL"
        static let llama4BDownloadURL      = "correction.llama4BDownloadURL"
        static let llama9BDownloadURL      = "correction.llama9BDownloadURL"
        static let llamaUseFlashAttn       = "correction.useFlashAttn"
        static let externalLLMBaseURL      = "correction.externalLLMBaseURL"
        static let externalLLMAPIKey       = "correction.externalLLMAPIKey"
        static let externalLLMModel        = "correction.externalLLMModel"

        // Prompts
        static let promptOverrideFolder = "prompts.overrideFolder"

        // Processing role
        static let processingMode      = "processing.mode"
        static let clientLocalBridgeURLs = "processing.client.localBridgeURLs"
        static let clientCloudBridgeURL = "processing.client.cloudBridgeURL"
        static let clientBridgeToken   = "processing.client.bridgeToken"
        static let clientLanguageIDs   = "processing.client.languages"
        static let clientBridgeEnabledRecognitionSources = "processing.client.enabledRecognitionSources"
        static let clientIdentityID    = "processing.client.identityID"
        static let clientSettingsRevision = "processing.client.settingsRevision"
        static let serverSettingsSnapshot = "processing.server.settingsSnapshot"
        static let clientSettingsSnapshot = "processing.client.settingsSnapshot"

        // Bridge
        static let bridgeEnabled    = "bridge.enabled"
        static let bridgeLANEnabled = "bridge.lanEnabled"
        static let bridgeLANAdapter = "bridge.lanAdapter"
        static let bridgePublicEnabled = "bridge.publicEnabled"
        static let bridgePort       = "bridge.port"
        static let bridgeAuthToken  = "bridge.authToken"
        static let bridgeHostname   = "bridge.hostname"

        // Diagnostics
        static let diagnosticsDebugMode = "diagnostics.debugMode"
        static let diagnosticsDebugCaptureLimit = "diagnostics.debugCaptureLimit"

        // Setup
        static let setupGuideHasShown = "setup.guide.hasShown"
        static let setupGuideCompleted = "setup.guide.completed"
    }

    static func registerDefaults() {
        let defaults: [String: Any] = [
            Keys.maxRecordingDuration: 30.0,
            Keys.holdModifier:         HoldModifier.rightOption.rawValue,
            Keys.voiceLivePreview:     true,
            Keys.voiceLivePreviewSource: VoiceLivePreviewSource.off.rawValue,
            Keys.soundFeedback:        true,
            Keys.launchAtLogin:        true,
            Keys.showDockIcon:         false,

            Keys.asrQwenEnabled:    false,
            Keys.asrNvidiaNemotronEnabled: false,
            Keys.asrAppleSpeechEnabled: false,
            Keys.asrLanguageIDs:    ASRLanguageSelection.defaultRawValue,
            Keys.fastASRSource:     RecognitionSource.qwen.rawValue,
            Keys.asrNvidiaNemotronTimeoutSec: 40,
            Keys.asrNvidiaNemotronModelID: NvidiaNemotronASRModelCatalog.defaultID,
            Keys.asrQwenLlamaTimeoutSec: 40,
            Keys.asrQwenLlamaModelID: QwenASRModelCatalog.defaultID,
            Keys.asrQwenLlamaMaxTokens: 2048,
            Keys.asrQwenLlamaModelPath: AppPaths.qwen3ASRGGUFFile.path,
            Keys.asrQwenLlamaMMProjPath: AppPaths.qwen3ASRMMProjFile.path,
            Keys.asrQwenLlamaModelDownloadURL: "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/main/Qwen3-ASR-0.6B-Q8_0.gguf?download=true",
            Keys.asrQwenLlamaMMProjDownloadURL: "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/main/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf?download=true",

            Keys.correctionBackend:       CorrectionBackendKind.qwen35_4B.rawValue,
            Keys.aiWritingBackend:        AIWritingBackend.languageModel.rawValue,
            Keys.correctionTimeoutMs:     1500,
            Keys.correctionColdTimeoutMs: 30000,
            Keys.correctionMaxTokens:     128,
            Keys.correctionContextSize:   4096,
            Keys.correctionMode:   CorrectionMode.polishPlus.rawValue,
            Keys.correctionAutoCommit:    true,
            Keys.numberOutputPreference:  NumberOutputPreference.automatic.rawValue,
            Keys.punctuationPreference:   PunctuationOutputPreference.normal.rawValue,
            Keys.llama2BPath:             AppPaths.llama2BFile.path,
            Keys.llama4BPath:             AppPaths.llama4BFile.path,
            Keys.llama9BPath:             AppPaths.llama9BFile.path,
            // Defaults point to unsloth's GGUF re-pack (most-downloaded community
            // quants for Qwen3.5). Editable in the Settings UI if you prefer
            // bartowski/lmstudio-community or a different quant level.
            Keys.llama2BDownloadURL:      "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf?download=true",
            Keys.llama4BDownloadURL:      "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf?download=true",
            Keys.llama9BDownloadURL:      "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf?download=true",
            Keys.llamaUseFlashAttn:       true,
            Keys.externalLLMBaseURL:      "http://127.0.0.1:1234",
            Keys.externalLLMModel:        "",

            Keys.promptOverrideFolder: AppPaths.promptsDir.path,

            Keys.processingMode:    ProcessingMode.client.rawValue,
            Keys.clientLocalBridgeURLs: "",
            Keys.clientCloudBridgeURL: "",
            Keys.clientLanguageIDs: ASRLanguageSelection.defaultRawValue,
            Keys.clientBridgeEnabledRecognitionSources: "",

            Keys.bridgeEnabled:    false,
            Keys.bridgeLANEnabled: false,
            Keys.bridgeLANAdapter: "all",
            Keys.bridgePublicEnabled: false,
            Keys.bridgePort:       18081,
            Keys.bridgeHostname:   "",

            Keys.diagnosticsDebugMode: false,
            Keys.diagnosticsDebugCaptureLimit: 10,
            Keys.setupGuideHasShown: false,
            Keys.setupGuideCompleted: false,
        ]
        var registeredDefaults = defaults
        for spec in QwenASRModelCatalog.all {
            registeredDefaults[spec.modelPathKey] = spec.defaultModelPath
            registeredDefaults[spec.mmprojPathKey] = spec.defaultMMProjPath
            registeredDefaults[spec.modelURLKey] = spec.defaultModelURL
            registeredDefaults[spec.mmprojURLKey] = spec.defaultMMProjURL
        }
        for file in NvidiaNemotronASRModelCatalog.spec(for: NvidiaNemotronASRModelCatalog.defaultID).files {
            registeredDefaults[file.pathKey] = file.defaultPath
            registeredDefaults[file.urlKey] = file.defaultURL
        }
        UserDefaults.standard.register(defaults: registeredDefaults)

        do {
            _ = try ensureBridgeAuthToken()
        } catch {
            Log.bridge.error("Bridge auth token initialization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Service-side accessors

    private static var ud: UserDefaults { .standard }
    private static let secureSettingsStore = KeychainSecureSettingsStore()
    private static let bridgeAuthTokenLock = NSLock()
    private static let cachedClientIdentityID = OSAllocatedUnfairLock<String?>(initialState: nil)

    private static func secureSetting(forKey key: String) -> SecureSettingValue {
        SecureSettingValue(key: key, store: secureSettingsStore)
    }

    private static func secureString(forKey key: String) -> String {
        secureSetting(forKey: key).load()
    }

    @discardableResult
    private static func setSecureString(_ value: String, forKey key: String) throws -> String {
        try secureSetting(forKey: key).set(value)
    }

    private static func rawSetting<Value>(
        forKey key: String,
        default fallback: Value
    ) -> Value where Value: RawRepresentable, Value.RawValue == String {
        rawSetting(forKey: key, default: fallback, defaults: ud)
    }

    private static func rawSetting<Value>(
        forKey key: String,
        default fallback: Value,
        defaults: UserDefaults
    ) -> Value where Value: RawRepresentable, Value.RawValue == String {
        guard let raw = defaults.string(forKey: key),
              let value = Value(rawValue: raw)
        else { return fallback }
        return value
    }

    static let serverScopedSettingKeys: [String] = [
        Keys.asrQwenEnabled,
        Keys.asrNvidiaNemotronEnabled,
        Keys.asrAppleSpeechEnabled,
        Keys.asrLanguageIDs,
        Keys.fastASRSource,
        Keys.asrNvidiaNemotronTimeoutSec,
        Keys.asrNvidiaNemotronModelID,
        Keys.asrQwenLlamaTimeoutSec,
        Keys.asrQwenLlamaModelID,
        Keys.asrQwenLlamaMaxTokens,
        Keys.asrQwenLlamaModelPath,
        Keys.asrQwenLlamaMMProjPath,
        Keys.asrQwenLlamaModelDownloadURL,
        Keys.asrQwenLlamaMMProjDownloadURL,
        Keys.correctionBackend,
        Keys.aiWritingBackend,
        Keys.correctionTimeoutMs,
        Keys.correctionColdTimeoutMs,
        Keys.correctionMaxTokens,
        Keys.correctionContextSize,
        Keys.correctionMode,
        Keys.correctionAutoCommit,
        Keys.numberOutputPreference,
        Keys.punctuationPreference,
        Keys.llama2BPath,
        Keys.llama4BPath,
        Keys.llama9BPath,
        Keys.llama2BDownloadURL,
        Keys.llama4BDownloadURL,
        Keys.llama9BDownloadURL,
        Keys.llamaUseFlashAttn,
        Keys.externalLLMBaseURL,
        Keys.externalLLMModel,
        Keys.promptOverrideFolder,
        Keys.bridgeEnabled,
        Keys.bridgeLANEnabled,
        Keys.bridgeLANAdapter,
        Keys.bridgePublicEnabled,
        Keys.bridgePort,
        Keys.bridgeHostname,
        Keys.diagnosticsDebugMode,
        Keys.diagnosticsDebugCaptureLimit,
    ] + QwenASRModelCatalog.all.flatMap {
        [$0.modelPathKey, $0.mmprojPathKey, $0.modelURLKey, $0.mmprojURLKey]
    } + NvidiaNemotronASRModelCatalog.all.flatMap { spec in
        spec.files.flatMap { [$0.pathKey, $0.urlKey] }
    }

    static let clientScopedSettingKeys: [String] = [
        Keys.clientLocalBridgeURLs,
        Keys.clientCloudBridgeURL,
        Keys.clientLanguageIDs,
        Keys.clientBridgeEnabledRecognitionSources,
    ]

    static var maxRecordingDuration: TimeInterval     { ud.double(forKey: Keys.maxRecordingDuration) }
    static var launchAtLogin: Bool                    { ud.bool(forKey: Keys.launchAtLogin) }
    static var showDockIcon: Bool                     { ud.bool(forKey: Keys.showDockIcon) }
    static var soundFeedback: Bool                    { ud.bool(forKey: Keys.soundFeedback) }
    /// When `true`, the recorder feeds PCM into the selected live-preview
    /// source so the HUD can show a transcript while the user is still
    /// speaking. The final text always comes from the Mac ASR + correction
    /// pipeline; preview text is display-only.
    static var voiceLivePreview: Bool {
        ud.bool(forKey: Keys.voiceLivePreview)
    }
    static var voiceLivePreviewSource: VoiceLivePreviewSource {
        guard voiceLivePreview else { return .off }
        let source: VoiceLivePreviewSource = rawSetting(forKey: Keys.voiceLivePreviewSource, default: .off)
        if processingMode == .client {
            return source.isClientEnabled(
                forRemoteRecognitionSources: clientBridgeEnabledRecognitionSources,
                correctionMode: correctionMode
            ) ? source : .off
        }
        return source.isEnabled(forRecognitionSources: enabledRecognitionSources, correctionMode: correctionMode) ? source : .off
    }
    static var holdModifier: HoldModifier {
        rawSetting(forKey: Keys.holdModifier, default: .rightOption)
    }

    static var configuredRecognitionSources: [RecognitionSource] {
        var sources: [RecognitionSource] = []
        if ud.bool(forKey: Keys.asrQwenEnabled) {
            sources.append(.qwen)
        }
        if ud.bool(forKey: Keys.asrNvidiaNemotronEnabled) {
            sources.append(.nvidiaNemotron)
        }
        if ud.bool(forKey: Keys.asrAppleSpeechEnabled) {
            sources.append(.appleSpeech)
        }
        return normalizedServerRecognitionSources(sources)
    }

    static var enabledRecognitionSources: [RecognitionSource] {
        configuredRecognitionSources
    }

    @MainActor
    static func isCorrectionModeAvailable(_ mode: CorrectionMode) -> Bool {
        guard mode == .fast else { return true }
        return FastASRRoute.readinessReport().ready
    }

    static func setEnabledRecognitionSources(_ sources: [RecognitionSource]) {
        let normalized = normalizedServerRecognitionSources(sources)
        ud.set(normalized.contains(.qwen), forKey: Keys.asrQwenEnabled)
        ud.set(normalized.contains(.nvidiaNemotron), forKey: Keys.asrNvidiaNemotronEnabled)
        ud.set(normalized.contains(.appleSpeech), forKey: Keys.asrAppleSpeechEnabled)
    }

    static func normalizedServerRecognitionSources(_ sources: [RecognitionSource]) -> [RecognitionSource] {
        RecognitionSource.recognizedSources(sources.map(\.rawValue))
    }

    static var fastASRSource: RecognitionSource {
        rawSetting(forKey: Keys.fastASRSource, default: .qwen)
    }

    static var clientBridgeEnabledRecognitionSources: [RecognitionSource] {
        recognitionSources(fromRaw: ud.string(forKey: Keys.clientBridgeEnabledRecognitionSources) ?? "")
    }

    static func setClientBridgeEnabledRecognitionSources(_ sources: [RecognitionSource]) {
        ud.set(RecognitionSource.rawValue(for: sources), forKey: Keys.clientBridgeEnabledRecognitionSources)
    }

    static func recognitionSources(fromRaw raw: String) -> [RecognitionSource] {
        RecognitionSource.recognizedSources(raw.components(separatedBy: ","))
    }

    static var asrCanonicalLanguageIDs: [String] {
        canonicalASRLanguageIDs(
            fromRawValue: ud.string(forKey: Keys.asrLanguageIDs)
                ?? ASRLanguageSelection.defaultRawValue
        )
    }

    static func canonicalASRLanguageIDs(fromRawValue rawValue: String) -> [String] {
        ASRLanguageSelection.parse(rawValue)
    }

    static var asrLanguageIDs: [String] {
        ASRLanguageSelection.validatedIDs(
            asrCanonicalLanguageIDs,
            sources: enabledRecognitionSources
        )
    }
    static var asrLocale: String                      { ASRLanguageSelection.primaryLanguageID(for: asrLanguageIDs) }
    static var asrNvidiaNemotronTimeoutSeconds: TimeInterval {
        BridgeSettingsNormalization.clampedASRTimeoutSec(ud.double(forKey: Keys.asrNvidiaNemotronTimeoutSec))
    }
    static var asrTimeoutSeconds: TimeInterval {
        BridgeSettingsNormalization.clampedASRTimeoutSec(
            max(asrQwenLlamaTimeoutSeconds, asrNvidiaNemotronTimeoutSeconds)
        )
    }
    static func asrTimeoutSeconds(for sources: [RecognitionSource]) -> TimeInterval {
        _ = sources
        return asrTimeoutSeconds
    }
    static var asrNvidiaNemotronModelID: String {
        let raw = ud.string(forKey: Keys.asrNvidiaNemotronModelID) ?? NvidiaNemotronASRModelCatalog.defaultID
        return NvidiaNemotronASRModelCatalog.spec(for: raw).id
    }
    static func asrNvidiaNemotronPath(for file: NvidiaNemotronASRFileSpec) -> String {
        let value = ud.string(forKey: file.pathKey) ?? file.defaultPath
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? file.defaultPath : trimmed
    }
    static func asrNvidiaNemotronDownloadURL(for file: NvidiaNemotronASRFileSpec) -> String {
        ud.string(forKey: file.urlKey) ?? file.defaultURL
    }
    static var asrQwenLlamaTimeoutSeconds: TimeInterval {
        BridgeSettingsNormalization.clampedASRTimeoutSec(ud.double(forKey: Keys.asrQwenLlamaTimeoutSec))
    }
    static var asrQwenLlamaModelPath: String {
        let spec = QwenASRModelCatalog.spec(for: asrQwenLlamaModelID)
        let value = ud.string(forKey: spec.modelPathKey) ?? spec.defaultModelPath
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? spec.defaultModelPath : trimmed
    }
    static var asrQwenLlamaMMProjPath: String {
        let spec = QwenASRModelCatalog.spec(for: asrQwenLlamaModelID)
        let value = ud.string(forKey: spec.mmprojPathKey) ?? spec.defaultMMProjPath
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? spec.defaultMMProjPath : trimmed
    }
    static var asrQwenLlamaModelID: String {
        let raw = ud.string(forKey: Keys.asrQwenLlamaModelID) ?? QwenASRModelCatalog.defaultID
        return QwenASRModelCatalog.spec(for: raw).id
    }
    static var asrQwenLlamaMaxTokens: Int {
        min(max(128, ud.integer(forKey: Keys.asrQwenLlamaMaxTokens)), 8192)
    }
    static var asrQwenLlamaModelDownloadURL: String {
        let spec = QwenASRModelCatalog.spec(for: asrQwenLlamaModelID)
        return ud.string(forKey: spec.modelURLKey) ?? spec.defaultModelURL
    }
    static var asrQwenLlamaMMProjDownloadURL: String {
        let spec = QwenASRModelCatalog.spec(for: asrQwenLlamaModelID)
        return ud.string(forKey: spec.mmprojURLKey) ?? spec.defaultMMProjURL
    }

    static var correctionBackend: CorrectionBackendKind {
        rawSetting(forKey: Keys.correctionBackend, default: .qwen35_4B)
    }
    static var aiWritingBackend: AIWritingBackend {
        rawSetting(forKey: Keys.aiWritingBackend, default: .languageModel)
    }
    static var correctionTimeoutMs: Int     { max(100, ud.integer(forKey: Keys.correctionTimeoutMs)) }
    static var correctionColdTimeoutMs: Int { max(1000, ud.integer(forKey: Keys.correctionColdTimeoutMs)) }
    static var correctionMaxTokens: Int     { max(16, ud.integer(forKey: Keys.correctionMaxTokens)) }
    static var correctionContextSize: Int {
        normalizedCorrectionContextSize(ud.integer(forKey: Keys.correctionContextSize))
    }
    static func normalizedCorrectionContextSize(_ value: Int) -> Int {
        max(correctionContextSizeRange.lowerBound, value)
    }
    static var correctionMode: CorrectionMode {
        rawSetting(forKey: Keys.correctionMode, default: .polishPlus)
    }
    static var autoCommit: Bool         { ud.bool(forKey: Keys.correctionAutoCommit) }
    static var numberOutputPreference: NumberOutputPreference {
        NumberOutputPreference.normalized(ud.string(forKey: Keys.numberOutputPreference))
    }
    static var punctuationPreference: PunctuationOutputPreference {
        PunctuationOutputPreference.normalized(ud.string(forKey: Keys.punctuationPreference))
    }
    static var diagnosticsDebugCaptureLimit: Int {
        min(200, max(1, ud.integer(forKey: Keys.diagnosticsDebugCaptureLimit)))
    }
    static var setupGuideHasShown: Bool { ud.bool(forKey: Keys.setupGuideHasShown) }
    static var setupGuideCompleted: Bool { ud.bool(forKey: Keys.setupGuideCompleted) }
    static var shouldAutomaticallyShowSetupGuide: Bool {
        shouldShowSetupGuide(hasShown: setupGuideHasShown, completed: setupGuideCompleted)
    }
    static func shouldShowSetupGuide(hasShown: Bool, completed: Bool) -> Bool {
        !hasShown && !completed
    }
    static func setSetupGuideHasShown(_ shown: Bool) {
        ud.set(shown, forKey: Keys.setupGuideHasShown)
    }
    static func setSetupGuideCompleted(_ completed: Bool) {
        ud.set(completed, forKey: Keys.setupGuideCompleted)
    }
    static var llama2BPath: String        { ud.string(forKey: Keys.llama2BPath) ?? AppPaths.llama2BFile.path }
    static var llama4BPath: String        { ud.string(forKey: Keys.llama4BPath) ?? AppPaths.llama4BFile.path }
    static var llama9BPath: String        { ud.string(forKey: Keys.llama9BPath) ?? AppPaths.llama9BFile.path }
    static var llama2BDownloadURL: String { ud.string(forKey: Keys.llama2BDownloadURL) ?? "" }
    static var llama4BDownloadURL: String { ud.string(forKey: Keys.llama4BDownloadURL) ?? "" }
    static var llama9BDownloadURL: String { ud.string(forKey: Keys.llama9BDownloadURL) ?? "" }
    static var llamaUseFlashAttn: Bool  { ud.bool(forKey: Keys.llamaUseFlashAttn) }
    static var externalLLMBaseURL: String {
        let value = ud.string(forKey: Keys.externalLLMBaseURL) ?? "http://127.0.0.1:1234"
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "http://127.0.0.1:1234" : trimmed
    }
    static var externalLLMAPIKey: String {
        secureString(forKey: Keys.externalLLMAPIKey)
    }
    @discardableResult
    static func setExternalLLMAPIKey(_ value: String) throws -> String {
        try setSecureString(value, forKey: Keys.externalLLMAPIKey)
    }
    static var externalLLMModel: String {
        ud.string(forKey: Keys.externalLLMModel)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var promptOverrideFolder: URL {
        URL(fileURLWithPath: ud.string(forKey: Keys.promptOverrideFolder) ?? AppPaths.promptsDir.path)
    }

    static var processingMode: ProcessingMode {
        processingMode(in: ud)
    }

    static func setProcessingMode(_ target: ProcessingMode) {
        setProcessingMode(target, defaults: ud)
    }

    static func setProcessingMode(_ target: ProcessingMode, defaults: UserDefaults) {
        let current = processingMode(in: defaults)
        guard current != target else { return }

        saveScopedSettings(for: current, defaults: defaults)
        defaults.set(target.rawValue, forKey: Keys.processingMode)
        restoreScopedSettings(for: target, defaults: defaults)
        defaults.synchronize()
    }

    private static func processingMode(in defaults: UserDefaults) -> ProcessingMode {
        rawSetting(forKey: Keys.processingMode, default: .client, defaults: defaults)
    }

    private static func saveScopedSettings(for mode: ProcessingMode, defaults: UserDefaults) {
        let keys = scopedSettingKeys(for: mode)
        var snapshot: [String: Any] = [
            scopedSnapshotVersionKey: scopedSnapshotVersion
        ]
        for key in keys {
            if let value = defaults.object(forKey: key) {
                snapshot[key] = value
            }
        }
        defaults.set(snapshot, forKey: snapshotKey(for: mode))
    }

    private static func restoreScopedSettings(for mode: ProcessingMode, defaults: UserDefaults) {
        guard let snapshot = defaults.dictionary(forKey: snapshotKey(for: mode)) else { return }
        let version = snapshot[scopedSnapshotVersionKey] as? Int ?? 0
        guard version <= scopedSnapshotVersion else { return }
        for key in scopedSettingKeys(for: mode) {
            if let value = snapshot[key] {
                defaults.set(value, forKey: key)
            }
        }
    }

    private static func scopedSettingKeys(for mode: ProcessingMode) -> [String] {
        switch mode {
        case .server: return serverScopedSettingKeys
        case .client: return clientScopedSettingKeys
        }
    }

    private static func snapshotKey(for mode: ProcessingMode) -> String {
        switch mode {
        case .server: return Keys.serverSettingsSnapshot
        case .client: return Keys.clientSettingsSnapshot
        }
    }

    private static let scopedSnapshotVersion = 1
    private static let scopedSnapshotVersionKey = "__typeforme_snapshot_version"

    static var clientLocalBridgeURLsRaw: String {
        ud.string(forKey: Keys.clientLocalBridgeURLs) ?? ""
    }
    static var clientLocalBridgeURLs: [String] {
        ClientBridgeConfiguration.uniqueBridgeURLs(
            clientLocalBridgeURLsRaw
                .components(separatedBy: CharacterSet(charactersIn: "\n,"))
        )
    }
    static var clientCloudBridgeURL: String {
        ud.string(forKey: Keys.clientCloudBridgeURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static var clientBridgeToken: String {
        secureString(forKey: Keys.clientBridgeToken)
    }
    @discardableResult
    static func setClientBridgeToken(_ value: String) throws -> String {
        let persisted = try setSecureString(value, forKey: Keys.clientBridgeToken)
        setClientSettingsRevision(nil)
        NotificationCenter.default.post(name: .clientBridgeConfigurationDidChange, object: nil)
        return persisted
    }
    static var clientSettingsRevision: String {
        ud.string(forKey: Keys.clientSettingsRevision)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static func setClientSettingsRevision(_ revision: String?) {
        let trimmed = revision?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            ud.removeObject(forKey: Keys.clientSettingsRevision)
        } else {
            ud.set(trimmed, forKey: Keys.clientSettingsRevision)
        }
    }
    static var clientIdentityID: String {
        ensureClientIdentityID()
    }
    static var clientLanguageIDs: [String] {
        ASRLanguageSelection.parse(
            ud.string(forKey: Keys.clientLanguageIDs) ?? ASRLanguageSelection.defaultRawValue
        )
    }

    static var activeLanguageIDs: [String] {
        processingMode == .client ? clientLanguageIDs : asrLanguageIDs
    }

    static var bridgeEnabled: Bool    { ud.bool(forKey: Keys.bridgeEnabled) }
    static var bridgeLANEnabled: Bool { ud.bool(forKey: Keys.bridgeLANEnabled) }
    static var bridgeLANAdapter: String {
        let value = ud.string(forKey: Keys.bridgeLANAdapter)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "all"
        return value.isEmpty ? "all" : value
    }
    static var bridgePublicEnabled: Bool { ud.bool(forKey: Keys.bridgePublicEnabled) }
    static var bridgePort: Int        { max(1024, ud.integer(forKey: Keys.bridgePort)) }
    static var bridgeHostname: String {
        ud.string(forKey: Keys.bridgeHostname) ?? ""
    }
    static var diagnosticsDebugMode: Bool {
        ud.bool(forKey: Keys.diagnosticsDebugMode)
    }
    static var bridgeAuthToken: String? {
        try? ensureBridgeAuthToken()
    }

    @discardableResult
    static func ensureBridgeAuthToken() throws -> String {
        bridgeAuthTokenLock.lock()
        defer { bridgeAuthTokenLock.unlock() }
        return try secureSetting(forKey: Keys.bridgeAuthToken).ensure(generating: newBridgeAuthToken)
    }

    @discardableResult
    static func rotateBridgeAuthToken() throws -> String {
        bridgeAuthTokenLock.lock()
        defer { bridgeAuthTokenLock.unlock() }
        return try secureSetting(forKey: Keys.bridgeAuthToken).replace(with: newBridgeAuthToken())
    }

    private static func newBridgeAuthToken() -> String {
        newLocalToken()
    }

    @discardableResult
    static func ensureClientIdentityID() -> String {
        cachedClientIdentityID.withLock { cachedIdentityID in
            if let cached = cleanClientIdentityID(cachedIdentityID) {
                return cached
            }
            if let existing = cleanClientIdentityID(ud.string(forKey: Keys.clientIdentityID)) {
                cachedIdentityID = existing
                return existing
            }
            let identity = "mac-\(UUID().uuidString.lowercased())"
            ud.set(identity, forKey: Keys.clientIdentityID)
            cachedIdentityID = identity
            return identity
        }
    }

    private static func cleanClientIdentityID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func newLocalToken() -> String {
        [UUID().uuidString, UUID().uuidString]
            .joined(separator: "")
            .replacingOccurrences(of: "-", with: "")
    }
}
