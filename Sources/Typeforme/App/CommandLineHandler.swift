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
            let startedAt = Date()
            do {
                let text = try await ASRFactory.shared.get().transcribe(
                    audioFileURL: request.audioURL,
                    languageIDs: AppSettings.asrLanguageIDs
                )
                let payload = DebugTranscribeResult(
                    ok: true,
                    provider: AppSettings.enabledRecognitionSources.map(\.rawValue).joined(separator: ","),
                    languageIDs: AppSettings.asrLanguageIDs,
                    audioPath: request.audioURL.path,
                    latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                    transcript: text,
                    error: nil
                )
                print(String(data: try BridgeJSON.encodePrettySorted(payload), encoding: .utf8) ?? "")
                Foundation.exit(0)
            } catch {
                let payload = DebugTranscribeResult(
                    ok: false,
                    provider: AppSettings.enabledRecognitionSources.map(\.rawValue).joined(separator: ","),
                    languageIDs: AppSettings.asrLanguageIDs,
                    audioPath: request.audioURL.path,
                    latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                    transcript: nil,
                    error: error.localizedDescription
                )
                let data: Data
                do {
                    data = try BridgeJSON.encodePrettySorted(payload)
                } catch {
                    preconditionFailure("Could not encode debug transcribe error payload: \(error)")
                }
                guard let output = String(data: data, encoding: .utf8) else {
                    preconditionFailure("Could not decode debug transcribe error payload as UTF-8")
                }
                fputs(output + "\n", stderr)
                Foundation.exit(2)
            }
        }
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

private struct DebugTranscribeResult: Encodable {
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
