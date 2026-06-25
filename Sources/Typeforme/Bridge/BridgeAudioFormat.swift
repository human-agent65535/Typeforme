@preconcurrency import AVFoundation
import Foundation

enum BridgeAudioFormat {
    static let allowedExtensions = ["caf"]
    static let cafMagic = Data("caff".utf8)
    static let cafMagicByteCount = 4

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
        isAllowedExtension(ext) ? "audio/x-caf" : "application/octet-stream"
    }

    static func hasCAFMagic(_ data: Data) -> Bool {
        data.starts(with: cafMagic)
    }

    static func fileHasCAFMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: cafMagicByteCount) else {
            return false
        }
        return hasCAFMagic(header)
    }

    static func isOpusCAFFile(_ url: URL) -> Bool {
        guard fileHasCAFMagic(url),
              let file = try? AVAudioFile(forReading: url)
        else {
            return false
        }
        let description = file.fileFormat.streamDescription.pointee
        return description.mFormatID == kAudioFormatOpus
            && abs(file.fileFormat.sampleRate - BridgeAudioRecordingContract.sampleRate) < 0.5
            && Int(file.fileFormat.channelCount) == BridgeAudioRecordingContract.channelCount
    }
}

enum BridgeAudioRecordingContract {
    static let sampleRate = 16_000.0
    static let channelCount = 1
    static let opusBitRate = 24_000
    static let minimumDurationSeconds = 0.35
    static let stopTailBufferNanoseconds: UInt64 = 200_000_000
}
