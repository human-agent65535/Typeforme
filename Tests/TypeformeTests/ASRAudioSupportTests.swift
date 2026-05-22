import Foundation
import Testing
@testable import Typeforme

@Suite("ASRAudioSupport")
struct ASRAudioSupportTests {
    @Test func stripsQwenASRTranscriptMarkers() {
        let text = "language English<asr_text>Hello, world.</asr_text>"
        #expect(ASRAudioSupport.cleanTranscriptText(text) == "Hello, world.")
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
}
