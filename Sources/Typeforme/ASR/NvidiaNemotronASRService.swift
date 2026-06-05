import Foundation

final class NvidiaNemotronASRService: ASRService {
    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        let supportedLanguageIDs = ASRLanguageSelection.validatedIDs(
            languageIDs,
            supportedOptions: ASRLanguageSelection.nvidiaNemotronASRSupportedLanguages
        )
        let runtimeStatus = Self.bundledRuntimeStatus()
        guard runtimeStatus.isReady,
              let runnerURL = runtimeStatus.runnerURL
        else {
            throw ASRAudioSupportError.httpStatus(503, runtimeStatus.errorDetail)
        }
        let modelDirURL = try Self.stageModelDirectory(runtimeStatus)
        defer { try? FileManager.default.removeItem(at: modelDirURL) }

        let uploadURL = try await ASRAudioSupport.wavUploadableAudioURL(for: audioFileURL)
        defer {
            if uploadURL != audioFileURL {
                try? FileManager.default.removeItem(at: uploadURL)
            }
        }

        let targetLanguage = Self.targetLanguage(for: supportedLanguageIDs)
        let result = try await Self.run(
            command: NvidiaASRCommand(
                executablePath: runnerURL.path,
                arguments: [
                    "--model-dir",
                    modelDirURL.path,
                    "--audio",
                    uploadURL.path,
                    "--target-lang",
                    targetLanguage,
                ]
            ),
            timeout: AppSettings.asrNvidiaNemotronTimeoutSeconds
        )

        guard result.exitCode == 0 else {
            let detail = result.errorDetail.isEmpty
                ? "runner exited with \(result.exitCode)"
                : result.errorDetail
            throw ASRAudioSupportError.httpStatus(503, detail)
        }

        let text = Self.parseTranscript(stdout: result.stdout)
        guard !text.isEmpty else {
            throw ASRAudioSupportError.emptyTranscript
        }
        return LocaleTextNormalizer.normalize(text, languageIDs: supportedLanguageIDs)
    }

    static func targetLanguage(for languageIDs: [String]) -> String {
        let ids = ASRLanguageSelection.validatedIDs(
            languageIDs,
            supportedOptions: ASRLanguageSelection.nvidiaNemotronASRSupportedLanguages
        )
        guard ids.count == 1, let locale = nemotronLocale(for: ids[0]) else {
            return "auto"
        }
        return locale
    }

    static func bundledRuntimeStatus() -> NvidiaNemotronASRRuntimeStatus {
        runtimeStatus(
            runnerURL: AppPaths.bundledNvidiaNemotronRunner,
            modelFiles: NvidiaNemotronASRModelCatalog
                .spec(for: AppSettings.asrNvidiaNemotronModelID)
                .files
                .map { file in
                    NvidiaNemotronASRModelFileStatus(
                        spec: file,
                        url: URL(fileURLWithPath: AppSettings.asrNvidiaNemotronPath(for: file))
                    )
                }
        )
    }

    static func runtimeStatus(
        runnerURL: URL?,
        modelFiles: [NvidiaNemotronASRModelFileStatus],
        fileManager: FileManager = .default
    ) -> NvidiaNemotronASRRuntimeStatus {
        let runnerReady = runnerURL.map { fileManager.isExecutableFile(atPath: $0.path) } ?? false
        let resolvedFiles = modelFiles.map { file in
            NvidiaNemotronASRModelFileStatus(
                spec: file.spec,
                url: file.url,
                installed: Self.isInstalledModelFile(file, fileManager: fileManager)
            )
        }
        return NvidiaNemotronASRRuntimeStatus(
            runnerURL: runnerURL,
            runnerReady: runnerReady,
            modelFiles: resolvedFiles
        )
    }

    private static func stageModelDirectory(_ status: NvidiaNemotronASRRuntimeStatus) throws -> URL {
        try AppPaths.ensureDirectories()
        let dir = AppPaths.asrWorkDir.appendingPathComponent("typeforme-nemotron-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in status.modelFiles {
            let link = dir.appendingPathComponent(file.spec.filename)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file.url)
        }
        return dir
    }

    private static func isInstalledModelFile(
        _ file: NvidiaNemotronASRModelFileStatus,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: file.url.path) else { return false }
        guard file.spec.expectedBytes > 0 else { return true }
        do {
            let actual = try ModelDownloadIntegrity.byteCount(of: file.url)
            return actual == file.spec.expectedBytes
        } catch {
            return false
        }
    }

    private static func run(command: NvidiaASRCommand, timeout: TimeInterval) async throws -> NvidiaASRProcessResult {
        try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.isExecutableFile(atPath: command.executablePath) else {
                throw ASRAudioSupportError.httpStatus(503, "NVIDIA Nemotron ASR runtime is missing or not executable")
            }

            try AppPaths.ensureDirectories()
            let stdoutURL = AppPaths.asrWorkDir.appendingPathComponent("typeforme-nvidia-asr-\(UUID().uuidString).out")
            let stderrURL = AppPaths.asrWorkDir.appendingPathComponent("typeforme-nvidia-asr-\(UUID().uuidString).err")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            defer {
                try? FileManager.default.removeItem(at: stdoutURL)
                try? FileManager.default.removeItem(at: stderrURL)
            }

            let stdout = try FileHandle(forWritingTo: stdoutURL)
            let stderr = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdout.close()
                try? stderr.close()
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executablePath)
            process.arguments = command.arguments
            process.standardOutput = stdout
            process.standardError = stderr

            let semaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in semaphore.signal() }
            try process.run()

            let deadline = DispatchTime.now() + timeout
            if semaphore.wait(timeout: deadline) == .timedOut {
                process.terminate()
                _ = semaphore.wait(timeout: .now() + 2)
                throw ASRAudioSupportError.timeout(seconds: timeout)
            }

            try? stdout.synchronize()
            try? stderr.synchronize()
            let stdoutText = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
            let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            return NvidiaASRProcessResult(
                exitCode: process.terminationStatus,
                stdout: stdoutText,
                stderr: stderrText
            )
        }.value
    }

    private static func parseTranscript(stdout: String) -> String {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let text = parseJSONTranscript(trimmed) {
            return ASRAudioSupport.cleanTranscriptText(text)
        }
        for line in trimmed.components(separatedBy: .newlines).reversed() {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if let text = parseJSONTranscript(value) {
                return ASRAudioSupport.cleanTranscriptText(text)
            }
            return ASRAudioSupport.cleanTranscriptText(value)
        }
        return ""
    }

    private static func parseJSONTranscript(_ value: String) -> String? {
        guard let data = value.data(using: .utf8),
              let payload = try? BridgeJSON.decode(NvidiaASRTranscriptPayload.self, from: data)
        else { return nil }
        return payload.textValue
    }

    private static func nemotronLocale(for id: String) -> String? {
        switch id {
        case "ar": return "ar-AR"
        case "bg": return "bg-BG"
        case "cs": return "cs-CZ"
        case "da": return "da-DK"
        case "de": return "de-DE"
        case "el": return "el-GR"
        case "en-US": return "en-US"
        case "es": return "es-ES"
        case "et": return "et-EE"
        case "fi": return "fi-FI"
        case "fr": return "fr-FR"
        case "he": return "he-IL"
        case "hi": return "hi-IN"
        case "hr": return "hr-HR"
        case "hu": return "hu-HU"
        case "it": return "it-IT"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "lt": return "lt-LT"
        case "lv": return "lv-LV"
        case "mt": return "mt-MT"
        case "nl": return "nl-NL"
        case "no": return "nb-NO"
        case "pl": return "pl-PL"
        case "pt": return "pt-BR"
        case "ro": return "ro-RO"
        case "ru": return "ru-RU"
        case "sk": return "sk-SK"
        case "sl": return "sl-SI"
        case "sv": return "sv-SE"
        case "th": return "th-TH"
        case "tr": return "tr-TR"
        case "uk": return "uk-UA"
        case "vi": return "vi-VN"
        case "zh-CN": return "zh-CN"
        default: return nil
        }
    }

}

private struct NvidiaASRCommand {
    let executablePath: String
    let arguments: [String]
}

struct NvidiaNemotronASRRuntimeStatus: Equatable {
    let runnerURL: URL?
    let runnerReady: Bool
    let modelFiles: [NvidiaNemotronASRModelFileStatus]

    var isReady: Bool {
        runnerReady && missingModelFiles.isEmpty
    }

    var missingModelFiles: [String] {
        modelFiles.filter { !$0.installed }.map(\.spec.filename)
    }

    var installedFileCount: Int {
        (runnerReady ? 1 : 0) + modelFiles.filter(\.installed).count
    }

    var expectedFileCount: Int {
        1 + modelFiles.count
    }

    var detail: String {
        if isReady {
            return "Ready"
        }
        return errorDetail
    }

    var errorDetail: String {
        var parts: [String] = []
        if let runnerURL {
            if !runnerReady {
                parts.append("Nemotron runtime is missing or not executable")
            }
        } else {
            parts.append("Nemotron runtime is missing from the app bundle")
        }

        if !missingModelFiles.isEmpty {
            parts.append("Nemotron model is missing or incomplete")
        }

        return parts.isEmpty ? "Bundled Nemotron runtime is unavailable" : parts.joined(separator: "; ")
    }
}

struct NvidiaNemotronASRModelFileStatus: Equatable {
    let spec: NvidiaNemotronASRFileSpec
    let url: URL
    var installed: Bool = false
}

private struct NvidiaASRProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var errorDetail: String {
        stderr
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .suffix(6)
            .joined(separator: "\n")
    }
}

private struct NvidiaASRTranscriptPayload: Decodable {
    struct Segment: Decodable {
        let text: String?
    }

    let text: String?
    let transcript: String?
    let transcription: String?
    let segments: [Segment]?

    var textValue: String? {
        if let text { return text }
        if let transcript { return transcript }
        if let transcription { return transcription }
        let combined = segments?.compactMap(\.text).joined(separator: " ")
        return combined?.isEmpty == false ? combined : nil
    }
}
