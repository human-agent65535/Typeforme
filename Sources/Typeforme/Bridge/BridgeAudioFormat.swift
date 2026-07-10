@preconcurrency import AVFoundation
import Foundation

enum BridgeAudioFormat {
    struct FLACStreamInfo: Equatable, Sendable {
        let sampleRate: Int
        let channelCount: Int
        let bitDepth: Int
        let totalSamples: UInt64

        var durationSeconds: TimeInterval? {
            guard sampleRate > 0, totalSamples > 0 else { return nil }
            return Double(totalSamples) / Double(sampleRate)
        }
    }

    static let allowedExtensions = ["flac"]
    static let flacMagic = Data("fLaC".utf8)
    static let flacMagicByteCount = 4
    private static let streamInfoByteCount = 42

    static func isAllowedExtension(_ ext: String) -> Bool {
        allowedExtensions.contains(ext.lowercased())
    }

    static func normalizedExtension(_ extensionHint: String?) -> String? {
        guard let extensionHint else { return nil }
        let ext = extensionHint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !ext.isEmpty,
              ext.count <= 8,
              ext.allSatisfy({ $0.isLetter || $0.isNumber }),
              isAllowedExtension(ext)
        else {
            return nil
        }
        return ext
    }

    static func mimeType(forExtension ext: String) -> String {
        isAllowedExtension(ext) ? "audio/flac" : "application/octet-stream"
    }

    static func hasFLACMagic(_ data: Data) -> Bool {
        data.starts(with: flacMagic)
    }

    static func fileHasFLACMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: flacMagicByteCount) else {
            return false
        }
        return hasFLACMagic(header)
    }

    static func flacStreamInfo(_ url: URL) -> FLACStreamInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: streamInfoByteCount) else {
            return nil
        }
        return flacStreamInfo(header)
    }

    static func flacStreamInfo(_ header: Data) -> FLACStreamInfo? {
        // Native FLAC requires STREAMINFO to be the first metadata block. Its
        // fixed 34-byte payload starts immediately after the four-byte block
        // header, so the complete prefix is only 42 bytes.
        guard header.count >= streamInfoByteCount,
              hasFLACMagic(header),
              header[4] & 0x7f == 0,
              Int(header[5]) << 16 | Int(header[6]) << 8 | Int(header[7]) == 34
        else {
            return nil
        }

        var packed: UInt64 = 0
        for byte in header[18...25] {
            packed = (packed << 8) | UInt64(byte)
        }
        return FLACStreamInfo(
            sampleRate: Int((packed >> 44) & 0x000f_ffff),
            channelCount: Int((packed >> 41) & 0x7) + 1,
            bitDepth: Int((packed >> 36) & 0x1f) + 1,
            totalSamples: packed & 0x0000_000f_ffff_ffff
        )
    }

    static func isWithinUploadDurationLimit(_ url: URL) -> Bool {
        guard let info = flacStreamInfo(url) else { return false }
        return info.sampleRate == Int(BridgeAudioRecordingContract.sampleRate)
            && info.channelCount == BridgeAudioRecordingContract.channelCount
            && info.bitDepth == BridgeAudioRecordingContract.flacBitDepth
            && info.totalSamples > 0
            && info.totalSamples <= BridgeAudioRecordingContract.maximumFrameCount
    }

    static func isFLACFile(_ url: URL) -> Bool {
        guard let streamInfo = flacStreamInfo(url),
              let file = try? AVAudioFile(forReading: url)
        else {
            return false
        }
        let description = file.fileFormat.streamDescription.pointee
        return description.mFormatID == kAudioFormatFLAC
            && description.mFormatFlags == kAppleLosslessFormatFlag_16BitSourceData
            && streamInfo.sampleRate == Int(BridgeAudioRecordingContract.sampleRate)
            && streamInfo.channelCount == BridgeAudioRecordingContract.channelCount
            && streamInfo.bitDepth == BridgeAudioRecordingContract.flacBitDepth
            && abs(file.fileFormat.sampleRate - BridgeAudioRecordingContract.sampleRate) < 0.5
            && Int(file.fileFormat.channelCount) == BridgeAudioRecordingContract.channelCount
    }
}

enum BridgeAudioRecordingContract {
    static let sampleRate = 16_000.0
    static let channelCount = 1
    static let flacBitDepth = 16
    static let minimumDurationSeconds = 0.35
    static let maximumDurationSeconds = 10 * 60.0
    static let maximumFrameCount = UInt64(sampleRate * maximumDurationSeconds)
    static let stopTailBufferNanoseconds: UInt64 = 200_000_000
}
