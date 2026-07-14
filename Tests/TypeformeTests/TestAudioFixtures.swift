import AVFoundation
import Foundation
@testable import Typeforme

enum TestAudioFixtures {
    static func makeWAVFile(frameCount: AVAudioFrameCount = 16_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-test-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: BridgeAudioRecordingContract.sampleRate,
            AVNumberOfChannelsKey: BridgeAudioRecordingContract.channelCount,
            AVLinearPCMBitDepthKey: BridgeAudioRecordingContract.flacBitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frameCount
            ) else {
                throw NSError(
                    domain: "typeforme.tests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Could not create WAV fixture buffer"]
                )
            }
            buffer.frameLength = frameCount
            if let channel = buffer.int16ChannelData?[0] {
                for frame in 0..<Int(frameCount) {
                    channel[frame] = frame.isMultiple(of: 2) ? 400 : -400
                }
            }
            try file.write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        return url
    }

    static func makeFLACFile(frameCount: AVAudioFrameCount = 16_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-test-\(UUID().uuidString).flac")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatFLAC),
            AVSampleRateKey: BridgeAudioRecordingContract.sampleRate,
            AVNumberOfChannelsKey: BridgeAudioRecordingContract.channelCount,
            AVEncoderBitDepthHintKey: BridgeAudioRecordingContract.flacBitDepth,
            AVLinearPCMBitDepthKey: BridgeAudioRecordingContract.flacBitDepth,
        ]

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frameCount
            ) else {
                throw NSError(
                    domain: "TypeformeTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not create FLAC fixture buffer"]
                )
            }
            buffer.frameLength = frameCount
            if let channel = buffer.int16ChannelData?[0] {
                for frame in 0..<Int(frameCount) {
                    channel[frame] = frame.isMultiple(of: 2) ? 400 : -400
                }
            }
            try file.write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        return url
    }

    static func makeFLACData(frameCount: AVAudioFrameCount = 16_000) throws -> Data {
        let url = try makeFLACFile(frameCount: frameCount)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }
}
