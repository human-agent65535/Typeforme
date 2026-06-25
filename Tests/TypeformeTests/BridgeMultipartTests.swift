import Foundation
import Testing
@testable import Typeforme

@Suite("BridgeMultipart")
struct BridgeMultipartTests {
    @Test func bridgeTokenCompareRejectsLengthMismatches() {
        #expect(BridgeHTTPServer.constantTimeEquals("token-123", "token-123"))
        #expect(!BridgeHTTPServer.constantTimeEquals("token-124", "token-123"))
        #expect(!BridgeHTTPServer.constantTimeEquals("token", "token-123"))
        #expect(!BridgeHTTPServer.constantTimeEquals("token-123-extra", "token-123"))
    }

    @Test func clientJobIDNormalizationAllowsOnlyBridgeSafeTokens() {
        #expect(BridgeClientJobID.normalized(" ios_job-1 ") == "ios_job-1")
        #expect(BridgeClientJobID.normalized("ios job 1") == nil)
        #expect(BridgeClientJobID.normalized(String(repeating: "a", count: BridgeClientJobID.maxLength + 1)) == nil)
    }

    @Test func dictateUploadUsesMultipartFilePayload() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-test-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeCAFBytes().write(to: url)

        let multipart = try RemoteBridgeClient.multipartDictateBody(
            audioURL: url,
            languageIDs: ["zh-CN", "en-US"],
            correctionMode: CorrectionMode.polish.rawValue,
            appName: "Notes",
            bundleID: "com.apple.Notes",
            appCategory: "chat",
            contextBefore: "前一句。",
            contextAfter: "后一句。",
            includeRawTranscript: true,
            clientJobID: "ios_test_1"
        )

        #expect(multipart.contentType.hasPrefix("multipart/form-data; boundary="))
        let bodyText = String(data: multipart.body, encoding: .utf8) ?? ""
        #expect(bodyText.contains(#"name="audio"; filename="audio.caf""#))
        #expect(bodyText.contains("Content-Type: audio/x-caf"))
        #expect(bodyText.contains("AUDIOBYTES"))
        #expect(bodyText.contains(#"name="language_ids""#))
        #expect(bodyText.contains(#"name="client_job_id""#))
        #expect(bodyText.contains("ios_test_1"))
        #expect(bodyText.contains(#"["zh-CN","en-US"]"#))
        #expect(bodyText.contains(#"name="context_before""#))
        #expect(bodyText.contains("前一句。"))
        #expect(bodyText.contains(#"name="context_after""#))
        #expect(bodyText.contains("后一句。"))
        #expect(!bodyText.contains("audio_base64"))
        let audioExtensionRange = try #require(bodyText.range(of: #"name="audio_extension""#))
        let audioRange = try #require(bodyText.range(of: #"name="audio"; filename="audio.caf""#))
        #expect(audioExtensionRange.lowerBound < audioRange.lowerBound)
    }

    @Test func dictateUploadCanStreamMultipartFromTempFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-test-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeCAFBytes().write(to: url)

        let multipart = try RemoteBridgeClient.multipartDictateBodyFile(
            audioURL: url,
            languageIDs: ["zh-CN", "en-US"],
            correctionMode: CorrectionMode.polish.rawValue,
            appName: "Notes",
            bundleID: "com.apple.Notes",
            appCategory: "chat",
            contextBefore: "前一句。",
            contextAfter: "后一句。",
            includeRawTranscript: true,
            clientJobID: "ios_test_2"
        )
        defer { try? FileManager.default.removeItem(at: multipart.fileURL) }

        #expect(multipart.contentType.hasPrefix("multipart/form-data; boundary="))
        #expect(multipart.contentLength > 0)
        let body = try Data(contentsOf: multipart.fileURL)
        #expect(Int64(body.count) == multipart.contentLength)
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        #expect(bodyText.contains(#"name="audio"; filename="audio.caf""#))
        #expect(bodyText.contains("Content-Type: audio/x-caf"))
        #expect(bodyText.contains("AUDIOBYTES"))
        #expect(bodyText.contains(#"name="language_ids""#))
        #expect(bodyText.contains(#"name="client_job_id""#))
        #expect(bodyText.contains("ios_test_2"))
        #expect(bodyText.contains(#"["zh-CN","en-US"]"#))
        #expect(!bodyText.contains("audio_base64"))
        let audioExtensionRange = try #require(bodyText.range(of: #"name="audio_extension""#))
        let audioRange = try #require(bodyText.range(of: #"name="audio"; filename="audio.caf""#))
        #expect(audioExtensionRange.lowerBound < audioRange.lowerBound)
    }

    @Test func serverParserStreamsMultipartAudioToTempFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-test-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let audioBytes = makeCAFBytes(extraBytes: 8188)
        try audioBytes.write(to: url)

        let multipart = try RemoteBridgeClient.multipartDictateBodyFile(
            audioURL: url,
            languageIDs: ["zh-CN", "en-US"],
            correctionMode: CorrectionMode.polishPlus.rawValue,
            appName: "Notes",
            bundleID: "com.apple.Notes",
            appCategory: "chat",
            contextBefore: "前一句。",
            contextAfter: "后一句。",
            includeRawTranscript: true,
            clientJobID: "ios_stream_1"
        )
        defer { try? FileManager.default.removeItem(at: multipart.fileURL) }

        let audioDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-stream-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: audioDirectory) }

        let parser = try BridgeMultipart.StreamingFormDataParser(
            contentType: multipart.contentType,
            maxBodyBytes: Int(multipart.contentLength) + 1024,
            maxHeaderBytes: 16 * 1024,
            maxFieldBytes: 1 * 1024 * 1024,
            audioDirectory: audioDirectory
        )
        let body = try Data(contentsOf: multipart.fileURL)
        let chunkSizes = [1, 2, 7, 64, 3, 128, 5]
        var offset = body.startIndex
        var index = 0
        while offset < body.endIndex {
            let size = chunkSizes[index % chunkSizes.count]
            let end = min(body.index(offset, offsetBy: size, limitedBy: body.endIndex) ?? body.endIndex, body.endIndex)
            try parser.append(body[offset..<end])
            offset = end
            index += 1
        }
        let form = try parser.finish()
        let streamedAudioURL = try #require(form.audioFileURL)
        defer { try? FileManager.default.removeItem(at: streamedAudioURL) }

        #expect(form.audioFilename == "audio.caf")
        #expect(streamedAudioURL.pathExtension == "caf")
        #expect(form.fields["correction_mode"] == CorrectionMode.polishPlus.rawValue)
        #expect(form.fields["app_name"] == "Notes")
        #expect(form.fields["client_job_id"] == "ios_stream_1")
        #expect(form.fields["context_before"] == "前一句。")
        #expect(form.fields["context_after"] == "后一句。")
        #expect(form.fields["include_raw_transcript"] == "true")
        #expect(try Data(contentsOf: streamedAudioURL) == audioBytes)
    }

    @Test func serverParserRejectsAudioBeforeAudioExtensionField() throws {
        let boundary = "TypeformeTest-\(UUID().uuidString)"
        let audioBytes = makeCAFBytes(extraBytes: 4092)
        let body = multipartBody(
            boundary: boundary,
            audioBytes: audioBytes,
            fields: [
                ("audio_extension", "caf"),
                ("correction_mode", CorrectionMode.polish.rawValue),
            ]
        )
        let audioDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-stream-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: audioDirectory) }

        #expect(throws: BridgeMultipartError.self) {
            try parseStreamedMultipartBody(body, boundary: boundary, audioDirectory: audioDirectory)
        }
    }

    @Test func serverParserRejectsMissingAudioExtensionField() throws {
        let boundary = "TypeformeTest-\(UUID().uuidString)"
        let audioBytes = makeCAFBytes(extraBytes: 4092)
        let body = multipartBody(
            boundary: boundary,
            audioBytes: audioBytes,
            fields: [
                ("correction_mode", CorrectionMode.polish.rawValue),
            ],
            audioFirst: false
        )
        let audioDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-stream-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: audioDirectory) }

        #expect(throws: BridgeMultipartError.self) {
            try parseStreamedMultipartBody(body, boundary: boundary, audioDirectory: audioDirectory)
        }
    }

    @Test func serverParserRejectsM4AAudioExtensionField() throws {
        let boundary = "TypeformeTest-\(UUID().uuidString)"
        let audioBytes = makeCAFBytes(extraBytes: 4092)
        let body = multipartBody(
            boundary: boundary,
            audioBytes: audioBytes,
            audioFilename: "audio.m4a",
            contentType: "audio/mp4",
            fields: [
                ("audio_extension", "m4a"),
                ("correction_mode", CorrectionMode.polish.rawValue),
            ],
            audioFirst: false
        )
        let audioDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-stream-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: audioDirectory) }

        #expect(throws: BridgeMultipartError.self) {
            try parseStreamedMultipartBody(body, boundary: boundary, audioDirectory: audioDirectory)
        }
    }

    @Test func serverParserRejectsM4ADisguisedAsCAF() throws {
        let boundary = "TypeformeTest-\(UUID().uuidString)"
        let audioBytes = makeCAFBytes(extraBytes: 4092)
        let body = multipartBody(
            boundary: boundary,
            audioBytes: audioBytes,
            audioFilename: "audio.m4a",
            contentType: "audio/mp4",
            fields: [
                ("audio_extension", "caf"),
                ("correction_mode", CorrectionMode.polish.rawValue),
            ],
            audioFirst: false
        )
        let audioDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-stream-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: audioDirectory) }

        #expect(throws: BridgeMultipartError.self) {
            try parseStreamedMultipartBody(body, boundary: boundary, audioDirectory: audioDirectory)
        }
    }

    @Test func serverParserRejectsFLACAudioExtensionField() throws {
        let boundary = "TypeformeTest-\(UUID().uuidString)"
        let audioBytes = makeCAFBytes(extraBytes: 4092)
        let body = multipartBody(
            boundary: boundary,
            audioBytes: audioBytes,
            audioFilename: "audio.flac",
            contentType: "audio/flac",
            fields: [
                ("audio_extension", "flac"),
                ("correction_mode", CorrectionMode.polish.rawValue),
            ],
            audioFirst: false
        )
        let audioDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-stream-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: audioDirectory) }

        #expect(throws: BridgeMultipartError.self) {
            try parseStreamedMultipartBody(body, boundary: boundary, audioDirectory: audioDirectory)
        }
    }

    @Test func serverParserRejectsWrongAudioContentType() throws {
        let boundary = "TypeformeTest-\(UUID().uuidString)"
        let body = multipartBody(
            boundary: boundary,
            audioBytes: makeCAFBytes(extraBytes: 4092),
            audioFilename: "audio.caf",
            contentType: "audio/flac",
            fields: [
                ("audio_extension", "caf"),
                ("correction_mode", CorrectionMode.polish.rawValue),
            ],
            audioFirst: false
        )
        let audioDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-stream-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: audioDirectory) }

        #expect(throws: BridgeMultipartError.self) {
            try parseStreamedMultipartBody(body, boundary: boundary, audioDirectory: audioDirectory)
        }
    }

    @Test func serverParserRejectsFakeCAFBytes() throws {
        let boundary = "TypeformeTest-\(UUID().uuidString)"
        let body = multipartBody(
            boundary: boundary,
            audioBytes: Data("AUDIOBYTES".utf8),
            fields: [
                ("audio_extension", "caf"),
                ("correction_mode", CorrectionMode.polish.rawValue),
            ],
            audioFirst: false
        )
        let audioDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-stream-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: audioDirectory) }

        #expect(throws: BridgeMultipartError.self) {
            try parseStreamedMultipartBody(body, boundary: boundary, audioDirectory: audioDirectory)
        }
    }

    @Test func dictateUploadRejectsUnsupportedAudioExtension() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("AUDIOBYTES".utf8).write(to: url)

        #expect(throws: BridgeMultipartError.self) {
            try RemoteBridgeClient.multipartDictateBody(
                audioURL: url,
                languageIDs: ["zh-CN"],
                correctionMode: CorrectionMode.polish.rawValue,
                appName: "Notes",
                bundleID: "com.apple.Notes",
                appCategory: "chat",
                contextBefore: "",
                contextAfter: "",
                includeRawTranscript: true
            )
        }
    }

    private func multipartBody(
        boundary: String,
        audioBytes: Data,
        audioFilename: String = "audio.caf",
        contentType: String = "audio/x-caf",
        fields: [(name: String, value: String)],
        audioFirst: Bool = true
    ) -> Data {
        var body = Data()

        func appendAudio() {
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"audio\"; filename=\"\(audioFilename)\"\r\n")
            body.appendUTF8("Content-Type: \(contentType)\r\n\r\n")
            body.append(audioBytes)
            body.appendUTF8("\r\n")
        }

        func appendFields() {
            for field in fields {
                body.appendUTF8("--\(boundary)\r\n")
                body.appendUTF8("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
                body.appendUTF8(field.value)
                body.appendUTF8("\r\n")
            }
        }

        if audioFirst {
            appendAudio()
            appendFields()
        } else {
            appendFields()
            appendAudio()
        }
        body.appendUTF8("--\(boundary)--\r\n")
        return body
    }

    private func parseStreamedMultipartBody(
        _ body: Data,
        boundary: String,
        audioDirectory: URL
    ) throws -> BridgeMultipart.StreamedFormData {
        let parser = try BridgeMultipart.StreamingFormDataParser(
            contentType: "multipart/form-data; boundary=\(boundary)",
            maxBodyBytes: body.count + 1024,
            maxHeaderBytes: 16 * 1024,
            maxFieldBytes: 1 * 1024 * 1024,
            audioDirectory: audioDirectory
        )
        let chunkSizes = [1, 7, 3, 128, 2, 64, 5]
        var offset = body.startIndex
        var index = 0
        while offset < body.endIndex {
            let size = chunkSizes[index % chunkSizes.count]
            let end = min(body.index(offset, offsetBy: size, limitedBy: body.endIndex) ?? body.endIndex, body.endIndex)
            try parser.append(body[offset..<end])
            offset = end
            index += 1
        }
        return try parser.finish()
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(contentsOf: string.utf8)
    }
}

private func makeCAFBytes(extraBytes: Int = 10) -> Data {
    var data = BridgeAudioFormat.cafMagic
    data.append(Data("AUDIOBYTES".utf8))
    if extraBytes > 0 {
        data.append(Data((0..<extraBytes).map { UInt8($0 % 251) }))
    }
    return data
}
