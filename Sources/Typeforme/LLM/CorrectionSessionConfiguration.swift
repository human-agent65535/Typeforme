import Foundation

/// Immutable inputs used to create one correction backend. Capturing this
/// value separates a recording from later Settings changes without changing
/// where those settings come from or how an external endpoint is validated.
enum CorrectorConfigurationSnapshot: Sendable, Equatable {
    case embedded(EmbeddedCorrectorConfiguration)
    case external(ExternalCompatibleCorrectorConfiguration)

    var kind: CorrectionBackendKind {
        switch self {
        case .embedded(let configuration):
            return configuration.kind
        case .external(let configuration):
            return configuration.kind
        }
    }

    @MainActor
    static func capture() -> CorrectorConfigurationSnapshot {
        let kind = AppSettings.correctionBackend
        switch kind {
        case .qwen35_2B, .qwen35_4B, .qwen35_9B:
            let modelPath: String
            switch kind {
            case .qwen35_2B:
                modelPath = AppSettings.llama2BPath
            case .qwen35_4B:
                modelPath = AppSettings.llama4BPath
            case .qwen35_9B:
                modelPath = AppSettings.llama9BPath
            case .externalOpenAICompatible, .externalAnthropicCompatible:
                preconditionFailure("External backend cannot use an embedded model")
            }
            return .embedded(EmbeddedCorrectorConfiguration(
                kind: kind,
                modelPath: modelPath,
                contextSize: AppSettings.correctionContextSize,
                maxTokens: AppSettings.correctionMaxTokens,
                useFlashAttention: AppSettings.llamaUseFlashAttn,
                coldTimeoutMilliseconds: AppSettings.correctionColdTimeoutMs
            ))
        case .externalOpenAICompatible, .externalAnthropicCompatible:
            return .external(ExternalCompatibleCorrectorConfiguration(
                kind: kind,
                baseURL: AppSettings.externalLLMBaseURL,
                model: AppSettings.externalLLMModel,
                apiKey: AppSettings.externalLLMAPIKey,
                maxTokens: AppSettings.correctionMaxTokens
            ))
        }
    }
}

struct EmbeddedCorrectorConfiguration: Sendable, Equatable {
    let kind: CorrectionBackendKind
    let modelPath: String
    let contextSize: Int
    let maxTokens: Int
    let useFlashAttention: Bool
    let coldTimeoutMilliseconds: Int
}

struct ExternalCompatibleCorrectorConfiguration: Sendable, Equatable {
    let kind: CorrectionBackendKind
    /// The configured endpoint authority. Completion-path normalization and
    /// HTTP/HTTPS validation remain owned by ExternalCompatibleCorrectorService.
    let baseURL: String
    let model: String
    let apiKey: String
    let maxTokens: Int
}

/// The complete immutable correction dependency set for one recording or
/// Bridge request. The corrector itself has already captured its backend
/// configuration when this value is created.
struct CorrectionSessionConfiguration: Sendable {
    let corrector: CorrectorService
    let numberOutputPreference: NumberOutputPreference
    let punctuationPreference: PunctuationOutputPreference
    let timeoutMs: Int
    let userDictionary: [DictionaryEntry]

    @MainActor
    static func capture(
        factory: CorrectorFactory = .shared,
        userDictionary: [DictionaryEntry]
    ) -> CorrectionSessionConfiguration {
        let correctorConfiguration = CorrectorConfigurationSnapshot.capture()
        return CorrectionSessionConfiguration(
            corrector: factory.make(configuration: correctorConfiguration),
            numberOutputPreference: AppSettings.numberOutputPreference,
            punctuationPreference: AppSettings.punctuationPreference,
            timeoutMs: AppSettings.correctionTimeoutMs,
            userDictionary: userDictionary
        )
    }
}
