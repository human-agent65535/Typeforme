enum BridgeAudioFormat {
    static let defaultExtension = "m4a"
    static let allowedExtensions = ["m4a", "aac"]

    static func isAllowedExtension(_ ext: String) -> Bool {
        allowedExtensions.contains(ext.lowercased())
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
