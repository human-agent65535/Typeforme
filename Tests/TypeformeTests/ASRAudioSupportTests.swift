import Foundation
import Testing
@testable import Typeforme

@Suite("ASRAudioSupport")
struct ASRAudioSupportTests {
    @Test func stripsQwenASRTranscriptMarkers() {
        let text = "language English<asr_text>Hello, world.</asr_text>"
        #expect(ASRAudioSupport.cleanTranscriptText(text) == "Hello, world.")
    }

    @Test func stripsNemotronLanguageTag() {
        #expect(ASRAudioSupport.cleanTranscriptText("Hello, world. <en-US>") == "Hello, world.")
    }

    @Test func parsesLlamaChatASRResponse() throws {
        let data = #"{"choices":[{"message":{"role":"assistant","content":"language Chinese<asr_text>你好，世界。</asr_text>"}}]}"#.data(using: .utf8)!
        #expect(try QwenLlamaASRService.parseChatTranscript(data: data) == "你好，世界。")
    }

    @Test func parsesLlamaChatASRContentArrayResponse() throws {
        let data = #"{"choices":[{"message":{"role":"assistant","content":[{"type":"text","text":"language Chinese<asr_text>你好，世界。</asr_text>"}]}}]}"#.data(using: .utf8)!
        #expect(try QwenLlamaASRService.parseChatTranscript(data: data) == "你好，世界。")
    }

    @Test func qwenASRConstrainsLanguageCombosWithAssistantPrefix() {
        #expect(QwenLlamaASRService.languageAssistantPrefix(languageIDs: ["zh-CN", "en-US"]) == "language Chinese, English<asr_text>")
        #expect(QwenLlamaASRService.languageAssistantPrefix(languageIDs: ["zh-CN", "en-US", "vi"]) == "language Vietnamese, Chinese, English<asr_text>")
        #expect(QwenLlamaASRService.languageAssistantPrefix(languageIDs: ["zh-CN", "en-US", "ja"]) == "language Japanese, Chinese, English<asr_text>")
    }

    @Test func qwenASRUsesForcedPrefixForSingleLanguage() {
        #expect(QwenLlamaASRService.languageAssistantPrefix(languageIDs: ["zh-CN"]) == "language Chinese<asr_text>")
        #expect(QwenLlamaASRService.languageAssistantPrefix(languageIDs: ["vi"]) == "language Vietnamese<asr_text>")
        #expect(QwenLlamaASRService.languageAssistantPrefix(languageIDs: ["ja"]) == "language Japanese<asr_text>")
        #expect(QwenLlamaASRService.languageAssistantPrefix(languageIDs: ["tl"]) == "language Filipino<asr_text>")
    }

    @Test func qwenRetriesOnlyTransientASRErrors() {
        #expect(QwenLlamaASRService.shouldRetryTransientASRError(ASRAudioSupportError.emptyTranscript, attempt: 1))
        #expect(QwenLlamaASRService.shouldRetryTransientASRError(ASRAudioSupportError.httpStatus(503, "busy"), attempt: 1))
        #expect(QwenLlamaASRService.shouldRetryTransientASRError(URLError(.networkConnectionLost), attempt: 1))

        #expect(!QwenLlamaASRService.shouldRetryTransientASRError(ASRAudioSupportError.emptyTranscript, attempt: 2))
        #expect(!QwenLlamaASRService.shouldRetryTransientASRError(ASRAudioSupportError.timeout(seconds: 120), attempt: 1))
        #expect(!QwenLlamaASRService.shouldRetryTransientASRError(ASRAudioSupportError.audioConversionFailed("bad audio"), attempt: 1))
        #expect(!QwenLlamaASRService.shouldRetryTransientASRError(ASRAudioSupportError.httpStatus(400, "bad request"), attempt: 1))
    }

    @Test func nvidiaNemotronTargetLanguageUsesAutoForMixedSelection() {
        #expect(NvidiaNemotronASRService.targetLanguage(for: ["en-US"]) == "en-US")
        #expect(NvidiaNemotronASRService.targetLanguage(for: ["ja"]) == "ja-JP")
        #expect(NvidiaNemotronASRService.targetLanguage(for: ["no"]) == "nb-NO")
        #expect(NvidiaNemotronASRService.targetLanguage(for: ["zh-CN", "en-US"]) == "auto")
    }

    @Test func nvidiaNemotronRuntimeStatusRequiresBundledHelperAndModelFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeforme-nemotron-test-\(UUID().uuidString)", isDirectory: true)
        let modelDir = root.appendingPathComponent("model", isDirectory: true)
        let runner = root.appendingPathComponent(NvidiaNemotronASRModelCatalog.bundledHelperName)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: runner.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
        let files = NvidiaNemotronASRModelCatalog
            .spec(for: NvidiaNemotronASRModelCatalog.defaultID)
            .files
            .map { file in
                NvidiaNemotronASRFileSpec(
                    id: file.id,
                    label: file.label,
                    filename: file.filename,
                    pathKey: file.pathKey,
                    urlKey: file.urlKey,
                    defaultPath: file.defaultPath,
                    defaultURL: file.defaultURL,
                    expectedBytes: 0
                )
            }
        for file in files {
            FileManager.default.createFile(atPath: modelDir.appendingPathComponent(file.filename).path, contents: Data())
        }

        var status = NvidiaNemotronASRService.runtimeStatus(
            runnerURL: runner,
            modelFiles: files.map {
                NvidiaNemotronASRModelFileStatus(spec: $0, url: modelDir.appendingPathComponent($0.filename))
            }
        )
        #expect(status.isReady)

        try FileManager.default.removeItem(at: modelDir.appendingPathComponent("tokenizer.model"))
        status = NvidiaNemotronASRService.runtimeStatus(
            runnerURL: runner,
            modelFiles: files.map {
                NvidiaNemotronASRModelFileStatus(spec: $0, url: modelDir.appendingPathComponent($0.filename))
            }
        )
        #expect(!status.isReady)
        #expect(status.missingModelFiles == ["tokenizer.model"])
    }
}
