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
