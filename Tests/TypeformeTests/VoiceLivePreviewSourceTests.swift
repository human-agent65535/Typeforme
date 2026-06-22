import Testing
@testable import Typeforme

@Suite("VoiceLivePreviewSource")
struct VoiceLivePreviewSourceTests {
    @Test func pickerShowsAllPreviewCapabilities() {
        #expect(VoiceLivePreviewSource.pickerOptions == [
            .off,
            .nvidiaNemotron,
            .appleSpeech,
        ])
        #expect(!VoiceLivePreviewSource.appleSpeech.isEnabled(forRecognitionSources: [.qwen]))
        #expect(VoiceLivePreviewSource.appleSpeech.isEnabled(forRecognitionSources: [.appleSpeech]))
    }

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
