import Testing
@testable import Typeforme

@Suite("VoiceLivePreviewSource")
struct VoiceLivePreviewSourceTests {
    @Test func qwenOnlyOffersOffAndAppleSpeech() {
        #expect(
            VoiceLivePreviewSource.options(forRecognitionSources: [.qwen, .appleSpeech]) == [
                .off,
                .appleSpeech,
            ]
        )
    }

    @Test func nemotronProvidersOfferNemotronPreview() {
        #expect(
            VoiceLivePreviewSource.options(forRecognitionSources: [.nvidiaNemotron]) == [
                .off,
                .nvidiaNemotron,
            ]
        )
        #expect(
            VoiceLivePreviewSource.options(forRecognitionSources: [.qwen, .nvidiaNemotron, .appleSpeech]) == [
                .off,
                .nvidiaNemotron,
                .appleSpeech,
            ]
        )
    }
}
