import Testing
@testable import Typeforme

@Suite("BridgeAudioFormat")
struct BridgeAudioFormatTests {
    @Test func bridgeFormatContractListsCurrentUploadExtensions() {
        #expect(BridgeAudioFormat.allowedExtensions == ["m4a", "aac"])
        #expect(BridgeAudioFormat.isAllowedExtension("m4a"))
        #expect(BridgeAudioFormat.isAllowedExtension("AAC"))
        #expect(!BridgeAudioFormat.isAllowedExtension("wav"))
        #expect(BridgeAudioFormat.normalizedExtension(" M4A ") == "m4a")
        #expect(BridgeAudioFormat.normalizedExtension("m-4a") == nil)
    }

    @Test func bridgeFormatContractMapsMimeTypes() {
        #expect(BridgeAudioFormat.mimeType(forExtension: "m4a") == "audio/mp4")
        #expect(BridgeAudioFormat.mimeType(forExtension: "aac") == "audio/mp4")
        #expect(BridgeAudioFormat.mimeType(forExtension: "wav") == "application/octet-stream")
    }

    @Test func recordingContractMatchesCurrentBridgeUploadBehavior() {
        #expect(BridgeAudioRecordingContract.minimumDurationSeconds == 0.35)
        #expect(BridgeAudioRecordingContract.stopTailBufferNanoseconds == 200_000_000)
        #expect(BridgeAudioRecordingContract.aacBitRate == 64_000)
    }
}
