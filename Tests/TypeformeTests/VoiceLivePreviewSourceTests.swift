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

    @Test func qwenAndAppleSpeechOfferOffAndAppleSpeech() {
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

    @Test func fastModeDisablesPreviewSources() {
        #expect(
            VoiceLivePreviewSource.options(
                forRecognitionSources: [.qwen, .nvidiaNemotron, .appleSpeech],
                correctionMode: .fast
            ) == [.off]
        )
        #expect(!VoiceLivePreviewSource.appleSpeech.isEnabled(
            forRecognitionSources: [.appleSpeech],
            correctionMode: .fast
        ))
        #expect(!VoiceLivePreviewSource.nvidiaNemotron.isEnabled(
            forRecognitionSources: [.nvidiaNemotron],
            correctionMode: .fast
        ))
    }
}
