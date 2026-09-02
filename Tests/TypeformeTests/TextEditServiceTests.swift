import Foundation
import Testing
@testable import Typeforme

@Suite("TextEditService")
struct TextEditServiceTests {
    @Test(arguments: [PunctuationOutputPreference.normal, .spaces, .english])
    @MainActor func pinyinSpacingIsNormalizedBeforeClausePunctuation(_ preference: PunctuationOutputPreference) async throws {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-pinyin-spacing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let configuration = CorrectionSessionConfiguration(
            corrector: TextEditCorrectorStub(
                recorder: TextEditCorrectorRecorder(),
                output: #"{"action":"replace_target","converted_segments":["林 霁，你 的 手 机 哪 里 买 的？\n我 用 Python 写 代 码，`保 留 空 格`"]}"#
            ),
            numberOutputPreference: .automatic,
            punctuationPreference: preference,
            timeoutMs: 500,
            userDictionary: []
        )
        let service = TextEditService(dictionary: UserDictionaryStore(url: dictionaryURL))
        let request = service.makeRequest(
            intent: .pinyinToChinese,
            contextBefore: "",
            targetText: "linjinideshoujinalimaidewoyongPythonxiedaima",
            contextAfter: "",
            spokenInstruction: "",
            languageIDs: ["zh-CN"],
            appName: nil,
            bundleID: nil,
            appCategory: .unknown,
            configuration: configuration
        )
        let result = try await service.edit(request, configuration: configuration)
        let expected: String
        switch preference {
        case .normal:
            expected = "林霁，你的手机哪里买的？\n我用 Python 写代码，`保 留 空 格`"
        case .spaces:
            expected = "林霁 你的手机哪里买的\n我用 Python 写代码 `保 留 空 格`"
        case .english:
            expected = "林霁, 你的手机哪里买的?\n我用 Python 写代码, `保 留 空 格`"
        }
        #expect(result.text == expected)
    }

    @Test @MainActor func spokenEditsPreserveIntentionalChineseSpacing() async throws {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-edit-spacing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let configuration = CorrectionSessionConfiguration(
            corrector: TextEditCorrectorStub(
                recorder: TextEditCorrectorRecorder(),
                output: #"{"action":"replace_target","text":"中 文 字 间 距"}"#
            ),
            numberOutputPreference: .automatic,
            punctuationPreference: .normal,
            timeoutMs: 500,
            userDictionary: []
        )
        let service = TextEditService(dictionary: UserDictionaryStore(url: dictionaryURL))
        let request = service.makeRequest(
            intent: .command,
            contextBefore: "",
            targetText: "中文字间距",
            contextAfter: "",
            spokenInstruction: "每个字之间加一个空格",
            languageIDs: ["zh-CN"],
            appName: nil,
            bundleID: nil,
            appCategory: .unknown,
            configuration: configuration
        )
        let result = try await service.edit(request, configuration: configuration)
        #expect(result.text == "中 文 字 间 距")
    }

    @Test @MainActor func capturedConfigurationOwnsPreferencesCorrectorAndTimeout() async throws {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-text-edit-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }

        let capturedRecorder = TextEditCorrectorRecorder()
        let replacementRecorder = TextEditCorrectorRecorder()
        let capturedDictionary = [DictionaryEntry(type: "project", surface: "Typeforme")]
        let replacementDictionary = [DictionaryEntry(type: "project", surface: "OtherName")]
        var currentConfiguration = CorrectionSessionConfiguration(
            corrector: TextEditCorrectorStub(recorder: capturedRecorder),
            numberOutputPreference: .digits,
            punctuationPreference: .english,
            timeoutMs: 432,
            userDictionary: capturedDictionary
        )
        let capturedConfiguration = currentConfiguration
        currentConfiguration = CorrectionSessionConfiguration(
            corrector: TextEditCorrectorStub(recorder: replacementRecorder),
            numberOutputPreference: .words,
            punctuationPreference: .spaces,
            timeoutMs: 9_999,
            userDictionary: replacementDictionary
        )

        let service = TextEditService(dictionary: UserDictionaryStore(url: dictionaryURL))
        let request = service.makeRequest(
            intent: .repairSelection,
            contextBefore: "before",
            targetText: "bad text",
            contextAfter: "after",
            spokenInstruction: "fix it",
            languageIDs: ["en-US"],
            appName: "Editor",
            bundleID: "com.example.editor",
            appCategory: .unknown,
            configuration: capturedConfiguration
        )
        let result = try await service.edit(
            request,
            configuration: capturedConfiguration
        )
        let capturedTimeouts = await capturedRecorder.timeouts()
        let replacementTimeouts = await replacementRecorder.timeouts()

        #expect(currentConfiguration.timeoutMs == 9_999)
        #expect(request.numberOutputPreference == .digits)
        #expect(request.punctuationPreference == .english)
        #expect(request.userDictionary == capturedDictionary)
        #expect(result.action == .replaceTarget)
        #expect(result.text == "fixed text")
        #expect(capturedTimeouts == [432])
        #expect(replacementTimeouts.isEmpty)
    }
}

private actor TextEditCorrectorRecorder {
    private var recordedTimeouts: [Int] = []

    func record(timeoutMs: Int) {
        recordedTimeouts.append(timeoutMs)
    }

    func timeouts() -> [Int] {
        recordedTimeouts
    }
}

private struct TextEditCorrectorStub: CorrectorService {
    let kind: CorrectionBackendKind = .externalOpenAICompatible
    let recorder: TextEditCorrectorRecorder
    var output = #"{"action":"replace_target","text":"fixed text"}"#

    func correct(_ request: CorrectionRequest, timeoutMs: Int) async throws -> CorrectorOutput {
        throw CorrectorError.unavailable("Text-edit test stub does not correct transcripts")
    }

    func complete(
        system: String,
        messages: [CorrectorChatMessage],
        timeoutMs: Int
    ) async throws -> String {
        await recorder.record(timeoutMs: timeoutMs)
        return output
    }
}
