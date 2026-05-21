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

    @Test func dictateUploadUsesMultipartFilePayload() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("AUDIOBYTES".utf8).write(to: url)

        let multipart = try RemoteBridgeClient.multipartDictateBody(
            audioURL: url,
            languageIDs: ["zh-CN", "en-US"],
            correctionMode: CorrectionMode.polish.rawValue,
            appName: "Notes",
            bundleID: "com.apple.Notes",
            appCategory: "chat",
            contextBefore: "前一句。",
            contextAfter: "后一句。",
            includeRawTranscript: true
        )

        #expect(multipart.contentType.hasPrefix("multipart/form-data; boundary="))
        let bodyText = String(data: multipart.body, encoding: .utf8) ?? ""
        #expect(bodyText.contains(#"name="audio"; filename="audio.m4a""#))
        #expect(bodyText.contains("Content-Type: audio/mp4"))
        #expect(bodyText.contains("AUDIOBYTES"))
        #expect(bodyText.contains(#"name="language_ids""#))
        #expect(bodyText.contains(#"["zh-CN","en-US"]"#))
        #expect(bodyText.contains(#"name="context_before""#))
        #expect(bodyText.contains("前一句。"))
        #expect(bodyText.contains(#"name="context_after""#))
        #expect(bodyText.contains("后一句。"))
        #expect(!bodyText.contains("audio_base64"))
    }

    @Test func dictateUploadCanStreamMultipartFromTempFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("AUDIOBYTES".utf8).write(to: url)

        let multipart = try RemoteBridgeClient.multipartDictateBodyFile(
            audioURL: url,
            languageIDs: ["zh-CN", "en-US"],
            correctionMode: CorrectionMode.polish.rawValue,
            appName: "Notes",
            bundleID: "com.apple.Notes",
            appCategory: "chat",
            contextBefore: "前一句。",
            contextAfter: "后一句。",
            includeRawTranscript: true
        )
        defer { try? FileManager.default.removeItem(at: multipart.fileURL) }

        #expect(multipart.contentType.hasPrefix("multipart/form-data; boundary="))
        #expect(multipart.contentLength > 0)
        let body = try Data(contentsOf: multipart.fileURL)
        #expect(Int64(body.count) == multipart.contentLength)
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        #expect(bodyText.contains(#"name="audio"; filename="audio.m4a""#))
        #expect(bodyText.contains("Content-Type: audio/mp4"))
        #expect(bodyText.contains("AUDIOBYTES"))
        #expect(bodyText.contains(#"name="language_ids""#))
        #expect(bodyText.contains(#"["zh-CN","en-US"]"#))
        #expect(!bodyText.contains("audio_base64"))
    }

    @Test func serverParserStreamsMultipartAudioToTempFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let audioBytes = Data((0..<8192).map { UInt8($0 % 251) })
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
            includeRawTranscript: true
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

        #expect(form.audioFilename == "audio.m4a")
        #expect(form.fields["correction_mode"] == CorrectionMode.polishPlus.rawValue)
        #expect(form.fields["app_name"] == "Notes")
        #expect(form.fields["context_before"] == "前一句。")
        #expect(form.fields["context_after"] == "后一句。")
        #expect(form.fields["include_raw_transcript"] == "true")
        #expect(try Data(contentsOf: streamedAudioURL) == audioBytes)
    }

    @Test func dictateUploadRejectsUnsupportedAudioExtension() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-test-\(UUID().uuidString).wav")
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
}
