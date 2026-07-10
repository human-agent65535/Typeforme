import Foundation

enum CommandLineHandler {
    static func exitIfHandled(arguments: [String] = CommandLine.arguments) {
        if let request = DebugTranscribeCommand(arguments: Array(arguments.dropFirst())) {
            runDebugTranscribe(request)
            RunLoop.main.run()
        }

        let flags = Set(arguments.dropFirst())
        guard flags.contains("--version") || flags.contains("-v") else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        print("Typeforme \(version) (\(build))")
        Foundation.exit(0)
    }

    private static func runDebugTranscribe(_ request: DebugTranscribeCommand) {
        AppSettings.registerDefaults()
        var overrides = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let sources = request.sources {
            overrides[AppSettings.Keys.asrQwenEnabled] = sources.contains(.qwen)
            overrides[AppSettings.Keys.asrNvidiaNemotronEnabled] = sources.contains(.nvidiaNemotron)
            overrides[AppSettings.Keys.asrAppleSpeechEnabled] = sources.contains(.appleSpeech)
        }
        if let languages = request.languagesRaw {
            overrides[AppSettings.Keys.asrLanguageIDs] = languages
        }
        UserDefaults.standard.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)

        Task { @MainActor in
            let execution = await executeDebugTranscribe(
                request,
                provider: AppSettings.enabledRecognitionSources.map(\.rawValue).joined(separator: ","),
                languageIDs: AppSettings.asrLanguageIDs,
                transcribe: { audioURL, languageIDs in
                    try await ASRFactory.shared.get().transcribe(
                        audioFileURL: audioURL,
                        languageIDs: languageIDs
                    )
                },
                cleanup: {
                    await ASRFactory.shared.stopQwenLlama()
                    await NvidiaNemotronWarmPool.shared.shutdown(reason: "debug_transcribe_exit")
                    await CorrectorFactory.shared.shutdownAll()
                }
            )
            let data = (try? BridgeJSON.encodePrettySorted(execution.payload))
                ?? Data("{\"error\":\"Could not encode debug transcribe result\",\"ok\":false}".utf8)
            let output = String(decoding: data, as: UTF8.self)
            if execution.writesToStandardError {
                fputs(output + "\n", stderr)
            } else {
                print(output)
            }
            Foundation.exit(execution.exitCode)
        }
    }

    /// Runs the command's fallible work and then performs helper teardown on
    /// both success and failure. Keeping `exit` outside makes this ordering
    /// directly testable without terminating the test process.
    @MainActor
    static func executeDebugTranscribe(
        _ request: DebugTranscribeCommand,
        provider: String,
        languageIDs: [String],
        transcribe: @escaping @MainActor @Sendable (URL, [String]) async throws -> String,
        cleanup: @escaping @MainActor @Sendable () async -> Void
    ) async -> DebugTranscribeExecution {
        let startedAt = Date()
        let execution: DebugTranscribeExecution
        do {
            let text = try await transcribe(request.audioURL, languageIDs)
            execution = DebugTranscribeExecution(
                payload: DebugTranscribeResult(
                    ok: true,
                    provider: provider,
                    languageIDs: languageIDs,
                    audioPath: request.audioURL.path,
                    latencyMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                    transcript: text,
                    error: nil
                ),
                exitCode: 0,
                writesToStandardError: false
            )
        } catch {
            execution = DebugTranscribeExecution(
                payload: DebugTranscribeResult(
                    ok: false,
                    provider: provider,
                    languageIDs: languageIDs,
                    audioPath: request.audioURL.path,
                    latencyMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                    transcript: nil,
                    error: error.localizedDescription
                ),
                exitCode: 2,
                writesToStandardError: true
            )
        }
        await cleanup()
        return execution
    }
}

struct DebugTranscribeCommand: Equatable {
    let audioURL: URL
    let sources: [RecognitionSource]?
    let languagesRaw: String?

    init?(arguments: [String]) {
        guard let commandIndex = arguments.firstIndex(of: "--debug-transcribe") else { return nil }
        let audioIndex = arguments.index(after: commandIndex)
        guard audioIndex < arguments.endIndex else {
            fputs("usage: Typeforme --debug-transcribe AUDIO [--sources qwen3-asr-llama,nvidia-nemotron-asr,apple-speech] [--languages zh-CN,en-US]\n", stderr)
            Foundation.exit(64)
        }

        self.audioURL = URL(fileURLWithPath: NSString(string: arguments[audioIndex]).expandingTildeInPath)

        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name) else { return nil }
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else {
                fputs("missing value for \(name)\n", stderr)
                Foundation.exit(64)
            }
            return arguments[valueIndex]
        }

        if let rawSources = option("--sources") {
            let values = rawSources
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            let parsed = values.compactMap(RecognitionSource.init(rawValue:))
            guard parsed.count == values.count, !parsed.isEmpty else {
                fputs("invalid --sources value\n", stderr)
                Foundation.exit(64)
            }
            self.sources = RecognitionSource.normalizedSources(parsed.map(\.rawValue))
        } else {
            self.sources = nil
        }
        self.languagesRaw = option("--languages")
    }
}

struct DebugTranscribeExecution {
    let payload: DebugTranscribeResult
    let exitCode: Int32
    let writesToStandardError: Bool
}

struct DebugTranscribeResult: Encodable {
    let ok: Bool
    let provider: String
    let languageIDs: [String]
    let audioPath: String
    let latencyMs: Int
    let transcript: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case provider
        case languageIDs = "language_ids"
        case audioPath = "audio_path"
        case latencyMs = "latency_ms"
        case transcript
        case error
    }
}
