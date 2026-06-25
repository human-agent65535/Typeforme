import Foundation

enum BridgeAudioFormat {
    static let allowedExtensions = ["m4a", "aac"]

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
        isAllowedExtension(ext) ? "audio/mp4" : "application/octet-stream"
    }
}

enum BridgeAudioRecordingContract {
    static let minimumDurationSeconds = 0.35
    static let stopTailBufferNanoseconds: UInt64 = 200_000_000
    static let aacBitRate = 64_000
}
