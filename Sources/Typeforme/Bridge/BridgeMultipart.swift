import Foundation

enum BridgeMultipartError: LocalizedError {
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            return message
        }
    }
}

enum BridgeMultipart {
    struct StreamedFormData {
        let fields: [String: String]
        let audioFileURL: URL?
        let audioFilename: String?
    }

    struct Body {
        let body: Data
        let contentType: String
    }

    struct FileBody {
        let fileURL: URL
        let contentType: String
        let contentLength: Int64
    }

    static func dictateBody(
        audioURL: URL,
        languageIDs: [String],
        correctionMode: String,
        appName: String?,
        bundleID: String?,
        appCategory: String,
        contextBefore: String = "",
        contextAfter: String = "",
        includeRawTranscript: Bool,
        clientJobID: String? = nil,
        alternateTranscript: String? = nil
    ) throws -> Body {
        try dictateBody(
            audioURL: audioURL,
            audioExtension: nil,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: appName,
            bundleID: bundleID,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            includeRawTranscript: includeRawTranscript,
            clientJobID: clientJobID,
            alternateTranscript: alternateTranscript
        )
    }

    static func dictateBody(
        audioURL: URL,
        audioExtension: String,
        languageIDs: [String],
        correctionMode: String,
        appName: String,
        appCategory: String,
        contextBefore: String,
        contextAfter: String,
        includeRawTranscript: Bool,
        clientJobID: String? = nil,
        alternateTranscript: String? = nil
    ) throws -> Body {
        try dictateBody(
            audioURL: audioURL,
            audioExtension: audioExtension,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: appName,
            bundleID: nil,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            includeRawTranscript: includeRawTranscript,
            clientJobID: clientJobID,
            alternateTranscript: alternateTranscript
        )
    }

    private static func dictateBody(
        audioURL: URL,
        audioExtension: String?,
        languageIDs: [String],
        correctionMode: String,
        appName: String?,
        bundleID: String?,
        appCategory: String,
        contextBefore: String,
        contextAfter: String,
        includeRawTranscript: Bool,
        clientJobID: String?,
        alternateTranscript: String? = nil
    ) throws -> Body {
        let boundary = "Typeforme-\(UUID().uuidString)"
        var body = Data()

        if let clientJobID = normalizedClientJobID(clientJobID) {
            appendField("client_job_id", clientJobID, to: &body, boundary: boundary)
        }
        appendField("language_ids", jsonString(languageIDs), to: &body, boundary: boundary)
        appendField("correction_mode", correctionMode, to: &body, boundary: boundary)
        appendField("app_category", appCategory, to: &body, boundary: boundary)
        appendField("context_before", contextBefore, to: &body, boundary: boundary)
        appendField("context_after", contextAfter, to: &body, boundary: boundary)
        appendField("include_raw_transcript", includeRawTranscript ? "true" : "false", to: &body, boundary: boundary)
        if let appName, !appName.isEmpty {
            appendField("app_name", appName, to: &body, boundary: boundary)
        }
        if let bundleID, !bundleID.isEmpty {
            appendField("bundle_id", bundleID, to: &body, boundary: boundary)
        }
        if let alt = alternateTranscript?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty {
            appendField("alternate_transcript", alt, to: &body, boundary: boundary)
        }

        let explicitExtension = audioExtension?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = try resolvedAudioExtension(for: audioURL, explicitExtension: explicitExtension)
        appendField("audio_extension", ext, to: &body, boundary: boundary)
        try appendFile(
            name: "audio",
            filename: "audio.\(ext)",
            contentType: mimeType(forExtension: ext),
            fileURL: audioURL,
            to: &body,
            boundary: boundary
        )
        body.append("--\(boundary)--\r\n")
        return Body(body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }

    static func dictateBodyFile(
        audioURL: URL,
        languageIDs: [String],
        correctionMode: String,
        appName: String?,
        bundleID: String?,
        appCategory: String,
        contextBefore: String = "",
        contextAfter: String = "",
        includeRawTranscript: Bool,
        clientJobID: String? = nil,
        alternateTranscript: String? = nil
    ) throws -> FileBody {
        try dictateBodyFile(
            audioURL: audioURL,
            audioExtension: nil,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: appName,
            bundleID: bundleID,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            includeRawTranscript: includeRawTranscript,
            clientJobID: clientJobID,
            alternateTranscript: alternateTranscript
        )
    }

    private static func dictateBodyFile(
        audioURL: URL,
        audioExtension: String?,
        languageIDs: [String],
        correctionMode: String,
        appName: String?,
        bundleID: String?,
        appCategory: String,
        contextBefore: String,
        contextAfter: String,
        includeRawTranscript: Bool,
        clientJobID: String?,
        alternateTranscript: String? = nil
    ) throws -> FileBody {
        let boundary = "Typeforme-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: bodyURL)

        do {
            if let clientJobID = normalizedClientJobID(clientJobID) {
                try writeField("client_job_id", clientJobID, to: handle, boundary: boundary)
            }
            try writeField("language_ids", jsonString(languageIDs), to: handle, boundary: boundary)
            try writeField("correction_mode", correctionMode, to: handle, boundary: boundary)
            try writeField("app_category", appCategory, to: handle, boundary: boundary)
            try writeField("context_before", contextBefore, to: handle, boundary: boundary)
            try writeField("context_after", contextAfter, to: handle, boundary: boundary)
            try writeField("include_raw_transcript", includeRawTranscript ? "true" : "false", to: handle, boundary: boundary)
            if let appName, !appName.isEmpty {
                try writeField("app_name", appName, to: handle, boundary: boundary)
            }
            if let bundleID, !bundleID.isEmpty {
                try writeField("bundle_id", bundleID, to: handle, boundary: boundary)
            }
            if let alt = alternateTranscript?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty {
                try writeField("alternate_transcript", alt, to: handle, boundary: boundary)
            }

            let explicitExtension = audioExtension?.trimmingCharacters(in: .whitespacesAndNewlines)
            let ext = try resolvedAudioExtension(for: audioURL, explicitExtension: explicitExtension)
            try writeField("audio_extension", ext, to: handle, boundary: boundary)
            try writeFile(
                name: "audio",
                filename: "audio.\(ext)",
                contentType: mimeType(forExtension: ext),
                fileURL: audioURL,
                to: handle,
                boundary: boundary
            )
            try handle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
            try handle.close()

            let size = (try FileManager.default.attributesOfItem(atPath: bodyURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else {
                throw BridgeMultipartError.invalidRequest("Multipart body is empty")
            }
            return FileBody(
                fileURL: bodyURL,
                contentType: "multipart/form-data; boundary=\(boundary)",
                contentLength: size
            )
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
    }

    final class StreamingFormDataParser {
        private enum State: Equatable {
            case boundary
            case afterBoundary
            case headers
            case body
            case finished
        }

        private let delimiter: Data
        private let prefixedDelimiter: Data
        private let headerSeparator = Data([13, 10, 13, 10])
        private let closing = Data("--".utf8)
        private let lineBreak = Data([13, 10])
        private let maxBodyBytes: Int
        private let maxHeaderBytes: Int
        private let maxFieldBytes: Int
        private let audioDirectory: URL

        private var state: State = .boundary
        private var buffer = Data()
        private var receivedBytes = 0
        private var fields: [String: String] = [:]
        private var currentPart: PartMetadata?
        private var currentFieldData = Data()
        private var audioHandle: FileHandle?
        private var audioBytes = 0
        private var didReturnAudioFile = false

        private(set) var audioFileURL: URL?
        private(set) var audioFilename: String?

        init(
            contentType: String,
            maxBodyBytes: Int,
            maxHeaderBytes: Int,
            maxFieldBytes: Int,
            audioDirectory: URL
        ) throws {
            guard contentType.lowercased().contains("multipart/form-data") else {
                throw BridgeMultipartError.invalidRequest("Content-Type must be multipart/form-data")
            }
            guard let boundary = BridgeMultipart.boundary(from: contentType) else {
                throw BridgeMultipartError.invalidRequest("Missing multipart boundary")
            }
            self.delimiter = Data("--\(boundary)".utf8)
            self.prefixedDelimiter = Data("\r\n--\(boundary)".utf8)
            self.maxBodyBytes = maxBodyBytes
            self.maxHeaderBytes = maxHeaderBytes
            self.maxFieldBytes = maxFieldBytes
            self.audioDirectory = audioDirectory
        }

        deinit {
            if !didReturnAudioFile {
                cleanup()
            }
        }

        func append(_ chunk: Data) throws {
            receivedBytes += chunk.count
            guard receivedBytes <= maxBodyBytes else {
                throw BridgeMultipartError.invalidRequest("Multipart body is too large")
            }
            guard state != .finished else { return }
            buffer.append(chunk)
            try processBuffer(final: false)
        }

        func finish() throws -> StreamedFormData {
            try processBuffer(final: true)
            guard state == .finished else {
                throw BridgeMultipartError.invalidRequest("Malformed multipart body")
            }
            try closeAudioHandle()
            didReturnAudioFile = audioFileURL != nil
            return StreamedFormData(
                fields: fields,
                audioFileURL: audioFileURL,
                audioFilename: audioFilename
            )
        }

        func cleanup() {
            try? audioHandle?.close()
            audioHandle = nil
            if let audioFileURL {
                try? FileManager.default.removeItem(at: audioFileURL)
            }
            audioFileURL = nil
            didReturnAudioFile = false
        }

        private func processBuffer(final: Bool) throws {
            while true {
                switch state {
                case .boundary:
                    guard let range = buffer.range(of: delimiter) else {
                        if final {
                            throw BridgeMultipartError.invalidRequest("Malformed multipart body")
                        }
                        retainPossibleBoundaryPrefix()
                        return
                    }
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    state = .afterBoundary

                case .afterBoundary:
                    if buffer.starts(with: closing) {
                        buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: closing.count))
                        state = .finished
                        buffer.removeAll(keepingCapacity: false)
                        return
                    }
                    if buffer.starts(with: lineBreak) {
                        buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: lineBreak.count))
                        state = .headers
                        continue
                    }
                    if !final, buffer.count < max(closing.count, lineBreak.count) {
                        return
                    }
                    throw BridgeMultipartError.invalidRequest("Malformed multipart boundary")

                case .headers:
                    guard let headerRange = buffer.range(of: headerSeparator) else {
                        if buffer.count > maxHeaderBytes + headerSeparator.count || final {
                            throw BridgeMultipartError.invalidRequest("Malformed multipart headers")
                        }
                        return
                    }
                    let headerData = buffer[buffer.startIndex..<headerRange.lowerBound]
                    guard headerData.count <= maxHeaderBytes,
                          let headerText = String(data: headerData, encoding: .utf8)
                    else {
                        throw BridgeMultipartError.invalidRequest("Malformed multipart headers")
                    }
                    currentPart = BridgeMultipart.partMetadata(from: headerText)
                    currentFieldData.removeAll(keepingCapacity: true)
                    buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
                    state = .body

                case .body:
                    if let range = buffer.range(of: prefixedDelimiter) {
                        try appendCurrentPartBytes(buffer[buffer.startIndex..<range.lowerBound])
                        try finalizeCurrentPart()
                        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                        state = .afterBoundary
                        continue
                    }

                    let retainedTailBytes = max(0, prefixedDelimiter.count - 1)
                    if buffer.count > retainedTailBytes {
                        let flushEnd = buffer.index(buffer.endIndex, offsetBy: -retainedTailBytes)
                        try appendCurrentPartBytes(buffer[buffer.startIndex..<flushEnd])
                        buffer.removeSubrange(buffer.startIndex..<flushEnd)
                    }

                    if final {
                        throw BridgeMultipartError.invalidRequest("Malformed multipart body")
                    }
                    return

                case .finished:
                    buffer.removeAll(keepingCapacity: false)
                    return
                }
            }
        }

        private func retainPossibleBoundaryPrefix() {
            guard buffer.count >= delimiter.count else { return }
            let keepStart = buffer.index(buffer.endIndex, offsetBy: -(delimiter.count - 1))
            buffer.removeSubrange(buffer.startIndex..<keepStart)
        }

        private func appendCurrentPartBytes(_ bytes: Data) throws {
            guard !bytes.isEmpty, let currentPart else { return }
            if currentPart.name == "audio" {
                try ensureAudioFile(for: currentPart)
                try audioHandle?.write(contentsOf: bytes)
                audioBytes += bytes.count
                guard audioBytes <= maxBodyBytes else {
                    throw BridgeMultipartError.invalidRequest("Audio part is too large")
                }
            } else {
                currentFieldData.append(bytes)
                guard currentFieldData.count <= maxFieldBytes else {
                    throw BridgeMultipartError.invalidRequest("Multipart field is too large: \(currentPart.name)")
                }
            }
        }

        private func finalizeCurrentPart() throws {
            defer {
                currentPart = nil
                currentFieldData.removeAll(keepingCapacity: true)
            }
            guard let currentPart else { return }
            if currentPart.name == "audio" {
                try closeAudioHandle()
                return
            }
            if let value = String(data: currentFieldData, encoding: .utf8) {
                fields[currentPart.name] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        private func ensureAudioFile(for part: PartMetadata) throws {
            if audioHandle != nil { return }
            guard audioFileURL == nil else {
                throw BridgeMultipartError.invalidRequest("Multipart request contains multiple audio parts")
            }
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            let url = audioDirectory.appendingPathComponent("\(UUID().uuidString).upload")
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            audioHandle = try FileHandle(forWritingTo: url)
            audioFileURL = url
            audioFilename = part.filename
        }

        private func closeAudioHandle() throws {
            guard let audioHandle else { return }
            try audioHandle.close()
            self.audioHandle = nil
        }
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "m4a", "aac": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }

    private static func boundary(from contentType: String) -> String? {
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pair.count == 2, pair[0].lowercased() == "boundary" else { continue }
            let boundary = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return isValidBoundary(boundary) ? boundary : nil
        }
        return nil
    }

    private static func isValidBoundary(_ boundary: String) -> Bool {
        let bytes = Array(boundary.utf8)
        guard !bytes.isEmpty, bytes.count <= 70 else { return false }
        for byte in bytes {
            let isAlphaNumeric = (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
            let isAllowedPunctuation = [39, 40, 41, 43, 44, 45, 46, 47, 58, 61, 63, 95].contains(byte)
            guard isAlphaNumeric || isAllowedPunctuation else { return false }
        }
        return true
    }

    private struct PartMetadata {
        let name: String
        let filename: String?
        let contentType: String?
    }

    private static func partMetadata(from headerText: String) -> PartMetadata? {
        var headers: [String: String] = [:]
        for line in headerText.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        guard let disposition = headers["content-disposition"],
              let name = headerParameter("name", in: disposition)
        else {
            return nil
        }
        return PartMetadata(
            name: name,
            filename: headerParameter("filename", in: disposition),
            contentType: headers["content-type"]
        )
    }

    private static func headerParameter(_ name: String, in header: String) -> String? {
        for parameter in header.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pair.count == 2, pair[0].lowercased() == name.lowercased() else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    private static func appendField(_ name: String, _ value: String, to body: inout Data, boundary: String) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.append(value)
        body.append("\r\n")
    }

    private static func appendFile(
        name: String,
        filename: String,
        contentType: String,
        fileURL: URL,
        to body: inout Data,
        boundary: String
    ) throws {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(contentType)\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n")
    }

    private static func writeField(_ name: String, _ value: String, to handle: FileHandle, boundary: String) throws {
        try handle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
        try handle.write(contentsOf: Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        try handle.write(contentsOf: Data(value.utf8))
        try handle.write(contentsOf: Data("\r\n".utf8))
    }

    private static func writeFile(
        name: String,
        filename: String,
        contentType: String,
        fileURL: URL,
        to handle: FileHandle,
        boundary: String
    ) throws {
        try handle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
        try handle.write(contentsOf: Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        try handle.write(contentsOf: Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while true {
            let chunk = try input.read(upToCount: 512 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            try handle.write(contentsOf: chunk)
        }
        try handle.write(contentsOf: Data("\r\n".utf8))
    }

    private static func resolvedAudioExtension(for audioURL: URL, explicitExtension: String?) throws -> String {
        let ext = (
            explicitExtension?.isEmpty == false
                ? explicitExtension!
                : (audioURL.pathExtension.isEmpty ? "m4a" : audioURL.pathExtension)
        ).lowercased()
        guard ["m4a", "aac"].contains(ext) else {
            throw BridgeMultipartError.invalidRequest("Unsupported audio extension: \(ext)")
        }
        return ext
    }

    private static func normalizedClientJobID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 96 else { return nil }
        let allowed = trimmed.filter { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
        return allowed == trimmed ? trimmed : nil
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
