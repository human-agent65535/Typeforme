import AVFoundation
import Foundation
import Testing
@testable import Typeforme

@Suite("BridgeAudioFormat")
struct BridgeAudioFormatTests {
    @Test func bridgeFormatContractListsCurrentUploadExtensions() {
        #expect(BridgeAudioFormat.allowedExtensions == ["flac"])
        #expect(BridgeAudioFormat.isAllowedExtension("flac"))
        #expect(BridgeAudioFormat.isAllowedExtension("FLAC"))
        #expect(!BridgeAudioFormat.isAllowedExtension("caf"))
        #expect(!BridgeAudioFormat.isAllowedExtension("m4a"))
        #expect(!BridgeAudioFormat.isAllowedExtension("aac"))
        #expect(!BridgeAudioFormat.isAllowedExtension("wav"))
        #expect(BridgeAudioFormat.normalizedExtension(" FLAC ") == "flac")
        #expect(BridgeAudioFormat.normalizedExtension("caf") == nil)
    }

    @Test func bridgeFormatContractMapsMimeTypes() {
        #expect(BridgeAudioFormat.mimeType(forExtension: "flac") == "audio/flac")
        #expect(BridgeAudioFormat.mimeType(forExtension: "caf") == "application/octet-stream")
        #expect(BridgeAudioFormat.mimeType(forExtension: "m4a") == "application/octet-stream")
        #expect(BridgeAudioFormat.mimeType(forExtension: "wav") == "application/octet-stream")
    }

    @Test func recordingContractMatchesCurrentBridgeUploadBehavior() {
        #expect(BridgeAudioRecordingContract.sampleRate == 16_000)
        #expect(BridgeAudioRecordingContract.channelCount == 1)
        #expect(BridgeAudioRecordingContract.flacBitDepth == 16)
        #expect(BridgeAudioRecordingContract.minimumDurationSeconds == 0.35)
        #expect(BridgeAudioRecordingContract.stopTailBufferNanoseconds == 200_000_000)
    }

    @Test func bridgeFormatRecognizesFLACMagic() {
        #expect(BridgeAudioFormat.hasFLACMagic(Data("fLaCAUDIOBYTES".utf8)))
        #expect(!BridgeAudioFormat.hasFLACMagic(Data("AUDIOBYTES".utf8)))
    }

    @Test func bridgeFormatRecognizesNativeFLACFile() throws {
        let url = try TestAudioFixtures.makeFLACFile()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(BridgeAudioFormat.fileHasFLACMagic(url))
        #expect(BridgeAudioFormat.isFLACFile(url))
    }

    @Test func bridgeFormatRejectsFloat32SourceFLACFile() throws {
        let url = try makeFloat32SourceFLACFile()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(BridgeAudioFormat.fileHasFLACMagic(url))
        #expect(!BridgeAudioFormat.isFLACFile(url))
    }

    @Test func bridgeFormatRejectsFakeFLACFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-test-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("fLaCAUDIOBYTES".utf8).write(to: url)

        #expect(BridgeAudioFormat.fileHasFLACMagic(url))
        #expect(!BridgeAudioFormat.isFLACFile(url))
    }

    private func makeFloat32SourceFLACFile(frameCount: AVAudioFrameCount = 16_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-test-\(UUID().uuidString).flac")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatFLAC),
            AVSampleRateKey: BridgeAudioRecordingContract.sampleRate,
            AVNumberOfChannelsKey: BridgeAudioRecordingContract.channelCount,
            AVEncoderBitDepthHintKey: BridgeAudioRecordingContract.flacBitDepth,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ), let channel = buffer.floatChannelData?[0] else {
            throw NSError(
                domain: "TypeformeTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create Float32 FLAC fixture buffer"]
            )
        }
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            channel[frame] = frame.isMultiple(of: 2) ? 0.01 : -0.01
        }
        try file.write(from: buffer)
        return url
    }
}
