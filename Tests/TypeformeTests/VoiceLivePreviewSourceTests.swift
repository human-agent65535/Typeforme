import Testing
@testable import Typeforme

@Suite("VoiceLivePreviewSource")
struct VoiceLivePreviewSourceTests {
    @Test func pickerShowsAllPreviewCapabilities() {
        #expect(VoiceLivePreviewSource.pickerOptions == [
            .off,
            .qwen,
            .nvidiaNemotron,
            .appleSpeech,
        ])
        #expect(VoiceLivePreviewSource.qwen.isEnabled(forRecognitionSources: [.qwen]))
        #expect(!VoiceLivePreviewSource.appleSpeech.isEnabled(forRecognitionSources: [.qwen]))
        #expect(VoiceLivePreviewSource.appleSpeech.isEnabled(forRecognitionSources: [.appleSpeech]))
    }

    @Test func qwenAndAppleSpeechOfferQwenAndAppleSpeech() {
        #expect(
            VoiceLivePreviewSource.options(forRecognitionSources: [.qwen, .appleSpeech]) == [
                .off,
                .qwen,
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
                .qwen,
                .nvidiaNemotron,
                .appleSpeech,
            ]
        )
    }

    @Test func fastModeOnlyOffersQwenPreview() {
        #expect(
            VoiceLivePreviewSource.options(
                forRecognitionSources: [.qwen, .nvidiaNemotron, .appleSpeech],
                correctionMode: .fast
            ) == [.off, .qwen]
        )
        #expect(VoiceLivePreviewSource.qwen.isEnabled(
            forRecognitionSources: [.qwen],
            correctionMode: .fast
        ))
        #expect(!VoiceLivePreviewSource.appleSpeech.isEnabled(
            forRecognitionSources: [.appleSpeech],
            correctionMode: .fast
        ))
        #expect(!VoiceLivePreviewSource.nvidiaNemotron.isEnabled(
            forRecognitionSources: [.nvidiaNemotron],
            correctionMode: .fast
        ))
    }

    @Test func fastModeWithoutQwenOnlyOffersOff() {
        #expect(
            VoiceLivePreviewSource.options(
                forRecognitionSources: [.nvidiaNemotron, .appleSpeech],
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
