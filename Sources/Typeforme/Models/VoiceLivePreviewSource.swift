import Foundation

enum VoiceLivePreviewSource: String, CaseIterable, Identifiable {
    case off
    case qwen = "qwen3-asr-llama"
    case nvidiaNemotron = "nvidia-nemotron"
    case appleSpeech = "apple-speech"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .qwen:
            return "Qwen3-ASR"
        case .nvidiaNemotron:
            return "NVIDIA Nemotron 3.5"
        case .appleSpeech:
            return "Apple Speech"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "No live transcript while recording."
        case .qwen:
            return "Shows rolling-window preview from Qwen3-ASR."
        case .nvidiaNemotron:
            return "Shows interim text from Nemotron."
        case .appleSpeech:
            return "Shows interim text from Apple Speech."
        }
    }

    static let pickerOptions: [VoiceLivePreviewSource] = [
        .off,
        .qwen,
        .nvidiaNemotron,
        .appleSpeech,
    ]

    static func options(
        forRecognitionSources sources: [RecognitionSource],
        correctionMode: CorrectionMode = .polish
    ) -> [VoiceLivePreviewSource] {
        var options: [VoiceLivePreviewSource] = [.off]
        if sources.contains(.qwen) {
            options.append(.qwen)
        }
        guard correctionMode.usesRefine else { return options }
        if sources.contains(.nvidiaNemotron) {
            options.append(.nvidiaNemotron)
        }
        if sources.contains(.appleSpeech) {
            options.append(.appleSpeech)
        }
        return options
    }

    static func clientOptions(
        forRemoteRecognitionSources sources: [RecognitionSource],
        correctionMode: CorrectionMode = .polish
    ) -> [VoiceLivePreviewSource] {
        var options: [VoiceLivePreviewSource] = [.off]
        if sources.contains(.qwen) {
            options.append(.qwen)
        }
        guard correctionMode.usesRefine else { return options }
        if sources.contains(.nvidiaNemotron) {
            options.append(.nvidiaNemotron)
        }
        options.append(.appleSpeech)
        return options
    }

    func isEnabled(
        forRecognitionSources sources: [RecognitionSource],
        correctionMode: CorrectionMode = .polish
    ) -> Bool {
        Self.options(forRecognitionSources: sources, correctionMode: correctionMode).contains(self)
    }

    func isClientEnabled(
        forRemoteRecognitionSources sources: [RecognitionSource],
        correctionMode: CorrectionMode = .polish
    ) -> Bool {
        Self.clientOptions(forRemoteRecognitionSources: sources, correctionMode: correctionMode).contains(self)
    }
}
