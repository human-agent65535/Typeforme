@preconcurrency import AVFoundation
import Foundation

enum BridgeAudioFormat {
    static let allowedExtensions = ["flac"]
    static let flacMagic = Data("fLaC".utf8)
    static let flacMagicByteCount = 4

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

    static func isFLACFile(_ url: URL) -> Bool {
        guard fileHasFLACMagic(url),
              let file = try? AVAudioFile(forReading: url)
        else {
            return false
        }
        let description = file.fileFormat.streamDescription.pointee
        return description.mFormatID == kAudioFormatFLAC
            && description.mFormatFlags == kAppleLosslessFormatFlag_16BitSourceData
            && abs(file.fileFormat.sampleRate - BridgeAudioRecordingContract.sampleRate) < 0.5
            && Int(file.fileFormat.channelCount) == BridgeAudioRecordingContract.channelCount
    }
}

enum BridgeAudioRecordingContract {
    static let sampleRate = 16_000.0
    static let channelCount = 1
    static let flacBitDepth = 16
    static let minimumDurationSeconds = 0.35
    static let stopTailBufferNanoseconds: UInt64 = 200_000_000
}
