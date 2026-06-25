import Foundation
import Testing
@testable import Typeforme

@Suite("BridgeAudioFormat")
struct BridgeAudioFormatTests {
    @Test func bridgeFormatContractListsCurrentUploadExtensions() {
        #expect(BridgeAudioFormat.allowedExtensions == ["caf"])
        #expect(BridgeAudioFormat.isAllowedExtension("caf"))
        #expect(BridgeAudioFormat.isAllowedExtension("CAF"))
        #expect(!BridgeAudioFormat.isAllowedExtension("flac"))
        #expect(!BridgeAudioFormat.isAllowedExtension("m4a"))
        #expect(!BridgeAudioFormat.isAllowedExtension("aac"))
        #expect(!BridgeAudioFormat.isAllowedExtension("wav"))
        #expect(BridgeAudioFormat.normalizedExtension(" CAF ") == "caf")
        #expect(BridgeAudioFormat.normalizedExtension("flac") == nil)
    }

    @Test func bridgeFormatContractMapsMimeTypes() {
        #expect(BridgeAudioFormat.mimeType(forExtension: "caf") == "audio/x-caf")
        #expect(BridgeAudioFormat.mimeType(forExtension: "flac") == "application/octet-stream")
        #expect(BridgeAudioFormat.mimeType(forExtension: "m4a") == "application/octet-stream")
        #expect(BridgeAudioFormat.mimeType(forExtension: "wav") == "application/octet-stream")
    }

    @Test func recordingContractMatchesCurrentBridgeUploadBehavior() {
        #expect(BridgeAudioRecordingContract.sampleRate == 16_000)
        #expect(BridgeAudioRecordingContract.channelCount == 1)
        #expect(BridgeAudioRecordingContract.opusBitRate == 24_000)
        #expect(BridgeAudioRecordingContract.minimumDurationSeconds == 0.35)
        #expect(BridgeAudioRecordingContract.stopTailBufferNanoseconds == 200_000_000)
    }

    @Test func bridgeFormatRecognizesCAFMagic() {
        #expect(BridgeAudioFormat.hasCAFMagic(Data("caffAUDIOBYTES".utf8)))
        #expect(!BridgeAudioFormat.hasCAFMagic(Data("AUDIOBYTES".utf8)))
    }

    @Test func bridgeFormatRecognizesNativeOpusCAFFile() throws {
        let url = try TestAudioFixtures.makeOpusCAFFile()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(BridgeAudioFormat.fileHasCAFMagic(url))
        #expect(BridgeAudioFormat.isOpusCAFFile(url))
    }

    @Test func bridgeFormatRejectsFakeCAFFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-test-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("caffAUDIOBYTES".utf8).write(to: url)

        #expect(BridgeAudioFormat.fileHasCAFMagic(url))
        #expect(!BridgeAudioFormat.isOpusCAFFile(url))
    }
}
