import Foundation
import LibrimeKit
import OSLog

private let rimeLog = Logger(subsystem: "com.typeforme.keyboard", category: "rime")

struct RimeKeyboardCandidate {
    let text: String
    let comment: String
}

struct RimeKeyboardState {
    let isReady: Bool
    let isComposing: Bool
    let input: String
    let preedit: String
    let candidates: [RimeKeyboardCandidate]
    let commitText: String
    let errorMessage: String?
}

final class RimeInputController {
    private static let schemaID = "typeforme_pinyin"
    private static let appName = "rime.typeforme"
    private static let distributionName = "Typeforme"
    private static let distributionCodeName = "typeforme"
    private static let dataVersion = "pinyin-simp-v1"
    private static let candidateLimit: Int32 = 16
    private static var didSetup = false
    private static var didInitialize = false

    private let api = IRimeAPI()
    private var didSelectSchema = false
    private var session: RimeSessionId = 0
    private var lastErrorMessage: String?

    var isReady: Bool {
        session != 0 && didSelectSchema && lastErrorMessage == nil
    }

    @discardableResult
    func startIfNeeded(bundle: Bundle = .main) -> Bool {
        if isReady { return true }

        guard let sharedSupportURL = bundle.resourceURL?.appendingPathComponent("RimeSharedSupport", isDirectory: true),
              FileManager.default.fileExists(atPath: sharedSupportURL.path)
        else {
            lastErrorMessage = "中文数据缺失"
            rimeLog.error("RimeSharedSupport is missing from the keyboard bundle")
            return false
        }

        let prebuiltDataURL = sharedSupportURL.appendingPathComponent("build", isDirectory: true)
        guard FileManager.default.fileExists(atPath: prebuiltDataURL.appendingPathComponent("default.yaml").path) else {
            lastErrorMessage = "中文数据未编译"
            rimeLog.error("Rime prebuilt data is missing from RimeSharedSupport/build")
            return false
        }

        do {
            // The keyboard extension must only open prebuilt Rime data. Do not
            // run librime maintenance or deployment synchronously here: first
            // launch has to stay inside the extension watchdog budget.
            let userDataURL = try ensureUserDataDirectory()
            let traits = IRimeTraits()
            traits.sharedDataDir = sharedSupportURL.path
            traits.userDataDir = userDataURL.path
            traits.prebuiltDataDir = prebuiltDataURL.path
            traits.stagingDir = userDataURL.appendingPathComponent("build", isDirectory: true).path
            traits.distributionName = Self.distributionName
            traits.distributionCodeName = Self.distributionCodeName
            traits.distributionVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            traits.appName = Self.appName

            if !Self.didSetup {
                api.setup(traits)
                Self.didSetup = true
            }
            if !Self.didInitialize {
                api.initialize(traits)
                Self.didInitialize = true
            }
            if session == 0 {
                session = api.createSession()
                guard session != 0 else {
                    lastErrorMessage = "中文输入暂不可用"
                    return false
                }
            }
            if !didSelectSchema {
                didSelectSchema = api.selectSchema(session, andSchameId: Self.schemaID)
                if !didSelectSchema {
                    lastErrorMessage = "中文数据不可用"
                    return false
                }
            }

            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "中文数据不可用"
            rimeLog.error("Failed to prepare Rime user data: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func setAsciiMode(_ enabled: Bool) -> RimeKeyboardState {
        guard startIfNeeded() else { return state() }
        _ = api.setOption(session, andOption: "ascii_mode", andValue: enabled)
        return state()
    }

    func setAsciiPunctuation(_ enabled: Bool) -> RimeKeyboardState {
        guard startIfNeeded() else { return state() }
        _ = api.setOption(session, andOption: "ascii_punct", andValue: enabled)
        return state()
    }

    func processCharacter(_ character: String) -> RimeKeyboardState {
        guard startIfNeeded(),
              let scalar = character.unicodeScalars.first
        else { return state() }
        _ = api.setOption(session, andOption: "ascii_mode", andValue: false)
        _ = api.processKeyCode(Int32(scalar.value), modifier: 0, andSession: session)
        return state(commitText: drainCommit())
    }

    func processKeyCode(_ code: Int32) -> RimeKeyboardState {
        guard startIfNeeded() else { return state() }
        _ = api.processKeyCode(code, modifier: 0, andSession: session)
        return state(commitText: drainCommit())
    }

    func selectCandidate(at index: Int) -> RimeKeyboardState {
        guard startIfNeeded() else { return state() }
        let didSelect = api.selectCandidate(session, andIndex: Int32(index))
        var commitText = drainCommit()
        if didSelect, commitText.isEmpty {
            _ = api.commitComposition(session)
            commitText = drainCommit()
        }
        return state(commitText: commitText)
    }

    func commitComposition() -> RimeKeyboardState {
        guard startIfNeeded() else { return state() }
        _ = api.commitComposition(session)
        return state(commitText: drainCommit())
    }

    func clearComposition() -> RimeKeyboardState {
        guard startIfNeeded() else { return state() }
        api.cleanComposition(session)
        return state()
    }

    func state(commitText: String = "") -> RimeKeyboardState {
        guard startIfNeeded(),
              let status = api.getStatus(session),
              let context = api.getContext(session)
        else {
            return RimeKeyboardState(
                isReady: false,
                isComposing: false,
                input: "",
                preedit: "",
                candidates: [],
                commitText: commitText,
                errorMessage: lastErrorMessage
            )
        }

        let input = api.getInput(session) ?? ""
        let preedit = context.composition?.preedit ?? input
        let menuCandidates = context.menu?.candidates ?? []
        let fullCandidateList = api.getCandidateList(session) ?? []
        let rawCandidates = !menuCandidates.isEmpty
            ? menuCandidates
            : (fullCandidateList.isEmpty
                ? (api.getCandidateWith(0, andCount: Self.candidateLimit, andSession: session) ?? [])
                : fullCandidateList)
        var candidates = rawCandidates.prefix(Int(Self.candidateLimit))
            .compactMap { candidate -> RimeKeyboardCandidate? in
                guard let text = candidate.text, !text.isEmpty else { return nil }
                return RimeKeyboardCandidate(text: text, comment: candidate.comment ?? "")
            }
        if candidates.isEmpty,
           let preview = context.commitTextPreview,
           !preview.isEmpty,
           preview != input {
            candidates = [RimeKeyboardCandidate(text: preview, comment: "")]
        }

        return RimeKeyboardState(
            isReady: true,
            isComposing: status.isComposing || !input.isEmpty,
            input: input,
            preedit: preedit,
            candidates: candidates,
            commitText: commitText,
            errorMessage: nil
        )
    }

    private func drainCommit() -> String {
        api.getCommit(session) ?? ""
    }

    private func ensureUserDataDirectory() throws -> URL {
        // This target currently has no App Group entitlement. A guessed group
        // identifier will silently fail on real provisioning profiles, so keep
        // Rime user data in the extension sandbox until host+keyboard entitlements
        // define an explicit shared container.
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let userDataURL = baseURL
            .appendingPathComponent("Rime", isDirectory: true)
            .appendingPathComponent(Self.dataVersion, isDirectory: true)
        try FileManager.default.createDirectory(at: userDataURL, withIntermediateDirectories: true)
        return userDataURL
    }
}
