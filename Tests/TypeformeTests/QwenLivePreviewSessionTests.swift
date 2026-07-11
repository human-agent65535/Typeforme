import Foundation
import Testing
@testable import Typeforme

@Suite("QwenLivePreviewSession")
struct QwenLivePreviewSessionTests {
    @Test func previewRequestWaitsForMinimumAudioAndStride() {
        #expect(!QwenLlamaLivePreviewSession.shouldRequestPreview(
            totalSamples: 15_999,
            lastRequestedSamples: 0,
            hasAudibleAudio: true
        ))
        #expect(QwenLlamaLivePreviewSession.shouldRequestPreview(
            totalSamples: 16_000,
            lastRequestedSamples: 0,
            hasAudibleAudio: true
        ))
        #expect(!QwenLlamaLivePreviewSession.shouldRequestPreview(
            totalSamples: 35_000,
            lastRequestedSamples: 20_000,
            hasAudibleAudio: true
        ))
        #expect(QwenLlamaLivePreviewSession.shouldRequestPreview(
            totalSamples: 36_000,
            lastRequestedSamples: 20_000,
            hasAudibleAudio: true
        ))
        #expect(!QwenLlamaLivePreviewSession.shouldRequestPreview(
            totalSamples: 36_000,
            lastRequestedSamples: 20_000,
            hasAudibleAudio: false
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

    @Test func canonicalFinalRequiresNonEmptyFullResult() {
        #expect(!QwenLlamaLivePreviewSession.hasUsableCanonicalFinal(""))
        #expect(!QwenLlamaLivePreviewSession.hasUsableCanonicalFinal(" \n\t "))
        #expect(QwenLlamaLivePreviewSession.hasUsableCanonicalFinal("complete recording"))
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
