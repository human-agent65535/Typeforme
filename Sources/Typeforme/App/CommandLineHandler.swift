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
        if let provider = request.provider {
            overrides[AppSettings.Keys.asrProvider] = provider
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
                    provider: AppSettings.asrProvider,
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
                    provider: AppSettings.asrProvider,
                    languageIDs: AppSettings.asrLanguageIDs,
                    audioPath: request.audioURL.path,
                    latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                    transcript: nil,
                    error: error.localizedDescription
                )
                fputs((String(data: (try? BridgeJSON.encodePrettySorted(payload)) ?? Data(), encoding: .utf8) ?? error.localizedDescription) + "\n", stderr)
                Foundation.exit(2)
            }
        }
    }
}

struct DebugTranscribeCommand: Equatable {
    let audioURL: URL
    let provider: String?
    let languagesRaw: String?

    init?(arguments: [String]) {
        guard let commandIndex = arguments.firstIndex(of: "--debug-transcribe") else { return nil }
        let audioIndex = arguments.index(after: commandIndex)
        guard audioIndex < arguments.endIndex else {
            fputs("usage: Typeforme --debug-transcribe AUDIO [--provider PROVIDER] [--languages zh-CN,en-US]\n", stderr)
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

        self.provider = option("--provider")
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
