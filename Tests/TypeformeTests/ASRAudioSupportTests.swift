import AVFoundation
import Foundation
import Testing
@testable import Typeforme

@Suite("ASRAudioSupport")
struct ASRAudioSupportTests {
    @Test func canonicalConversionProducesBounded16kMonoWAV() async throws {
        let input = try TestAudioFixtures.makeFLACFile()
        defer { try? FileManager.default.removeItem(at: input) }
        let output = try await ASRAudioSupport.wavUploadableAudioURL(for: input)
        defer { try? FileManager.default.removeItem(at: output) }

        let file = try AVAudioFile(forReading: output)
        let byteCount = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
        #expect(output.pathExtension == "wav")
        #expect(file.fileFormat.channelCount == 1)
        #expect(abs(file.fileFormat.sampleRate - 16_000) < 1)
        #expect(byteCount > 44)
        #expect(byteCount <= ASRAudioSupport.maximumCanonicalWAVBytes)
    }

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

    @Test func qwenASRUsesAutomaticLanguageDetectionForMultiLanguageSelection() {
        #expect(QwenLlamaASRService.languageAssistantPrefix(languageIDs: ["zh-CN", "en-US"]) == nil)
        #expect(QwenLlamaASRService.languageAssistantPrefix(languageIDs: ["zh-CN", "en-US", "vi"]) == nil)
        #expect(QwenLlamaASRService.languageAssistantPrefix(languageIDs: ["zh-CN", "en-US", "ja"]) == nil)
        #expect(QwenLlamaASRService.languageAssistantPrefix(languageIDs: ["auto"]) == nil)
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

    @Test func benignEmptyASRWarningsAreNotUserVisible() {
        let transcription = ASRTranscription(
            text: "hello",
            warnings: [
                "NVIDIA Nemotron ASR: ASR server returned an empty transcript",
                "Qwen3-ASR: No speech detected",
            ]
        )
        #expect(transcription.warningText == nil)
    }

    @Test func qwenWarmupSilenceWAVIs16kMonoPCM() throws {
        let url = try QwenLlamaASRService.writeWarmupSilenceWAVFile(sampleCount: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        #expect(ascii(data, 0..<4) == "RIFF")
        #expect(ascii(data, 8..<12) == "WAVE")
        #expect(ascii(data, 12..<16) == "fmt ")
        #expect(littleEndianUInt16(data, offset: 20) == 1)
        #expect(littleEndianUInt16(data, offset: 22) == 1)
        #expect(littleEndianUInt32(data, offset: 24) == 16_000)
        #expect(littleEndianUInt32(data, offset: 28) == 32_000)
        #expect(littleEndianUInt16(data, offset: 32) == 2)
        #expect(littleEndianUInt16(data, offset: 34) == 16)
        #expect(ascii(data, 36..<40) == "data")
        #expect(littleEndianUInt32(data, offset: 40) == 6)
        #expect(data[44..<50].allSatisfy { $0 == 0 })
    }

    @Test func qwenPreviewFloat32WAVIs16kMonoPCM() throws {
        var pcm = Data()
        for sample in [-1.0, 0.0, 0.5, 1.0] as [Float] {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { pcm.append(contentsOf: $0) }
        }

        let url = try QwenLlamaASRService.writePCM16kMonoFloat32WAVFile(pcm)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        #expect(ascii(data, 0..<4) == "RIFF")
        #expect(ascii(data, 8..<12) == "WAVE")
        #expect(littleEndianUInt16(data, offset: 20) == 1)
        #expect(littleEndianUInt16(data, offset: 22) == 1)
        #expect(littleEndianUInt32(data, offset: 24) == 16_000)
        #expect(littleEndianUInt16(data, offset: 34) == 16)
        #expect(littleEndianUInt32(data, offset: 40) == 8)
        #expect(littleEndianUInt16(data, offset: 44) == UInt16(bitPattern: Int16.min + 1))
        #expect(littleEndianUInt16(data, offset: 46) == 0)
        #expect(littleEndianUInt16(data, offset: 48) == UInt16(bitPattern: 16_384))
        #expect(littleEndianUInt16(data, offset: 50) == UInt16(bitPattern: Int16.max))
    }

    @Test func qwenLivePreviewUsesEightSecondRollingWindow() {
        #expect(QwenLlamaLivePreviewSession.rollingWindowStartSample(totalSamples: 16_000) == 0)
        #expect(QwenLlamaLivePreviewSession.rollingWindowStartSample(totalSamples: 128_000) == 0)
        #expect(QwenLlamaLivePreviewSession.rollingWindowStartSample(totalSamples: 160_000) == 32_000)
        #expect(!QwenLlamaLivePreviewSession.shouldRequestPreview(totalSamples: 15_999, lastRequestedSamples: 0, hasAudibleAudio: true))
        #expect(QwenLlamaLivePreviewSession.shouldRequestPreview(totalSamples: 16_000, lastRequestedSamples: 0, hasAudibleAudio: true))
        #expect(!QwenLlamaLivePreviewSession.shouldRequestPreview(totalSamples: 24_000, lastRequestedSamples: 16_000, hasAudibleAudio: true))
        #expect(QwenLlamaLivePreviewSession.shouldRequestPreview(totalSamples: 32_000, lastRequestedSamples: 16_000, hasAudibleAudio: true))
    }

    @Test @MainActor func finalASRRequiresRecordedAudio() async {
        let missingAudio = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-missing-final-audio-\(UUID().uuidString).flac")
        let service = ASRFactory.shared.get(sources: [.qwen])

        await #expect(throws: ASRAudioSupportError.self) {
            _ = try await service.transcribeResult(
                audioFileURL: missingAudio,
                languageIDs: ["en-US"]
            )
        }
    }

    @Test func qwenLivePreviewRegistryCancelsRegisteredAndPendingTasks() async {
        _ = await QwenLlamaLivePreviewTaskRegistry.shared.cancelAll()

        let registeredID = UUID()
        let registeredMarker = QwenPreviewRegistryMarker()
        QwenLlamaLivePreviewTaskRegistry.shared.reserve(id: registeredID)
        let registeredTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            await registeredMarker.markFinished()
        }

        #expect(QwenLlamaLivePreviewTaskRegistry.shared.install(registeredTask, id: registeredID))
        #expect(await QwenLlamaLivePreviewTaskRegistry.shared.cancelAll())
        #expect(await registeredMarker.isFinished)

        let pendingID = UUID()
        let pendingMarker = QwenPreviewRegistryMarker()
        QwenLlamaLivePreviewTaskRegistry.shared.reserve(id: pendingID)
        #expect(await QwenLlamaLivePreviewTaskRegistry.shared.cancelAll())

        let pendingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            await pendingMarker.markFinished()
        }
        #expect(!QwenLlamaLivePreviewTaskRegistry.shared.install(pendingTask, id: pendingID))
        await pendingTask.value
        #expect(await pendingMarker.isFinished)
    }

    @Test func nvidiaNemotronTargetLanguageUsesAutoForMixedSelection() {
        #expect(NvidiaNemotronASRService.targetLanguage(for: ["en-US"]) == "en-US")
        #expect(NvidiaNemotronASRService.targetLanguage(for: ["ja"]) == "ja-JP")
        #expect(NvidiaNemotronASRService.targetLanguage(for: ["no"]) == "nb-NO")
        #expect(NvidiaNemotronASRService.targetLanguage(for: ["zh-CN", "en-US"]) == "auto")
    }

    @Test func nvidiaNemotronDetectsDecodedChunkLog() {
        #expect(NvidiaNemotronLivePreviewSession.isDecodedChunkLog(
            "typeforme-nemotron-asr stream chunk=1 audio_ms=560 decode_ms=72 changed=false text_chars=0 flushing=false elapsed_ms=1583"
        ))
        #expect(!NvidiaNemotronLivePreviewSession.isDecodedChunkLog(
            "typeforme-nemotron-asr ready mode=Multilingual target_lang=auto load_ms=1027"
        ))
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

    private func ascii(_ data: Data, _ range: Range<Int>) -> String {
        String(data: data.subdata(in: range), encoding: .ascii) ?? ""
    }

    private func littleEndianUInt16(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

private actor QwenPreviewRegistryMarker {
    private var finished = false

    var isFinished: Bool {
        finished
    }

    func markFinished() {
        finished = true
    }
}
