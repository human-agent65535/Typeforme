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

    @Test func fastModeDoesNotHideConfiguredPreviewSources() {
        #expect(
            VoiceLivePreviewSource.options(
                forRecognitionSources: [.qwen, .nvidiaNemotron, .appleSpeech],
                correctionMode: .fast
            ) == [.off, .qwen, .nvidiaNemotron, .appleSpeech]
        )
        #expect(VoiceLivePreviewSource.qwen.isEnabled(
            forRecognitionSources: [.qwen],
            correctionMode: .fast
        ))
        #expect(VoiceLivePreviewSource.appleSpeech.isEnabled(
            forRecognitionSources: [.appleSpeech],
            correctionMode: .fast
        ))
        #expect(VoiceLivePreviewSource.nvidiaNemotron.isEnabled(
            forRecognitionSources: [.nvidiaNemotron],
            correctionMode: .fast
        ))
    }

    @Test func fastModeWithoutQwenStillOffersAppleAndNemotronPreviewSettings() {
        #expect(
            VoiceLivePreviewSource.options(
                forRecognitionSources: [.nvidiaNemotron, .appleSpeech],
                correctionMode: .fast
            ) == [.off, .nvidiaNemotron, .appleSpeech]
        )
        #expect(VoiceLivePreviewSource.appleSpeech.isEnabled(
            forRecognitionSources: [.appleSpeech],
            correctionMode: .fast
        ))
        #expect(VoiceLivePreviewSource.nvidiaNemotron.isEnabled(
            forRecognitionSources: [.nvidiaNemotron],
            correctionMode: .fast
        ))
    }

    @Test func clientPreviewUsesRemoteServerSourcesOnly() {
        #expect(
            VoiceLivePreviewSource.clientOptions(
                forRemoteRecognitionSources: [],
                correctionMode: .polishPlus
            ) == [.off]
        )
        #expect(
            VoiceLivePreviewSource.clientOptions(
                forRemoteRecognitionSources: [.qwen, .nvidiaNemotron],
                correctionMode: .polishPlus
            ) == [.off, .qwen, .nvidiaNemotron]
        )
        #expect(
            VoiceLivePreviewSource.clientOptions(
                forRemoteRecognitionSources: [.nvidiaNemotron],
                correctionMode: .fast
            ) == [.off, .nvidiaNemotron]
        )
        #expect(!VoiceLivePreviewSource.appleSpeech.isClientEnabled(
            forRemoteRecognitionSources: [],
            correctionMode: .polishPlus
        ))
        #expect(VoiceLivePreviewSource.appleSpeech.isClientEnabled(
            forRemoteRecognitionSources: [.appleSpeech],
            correctionMode: .fast
        ))
    }

    @Test func bridgeFastPreviewDoesNotRewriteConfiguredSource() {
        #expect(BridgeSettingsPayload.bridgeLivePreviewSource(
            configuredSource: .appleSpeech,
            sources: [.qwen, .appleSpeech],
            correctionMode: .fast
        ) == .appleSpeech)
        #expect(BridgeSettingsPayload.bridgeLivePreviewSource(
            configuredSource: .off,
            sources: [.qwen],
            correctionMode: .fast
        ) == .off)
        #expect(BridgeSettingsPayload.bridgeLivePreviewSource(
            configuredSource: .appleSpeech,
            sources: [.appleSpeech],
            correctionMode: .fast
        ) == .appleSpeech)
        #expect(BridgeSettingsPayload.bridgeLivePreviewSource(
            configuredSource: .appleSpeech,
            sources: [.qwen, .appleSpeech],
            correctionMode: .polishPlus
        ) == .appleSpeech)
    }
}
