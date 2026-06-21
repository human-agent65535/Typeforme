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
            return "No live transcript is shown while recording."
        case .nvidiaNemotron:
            return "Streams recorder audio through the selected local Nemotron 3.5 model. Final inserted text still comes from the selected ASR and correction pipeline."
        case .appleSpeech:
            return "Uses Apple's on-device recognizer when the current language is supported and speech recognition permission is granted. Final inserted text still comes from the selected ASR and correction pipeline."
        }
    }

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
}
