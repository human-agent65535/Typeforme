import Darwin
import Foundation
import Testing
@testable import Typeforme

@Suite("AI Writing decoder")
struct AIWritingDecoderTests {
    @Test(arguments: NumberOutputPreference.allCases, PunctuationOutputPreference.allCases)
    func numberAndPunctuationPreferencesPreserveDraftLayout(_ numbers: NumberOutputPreference, _ punctuation: PunctuationOutputPreference) throws {
        let source = "  womaile36gebenzi,  meige4.5yuan.\n"
        let converted = try ["我买了36个本子,", "每个4.5元."].map {
            try AIWritingOutputFormatter.format($0, numbers: numbers, punctuation: punctuation)
        }
        let result = try PinyinDraftLayout(source).replacement(from: converted, languageIDs: ["zh-CN"], punctuationPreference: punctuation)
        let count = numbers == .words ? "三十六" : "36"
        switch punctuation {
        case .normal: #expect(result == "  我买了\(count)个本子，  每个4.5元。\n")
        case .english: #expect(result == "  我买了\(count)个本子,  每个4.5元.\n")
        case .spaces: #expect(result == "  我买了\(count)个本子  每个4.5元\n")
        }
    }

    @Test func numbersKeepIdiomsDatesAndTechnicalLiterals() throws {
        let text = "一起看三十六个本子，两个箱子 2026-09-03 09:45 4.5元 v1.2.3 https://example.com?q=36 `36个`"
        let result = try AIWritingOutputFormatter.format(text, numbers: .digits, punctuation: .normal)
        #expect(result == "一起看36个本子，2个箱子 2026-09-03 09:45 4.5元 v1.2.3 https://example.com?q=36 `36个`")
        let english = "Can you review this patch?"
        #expect(try AIWritingOutputFormatter.format(english, numbers: .words, punctuation: .normal) == english)
    }

    @Test @MainActor func localDecoderIsUsedOnlyForPinyinAndGetsWholeDraft() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("typeforme-decoder-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = DecoderStub()
        let service = TextEditService(dictionary: UserDictionaryStore(url: url), aiWritingDecoder: decoder)
        let configuration = CorrectionSessionConfiguration(
            corrector: PromptStub(), numberOutputPreference: .automatic,
            punctuationPreference: .normal, timeoutMs: 500, userDictionary: [],
            aiWriting: .pinyinDecoder(Self.runtime)
        )
        let request = service.makeRequest(intent: .pinyinToChinese, contextBefore: "前文",
            targetText: "你好  nizaima?", contextAfter: "后文", spokenInstruction: "",
            languageIDs: ["zh-CN"], appName: nil, bundleID: nil, appCategory: .unknown, configuration: configuration)
        let result = try await service.edit(request, configuration: configuration)
        #expect(result.text == "你好  你在吗？")
        let received = await decoder.received
        #expect(received?.targetText == "你好  nizaima?")
        #expect(received?.contextBefore == "前文")
        let command = service.makeRequest(intent: .command, contextBefore: "", targetText: "draft",
            contextAfter: "", spokenInstruction: "fix", languageIDs: ["en-US"],
            appName: nil, bundleID: nil, appCategory: .unknown, configuration: configuration)
        #expect(try await service.edit(command, configuration: configuration).text == "fixed")
        #expect(await decoder.calls == 1)
    }

    @Test @MainActor func missingOrFailedDecoderNeverUsesPromptFallback() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("typeforme-decoder-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let service = TextEditService(dictionary: UserDictionaryStore(url: url), aiWritingDecoder: DecoderStub(shouldFail: true))
        for runtime in [nil, Self.runtime] {
            let configuration = CorrectionSessionConfiguration(
                corrector: PromptStub(), numberOutputPreference: .automatic,
                punctuationPreference: .normal, timeoutMs: 500, userDictionary: [],
                aiWriting: .pinyinDecoder(runtime)
            )
            let request = service.makeRequest(intent: .pinyinToChinese, contextBefore: "", targetText: "nihao",
                contextAfter: "", spokenInstruction: "", languageIDs: ["zh-CN"],
                appName: nil, bundleID: nil, appCategory: .unknown, configuration: configuration)
            await #expect(throws: AIWritingDecoderError.self) {
                try await service.edit(request, configuration: configuration)
            }
        }
    }

    @Test func lineWorkerReusesProcessWithoutCrossingReplies() async throws {
        let worker = try AIWritingLineWorker(executable: "/usr/bin/python3", arguments: ["-u", "-c", """
        import os, sys, json
        os.setpgid(0, 0)
        for line in sys.stdin:
            value = json.loads(line)
            print(json.dumps(dict(id=value['id'], pid=os.getpid())), flush=True)
        """])
        defer { worker.stop() }
        let first = try await worker.query(Data(#"{"id":"first"}"#.utf8), timeout: 5)
        let second = try await worker.query(Data(#"{"id":"second"}"#.utf8), timeout: 5)
        let one = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let two = try #require(JSONSerialization.jsonObject(with: second) as? [String: Any])
        #expect(one["id"] as? String == "first")
        #expect(two["id"] as? String == "second")
        #expect(one["pid"] as? Int == two["pid"] as? Int)
    }

    @Test func deadlineTerminatesOwnedNativeChildren() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("typeforme-decoder-child-\(UUID())")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let worker = try AIWritingLineWorker(executable: "/usr/bin/python3", arguments: ["-u", "-c", """
        import os, pathlib, subprocess, sys, time
        os.setpgid(0, 0)
        child = subprocess.Popen(['/bin/sleep', '30'])
        pathlib.Path(sys.argv[1]).write_text(str(child.pid))
        time.sleep(30)
        """, pidFile.path])
        defer { worker.stop() }
        do {
            _ = try await worker.query(Data("{}".utf8), timeout: 1)
            Issue.record("An unanswered decoder request must time out")
        } catch {
            #expect(error as? AIWritingDecoderError == .timedOut)
        }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        for _ in 0..<40 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(kill(pid, 0) != 0)
        #expect(worker.isClosed)
    }

    @Test func cancellationDoesNotWaitForDecoderDeadline() async throws {
        let worker = try AIWritingLineWorker(executable: "/usr/bin/python3", arguments: ["-u", "-c", "import os,time; os.setpgid(0,0); time.sleep(30)"])
        defer { worker.stop() }
        let task = Task { try await worker.query(Data("{}".utf8), timeout: 20) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(worker.isClosed)
    }

    private static let runtime = AIWritingDecoderConfiguration(version: 1, python: "/unused/python", script: "/unused/decode.py",
        tools: "/unused/tools", rimeData: "/unused/rime", grammar: "/unused/grammar", plugin: "/unused/plugin",
        model: "/unused/model", backendDirectory: "/unused/backend")
}

private actor DecoderStub: AIWritingDecoding {
    var received: TextEditRequest?
    var calls = 0
    let shouldFail: Bool
    init(shouldFail: Bool = false) { self.shouldFail = shouldFail }
    func decode(_ request: TextEditRequest, configuration: AIWritingDecoderConfiguration) async throws -> [String] {
        if shouldFail { throw AIWritingDecoderError.failed }
        received = request
        calls += 1
        return ["你好", "你在吗?"]
    }
}

private struct PromptStub: CorrectorService {
    let kind = CorrectionBackendKind.externalOpenAICompatible
    func correct(_ request: CorrectionRequest, timeoutMs: Int) async throws -> CorrectorOutput {
        throw AIWritingDecoderError.failed
    }
    func complete(system: String, messages: [CorrectorChatMessage], timeoutMs: Int) async throws -> String {
        #"{"action":"replace_target","text":"fixed"}"#
    }
}
