import AVFoundation
import Foundation

enum BridgeLivePreviewOpusDecoderError: LocalizedError {
    case unavailable
    case invalidPacket
    case invalidFrameDuration(Int)
    case decodeFailed(String)
    case emptyPCM

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Opus live preview decoder is unavailable"
        case .invalidPacket:
            return "Opus live preview packet is invalid"
        case .invalidFrameDuration(let sampleCount):
            return "Opus live preview packet must decode to 320 samples; got \(sampleCount)"
        case .decodeFailed(let detail):
            return "Opus live preview decode failed: \(detail)"
        case .emptyPCM:
            return "Opus live preview decoder produced no PCM"
        }
    }
}

final class BridgeLivePreviewOpusDecoder: @unchecked Sendable {
    static let maxPacketBytes = 1_275

    private static let sampleRate = 16_000.0
    private static let channelCount: AVAudioChannelCount = 1
    private static let opusFrameSampleCount: UInt32 = 320
    private static let maxOutputFrames: AVAudioFrameCount = 960
    private static let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channelCount,
        interleaved: false
    )!
    private static let opusFormat = AVAudioFormat(settings: [
        AVFormatIDKey: Int(kAudioFormatOpus),
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: Int(channelCount),
    ])!

    private let converter: AVAudioConverter?

    init() {
        converter = AVAudioConverter(from: Self.opusFormat, to: Self.pcmFormat)
    }

    func decode(packet: Data) throws -> Data {
        guard !packet.isEmpty, packet.count <= Self.maxPacketBytes else {
            throw BridgeLivePreviewOpusDecoderError.invalidPacket
        }
        let packetSampleCount = try Self.opusSampleCountAt16k(packet)
        guard packetSampleCount == Int(Self.opusFrameSampleCount) else {
            throw BridgeLivePreviewOpusDecoderError.invalidFrameDuration(packetSampleCount)
        }
        guard let converter,
              let output = AVAudioPCMBuffer(
                  pcmFormat: Self.pcmFormat,
                  frameCapacity: Self.maxOutputFrames
              )
        else {
            throw BridgeLivePreviewOpusDecoderError.unavailable
        }

        let input = AVAudioCompressedBuffer(
            format: Self.opusFormat,
            packetCapacity: 1,
            maximumPacketSize: packet.count
        )
        packet.withUnsafeBytes { source in
            if let baseAddress = source.baseAddress {
                memcpy(input.data, baseAddress, packet.count)
            }
        }
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        if let description = input.packetDescriptions {
            description[0] = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: Self.opusFrameSampleCount,
                mDataByteSize: UInt32(packet.count)
            )
        }

        let inputSource = BridgeLivePreviewOpusDecoderInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            inputSource.next(outStatus)
        }
        if let conversionError {
            throw BridgeLivePreviewOpusDecoderError.decodeFailed(conversionError.localizedDescription)
        }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            break
        case .error:
            throw BridgeLivePreviewOpusDecoderError.decodeFailed("converter returned error")
        @unknown default:
            break
        }
        let frameCount = Int(output.frameLength)
        guard frameCount > 0, let samples = output.floatChannelData?[0] else {
            throw BridgeLivePreviewOpusDecoderError.emptyPCM
        }
        return Self.littleEndianFloatData(samples: samples, count: frameCount)
    }

    private static func opusSampleCountAt16k(_ packet: Data) throws -> Int {
        guard let toc = packet.first else {
            throw BridgeLivePreviewOpusDecoderError.invalidPacket
        }
        let config = Int(toc >> 3)
        let code = Int(toc & 0x03)
        let samplesPerFrame: Int
        switch config {
        case 0...11:
            switch config & 0x03 {
            case 0: samplesPerFrame = 160
            case 1: samplesPerFrame = 320
            case 2: samplesPerFrame = 640
            default: samplesPerFrame = 960
            }
        case 12...15:
            samplesPerFrame = (config & 0x01) == 0 ? 160 : 320
        case 16...31:
            switch config & 0x03 {
            case 0: samplesPerFrame = 40
            case 1: samplesPerFrame = 80
            case 2: samplesPerFrame = 160
            default: samplesPerFrame = 320
            }
        default:
            throw BridgeLivePreviewOpusDecoderError.invalidPacket
        }

        let frameCount: Int
        switch code {
        case 0:
            frameCount = 1
        case 1, 2:
            frameCount = 2
        case 3:
            guard packet.count >= 2 else {
                throw BridgeLivePreviewOpusDecoderError.invalidPacket
            }
            frameCount = Int(packet[packet.index(after: packet.startIndex)] & 0x3F)
            guard frameCount > 0 else {
                throw BridgeLivePreviewOpusDecoderError.invalidPacket
            }
        default:
            throw BridgeLivePreviewOpusDecoderError.invalidPacket
        }
        return samplesPerFrame * frameCount
    }

    private static func littleEndianFloatData(samples: UnsafePointer<Float>, count: Int) -> Data {
        var data = Data(count: count * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { rawBuffer in
            let output = rawBuffer.bindMemory(to: UInt32.self)
            for index in 0..<count {
                output[index] = samples[index].bitPattern.littleEndian
            }
        }
        return data
    }
}

private final class BridgeLivePreviewOpusDecoderInput: @unchecked Sendable {
    private let buffer: AVAudioCompressedBuffer
    private var supplied = false

    init(buffer: AVAudioCompressedBuffer) {
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
