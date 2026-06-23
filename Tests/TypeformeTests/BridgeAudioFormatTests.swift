import Testing
@testable import Typeforme

@Suite("BridgeAudioFormat")
struct BridgeAudioFormatTests {
    @Test func bridgeFormatContractListsCurrentUploadExtensions() {
        #expect(BridgeAudioFormat.defaultExtension == "m4a")
        #expect(BridgeAudioFormat.allowedExtensions == ["m4a", "aac"])
        #expect(BridgeAudioFormat.isAllowedExtension("m4a"))
        #expect(BridgeAudioFormat.isAllowedExtension("AAC"))
        #expect(!BridgeAudioFormat.isAllowedExtension("wav"))
    }

    @Test func bridgeFormatContractMapsMimeTypes() {
        #expect(BridgeAudioFormat.mimeType(forExtension: "m4a") == "audio/mp4")
        #expect(BridgeAudioFormat.mimeType(forExtension: "aac") == "audio/mp4")
        #expect(BridgeAudioFormat.mimeType(forExtension: "wav") == "application/octet-stream")
    }
}
