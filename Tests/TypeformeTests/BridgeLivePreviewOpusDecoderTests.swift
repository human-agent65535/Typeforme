import AVFoundation
import Foundation
import Testing
@testable import Typeforme

@Suite("BridgeLivePreviewOpusDecoder")
struct BridgeLivePreviewOpusDecoderTests {
    @Test func decoderConvertsOpusPacketToPCM() throws {
        let packet = try Self.makeOpusPacket()
        let decoder = BridgeLivePreviewOpusDecoder()

        let pcm = try decoder.decode(packet: packet)

        #expect(!pcm.isEmpty)
        #expect(pcm.count % MemoryLayout<Float>.size == 0)
        #expect((pcm.count / MemoryLayout<Float>.size) > 0)
    }

    @Test func decoderRejectsEmptyPacket() {
        let decoder = BridgeLivePreviewOpusDecoder()

        #expect(throws: BridgeLivePreviewOpusDecoderError.self) {
            try decoder.decode(packet: Data())
        }
    }

    @Test func decoderRejectsOversizedPacket() {
        let decoder = BridgeLivePreviewOpusDecoder()

        #expect(throws: BridgeLivePreviewOpusDecoderError.self) {
            try decoder.decode(packet: Data(repeating: 0x7F, count: BridgeLivePreviewOpusDecoder.maxPacketBytes + 1))
        }
    }

    @Test func decoderRejectsNon20msPacketShape() {
        let decoder = BridgeLivePreviewOpusDecoder()

        #expect(throws: BridgeLivePreviewOpusDecoderError.self) {
            try decoder.decode(packet: Data([0x10]))
        }
    }

    @Test func decoderRejectsLegacyFloat32PCMFrame() {
        let decoder = BridgeLivePreviewOpusDecoder()
        var pcmFrame = Data()
        for index in 0..<320 {
            var bits = (sinf(Float(index) * 0.05) * 0.1).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { pcmFrame.append(contentsOf: $0) }
        }

        #expect(pcmFrame.count == 320 * MemoryLayout<Float>.size)
        #expect(throws: BridgeLivePreviewOpusDecoderError.self) {
            try decoder.decode(packet: pcmFrame)
        }
    }

    private static func makeOpusPacket() throws -> Data {
        let pcmFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let opusFormat = try #require(AVAudioFormat(settings: [
            AVFormatIDKey: Int(kAudioFormatOpus),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24_000,
        ]))
        let input = try #require(AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: 320
        ))
        input.frameLength = 320
        let channel = try #require(input.floatChannelData?[0])
        for index in 0..<320 {
            channel[index] = sinf(Float(index) * 0.05) * 0.1
        }
        let converter = try #require(AVAudioConverter(from: pcmFormat, to: opusFormat))
        let output = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: 4_096
        )
        let inputSource = OpusEncoderTestInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            inputSource.next(outStatus)
        }
        if let conversionError {
            throw conversionError
        }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            break
        case .error:
            throw BridgeLivePreviewOpusDecoderError.decodeFailed("test encoder returned error")
        @unknown default:
            break
        }
        let byteCount = Int(output.packetDescriptions?.pointee.mDataByteSize ?? output.byteLength)
        let offset = Int(output.packetDescriptions?.pointee.mStartOffset ?? 0)
        return Data(bytes: output.data.advanced(by: offset), count: byteCount)
    }
}

private final class OpusEncoderTestInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !supplied else {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}
