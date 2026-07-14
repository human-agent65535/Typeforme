import Foundation
import Testing
@testable import Typeforme

@Suite("TextEditService")
struct TextEditServiceTests {
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

    func correct(_ request: CorrectionRequest, timeoutMs: Int) async throws -> CorrectorOutput {
        throw CorrectorError.unavailable("Text-edit test stub does not correct transcripts")
    }

    func complete(
        system: String,
        messages: [CorrectorChatMessage],
        timeoutMs: Int
    ) async throws -> String {
        await recorder.record(timeoutMs: timeoutMs)
        return #"{"action":"replace_target","text":"fixed text"}"#
    }
}
