import Foundation

enum VoiceLivePreviewSource: String, CaseIterable, Identifiable {
    case off
    case nvidiaNemotron = "nvidia-nemotron"
    case appleSpeech = "apple-speech"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
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
        case .nvidiaNemotron:
            return "Shows interim text from Nemotron."
        case .appleSpeech:
            return "Shows interim text from Apple Speech."
        }
    }

    static let pickerOptions: [VoiceLivePreviewSource] = [
        .off,
        .nvidiaNemotron,
        .appleSpeech,
    ]

    static func options(forRecognitionSources sources: [RecognitionSource]) -> [VoiceLivePreviewSource] {
        var options: [VoiceLivePreviewSource] = [.off]
        if sources.contains(.nvidiaNemotron) {
            options.append(.nvidiaNemotron)
        }
        if sources.contains(.appleSpeech) {
            options.append(.appleSpeech)
        }
        return options
    }

    func isEnabled(forRecognitionSources sources: [RecognitionSource]) -> Bool {
        Self.options(forRecognitionSources: sources).contains(self)
    }
}
