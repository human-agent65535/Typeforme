import Foundation
import Testing
@testable import Typeforme

@Suite("QwenLivePreviewSession")
struct QwenLivePreviewSessionTests {
    @Test func previewRequestWaitsForMinimumAudioAndStride() {
        #expect(!QwenLlamaLivePreviewSession.shouldRequestPreview(
            totalSamples: 19_199,
            lastRequestedSamples: 0
        ))
        #expect(QwenLlamaLivePreviewSession.shouldRequestPreview(
            totalSamples: 19_200,
            lastRequestedSamples: 0
        ))
        #expect(!QwenLlamaLivePreviewSession.shouldRequestPreview(
            totalSamples: 35_000,
            lastRequestedSamples: 20_000
        ))
        #expect(QwenLlamaLivePreviewSession.shouldRequestPreview(
            totalSamples: 36_000,
            lastRequestedSamples: 20_000
        ))
    }

    @Test func silentPCMDoesNotPassAudiblePreviewGate() {
        let silence = Data(count: 16_000 * MemoryLayout<Float>.size)

        #expect(!QwenLlamaLivePreviewSession.hasAudiblePreviewSignal(silence))
    }

    @Test func audiblePCMPassesPreviewGate() {
        let speechLikeAudio = float32PCMData(repeating: 0.02, sampleCount: 16_000)

        #expect(QwenLlamaLivePreviewSession.hasAudiblePreviewSignal(speechLikeAudio))
    }

    private func float32PCMData(repeating value: Float, sampleCount: Int) -> Data {
        var data = Data(count: sampleCount * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { rawBuffer in
            let output = rawBuffer.bindMemory(to: UInt32.self)
            let word = value.bitPattern.littleEndian
            for index in 0..<sampleCount {
                output[index] = word
            }
        }
        return data
    }
}
