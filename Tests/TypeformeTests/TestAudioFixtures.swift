import AVFoundation
import Foundation
@testable import Typeforme

enum TestAudioFixtures {
    static func makeOpusCAFFile(frameCount: AVAudioFrameCount = 16_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-test-\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatOpus),
            AVSampleRateKey: BridgeAudioRecordingContract.sampleRate,
            AVNumberOfChannelsKey: BridgeAudioRecordingContract.channelCount,
            AVEncoderBitRateKey: BridgeAudioRecordingContract.opusBitRate,
        ]

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frameCount
            ) else {
                throw NSError(
                    domain: "TypeformeTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not create Opus CAF fixture buffer"]
                )
            }
            buffer.frameLength = frameCount
            if let channel = buffer.floatChannelData?[0] {
                for frame in 0..<Int(frameCount) {
                    channel[frame] = frame.isMultiple(of: 2) ? 0.01 : -0.01
                }
            }
            try file.write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        return url
    }

    static func makeOpusCAFData(frameCount: AVAudioFrameCount = 16_000) throws -> Data {
        let url = try makeOpusCAFFile(frameCount: frameCount)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }
}
