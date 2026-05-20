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
    private enum StartupState {
        case idle
        case starting
        case ready
        case failed
    }

    private static let schemaID = "typeforme_pinyin"
    private static let appName = "rime.typeforme"
    private static let distributionName = "Typeforme"
    private static let distributionCodeName = "typeforme"
    private static let dataVersion = "pinyin-simp-v1"
    private static let candidateLimit: Int32 = 16
    private static var didSetup = false
    private static var didInitialize = false

    private let api = IRimeAPI()
    private let rimeQueue = DispatchQueue(label: "com.typeforme.keyboard.rime", qos: .userInitiated)
    private let stateLock = NSLock()
    private var startupState: StartupState = .idle
    private var didSelectSchema = false
    private var session: RimeSessionId = 0
    private var lastErrorMessage: String?
    private var desiredAsciiMode = false
    private var desiredAsciiPunctuation = false

    var onStateChange: ((RimeKeyboardState) -> Void)?

    var isReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return startupState == .ready && session != 0 && didSelectSchema && lastErrorMessage == nil
    }

    @discardableResult
    func startIfNeeded(bundle: Bundle = .main) -> Bool {
        if isReady { return true }
        stateLock.lock()
        if startupState == .starting {
            stateLock.unlock()
            return false
        }
        if startupState == .failed {
            stateLock.unlock()
            return false
        }
        startupState = .starting
        stateLock.unlock()

        rimeQueue.async { [weak self] in
            guard let self else { return }
            _ = self.startOnQueue(bundle: bundle)
            let nextState = self.stateOnQueue()
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(nextState)
            }
        }
        return false
    }

    private func startOnQueue(bundle: Bundle = .main) -> Bool {
        if isReadyOnQueue { return true }
        guard let sharedSupportURL = bundle.resourceURL?.appendingPathComponent("RimeSharedSupport", isDirectory: true),
              FileManager.default.fileExists(atPath: sharedSupportURL.path)
        else {
            finishStartupOnQueue(.failed, errorMessage: "中文数据缺失")
            rimeLog.error("RimeSharedSupport is missing from the keyboard bundle")
            return false
        }

        let prebuiltDataURL = sharedSupportURL.appendingPathComponent("build", isDirectory: true)
        guard FileManager.default.fileExists(atPath: prebuiltDataURL.appendingPathComponent("default.yaml").path) else {
            finishStartupOnQueue(.failed, errorMessage: "中文数据未编译")
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
                    finishStartupOnQueue(.failed, errorMessage: "中文输入暂不可用")
                    return false
                }
            }
            if !didSelectSchema {
                didSelectSchema = api.selectSchema(session, andSchameId: Self.schemaID)
                if !didSelectSchema {
                    finishStartupOnQueue(.failed, errorMessage: "中文数据不可用")
                    return false
                }
            }

            applyDesiredOptionsOnQueue()
            finishStartupOnQueue(.ready, errorMessage: nil)
            return true
        } catch {
            finishStartupOnQueue(.failed, errorMessage: "中文数据不可用")
            rimeLog.error("Failed to prepare Rime user data: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func setAsciiMode(_ enabled: Bool) -> RimeKeyboardState {
        stateLock.lock()
        desiredAsciiMode = enabled
        stateLock.unlock()
        guard startIfNeeded() else { return notReadyState() }
        return rimeQueue.sync {
            _ = api.setOption(session, andOption: "ascii_mode", andValue: enabled)
            return stateOnQueue()
        }
    }

    func setAsciiPunctuation(_ enabled: Bool) -> RimeKeyboardState {
        stateLock.lock()
        desiredAsciiPunctuation = enabled
        stateLock.unlock()
        guard startIfNeeded() else { return notReadyState() }
        return rimeQueue.sync {
            _ = api.setOption(session, andOption: "ascii_punct", andValue: enabled)
            return stateOnQueue()
        }
    }

    func processCharacter(_ character: String) -> RimeKeyboardState {
        guard startIfNeeded(),
              let scalar = character.unicodeScalars.first
        else { return notReadyState() }
        return rimeQueue.sync {
            _ = api.setOption(session, andOption: "ascii_mode", andValue: false)
            _ = api.processKeyCode(Int32(scalar.value), modifier: 0, andSession: session)
            return stateOnQueue(commitText: drainCommit())
        }
    }

    func processKeyCode(_ code: Int32) -> RimeKeyboardState {
        guard startIfNeeded() else { return notReadyState() }
        return rimeQueue.sync {
            _ = api.processKeyCode(code, modifier: 0, andSession: session)
            return stateOnQueue(commitText: drainCommit())
        }
    }

    func selectCandidate(at index: Int) -> RimeKeyboardState {
        guard startIfNeeded() else { return notReadyState() }
        return rimeQueue.sync {
            let didSelect = api.selectCandidate(session, andIndex: Int32(index))
            var commitText = drainCommit()
            if didSelect, commitText.isEmpty {
                _ = api.commitComposition(session)
                commitText = drainCommit()
            }
            return stateOnQueue(commitText: commitText)
        }
    }

    func commitComposition() -> RimeKeyboardState {
        guard startIfNeeded() else { return notReadyState() }
        return rimeQueue.sync {
            _ = api.commitComposition(session)
            return stateOnQueue(commitText: drainCommit())
        }
    }

    func clearComposition() -> RimeKeyboardState {
        guard startIfNeeded() else { return notReadyState() }
        return rimeQueue.sync {
            api.cleanComposition(session)
            return stateOnQueue()
        }
    }

    func state(commitText: String = "") -> RimeKeyboardState {
        guard startIfNeeded() else { return notReadyState(commitText: commitText) }
        return rimeQueue.sync {
            stateOnQueue(commitText: commitText)
        }
    }

    private var isReadyOnQueue: Bool {
        session != 0 && didSelectSchema && lastErrorMessage == nil
    }

    private func stateOnQueue(commitText: String = "") -> RimeKeyboardState {
        guard isReadyOnQueue,
              let status = api.getStatus(session),
              let context = api.getContext(session)
        else {
            return notReadyState(commitText: commitText)
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

    private func notReadyState(commitText: String = "") -> RimeKeyboardState {
        stateLock.lock()
        let errorMessage = lastErrorMessage
        stateLock.unlock()
        return RimeKeyboardState(
            isReady: false,
            isComposing: false,
            input: "",
            preedit: "",
            candidates: [],
            commitText: commitText,
            errorMessage: errorMessage
        )
    }

    private func finishStartupOnQueue(_ nextState: StartupState, errorMessage: String?) {
        stateLock.lock()
        startupState = nextState
        lastErrorMessage = errorMessage
        stateLock.unlock()
    }

    private func applyDesiredOptionsOnQueue() {
        stateLock.lock()
        let asciiMode = desiredAsciiMode
        let asciiPunctuation = desiredAsciiPunctuation
        stateLock.unlock()
        _ = api.setOption(session, andOption: "ascii_mode", andValue: asciiMode)
        _ = api.setOption(session, andOption: "ascii_punct", andValue: asciiPunctuation)
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
