import CryptoKit
import Foundation
import LibrimeKit
import OSLog

private let rimeLog = Logger(subsystem: "com.example.typeforme.keyboard", category: "rime")

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
    let candidateOffset: Int
    let hasPreviousPage: Bool
    let hasNextPage: Bool
    let commitText: String
    let errorMessage: String?
}

enum RimeCharacterProcessResult {
    case processed(RimeKeyboardState)
    case notReady(RimeKeyboardState)
}

struct RimeKeyCodeProcessResult {
    let wasComposing: Bool
    let state: RimeKeyboardState
}

/// Result of probing a candidate next letter against the live composition.
enum RimeProbeValidity {
    /// The letter cleanly extended the current segment (e.g. typing "i" after
    /// "zh" to form "zhi"). Strong evidence the user intended this letter.
    case extend
    /// The letter forced a segment break (e.g. typing "b" after "zh" yielding
    /// "zh|b" or "zh'b"). Strong evidence the user did not intend this letter.
    case split
    /// Probe could not produce a useful signal (rime not ready, input empty,
    /// commit happened, schema mismatch). Caller should fall back to geometry.
    case unknown
}

enum RimeKeyboardDictionaryTier: String {
    case standard
    case extended
    case large
}

struct RimeKeyboardProfile: Equatable {
    var dictionaryTier: RimeKeyboardDictionaryTier = .standard

    var schemaID: String {
        switch dictionaryTier {
        case .standard:
            return "typeforme_pinyin"
        case .extended:
            return "typeforme_pinyin_ext"
        case .large:
            return "typeforme_pinyin_large"
        }
    }
}

final class RimeInputController {
    private enum StartupState {
        case idle
        case starting
        case ready
        case failed
    }

    private static let appName = "rime.typeforme"
    private static let distributionName = "Typeforme"
    private static let distributionCodeName = "typeforme"
    private static let dataVersion = "typeforme-pinyin-v2"
    private static let customPhraseFileName = "typeforme_custom_phrase.txt"
    // 60 candidates × 5-column grid = up to 12 rows of 42pt = 504pt of
    // content versus ~226pt of grid scroll-view height. That's ~280pt of
    // meaningful vertical scroll when the user taps the expand chevron.
    // The same pool feeds the horizontal candidate bar, which is fine — the
    // bar already scrolls horizontally and shows as many as the user pans
    // through.
    private static let candidateLimit: Int32 = 60
    private static let startupRetryInterval: TimeInterval = 2.0
    private static var didSetup = false
    private static var didInitialize = false

    private let api = IRimeAPI()
    private let rimeQueue = DispatchQueue(label: "com.example.typeforme.keyboard.rime", qos: .userInitiated)
    private let stateLock = NSLock()
    private var startupState: StartupState = .idle
    private var selectedSchemaID: String?
    private var session: RimeSessionId = 0
    private var probeSession: RimeSessionId = 0
    private var lastErrorMessage: String?
    private var lastStartupAttemptAt: TimeInterval = 0
    private var desiredProfile = RimeKeyboardProfile()
    private var desiredAsciiMode = false
    private var desiredAsciiPunctuation = false
    private var desiredUserPhraseContent = RimeInputController.customPhraseFileContent(from: [])
    private var desiredUserPhraseSignature = RimeInputController.customPhraseSignature(RimeInputController.customPhraseFileContent(from: []))
    private var appliedUserPhraseSignature: String?

    var onStateChange: ((RimeKeyboardState) -> Void)?

    var isReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return startupState == .ready
            && session != 0
            && selectedSchemaID == desiredProfile.schemaID
            && lastErrorMessage == nil
    }

    @discardableResult
    func startIfNeeded(bundle: Bundle = .main) -> Bool {
        if isReady { return true }
        let now = Date().timeIntervalSince1970
        stateLock.lock()
        if startupState == .starting {
            stateLock.unlock()
            return false
        }
        if startupState == .failed {
            guard now - lastStartupAttemptAt >= Self.startupRetryInterval else {
                stateLock.unlock()
                return false
            }
            lastErrorMessage = nil
        }
        startupState = .starting
        lastStartupAttemptAt = now
        stateLock.unlock()

        let startedAt = Date()
        rimeQueue.async { [weak self] in
            guard let self else { return }
            let didStart = self.startOnQueue(bundle: bundle)
            let elapsedMS = Date().timeIntervalSince(startedAt) * 1000
            if didStart {
                rimeLog.notice("Rime startup ready in \(elapsedMS, privacy: .public) ms")
            } else {
                rimeLog.error("Rime startup failed in \(elapsedMS, privacy: .public) ms")
            }
            let nextState = self.stateOnQueue()
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(nextState)
            }
        }
        return false
    }

    private func startOnQueue(bundle: Bundle = .main) -> Bool {
        if isReadyOnQueue && appliedUserPhraseSignature == desiredUserPhraseSignatureOnQueue {
            return true
        }
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
            let (customPhraseContent, customPhraseSignature) = desiredUserPhraseSnapshotOnQueue
            if session != 0, appliedUserPhraseSignature != customPhraseSignature {
                api.cleanAllSession()
                session = 0
                probeSession = 0
                selectedSchemaID = nil
            }
            try applyCustomPhrasesOnQueue(
                content: customPhraseContent,
                signature: customPhraseSignature,
                userDataURL: userDataURL
            )
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
            let schemaID = desiredProfileOnQueue.schemaID
            if selectedSchemaID != schemaID {
                let didSelectSchema = api.selectSchema(session, andSchameId: schemaID)
                if !didSelectSchema {
                    finishStartupOnQueue(.failed, errorMessage: "中文数据不可用")
                    return false
                }
                selectedSchemaID = schemaID
            }

            applyDesiredOptionsOnQueue()
            ensureProbeSessionOnQueue()
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

    func applyOptions(asciiPunctuation: Bool, asciiMode: Bool) -> RimeKeyboardState {
        setDesiredOptions(asciiPunctuation: asciiPunctuation, asciiMode: asciiMode)
        guard startIfNeeded() else { return notReadyState() }
        return rimeQueue.sync {
            applyOptionsOnQueue(asciiMode: asciiMode, asciiPunctuation: asciiPunctuation)
            return stateOnQueue()
        }
    }

    func setProfile(_ profile: RimeKeyboardProfile) -> RimeKeyboardState {
        stateLock.lock()
        desiredProfile = profile
        stateLock.unlock()
        guard startIfNeeded() else { return notReadyState() }
        return rimeQueue.sync {
            if selectedSchemaID != profile.schemaID {
                api.cleanComposition(session)
                let didSelectSchema = api.selectSchema(session, andSchameId: profile.schemaID)
                guard didSelectSchema else {
                    finishStartupOnQueue(.failed, errorMessage: "中文数据不可用")
                    return notReadyState()
                }
                selectedSchemaID = profile.schemaID
                if probeSession != 0 {
                    api.cleanComposition(probeSession)
                    if !api.selectSchema(probeSession, andSchameId: profile.schemaID) {
                        probeSession = 0
                    }
                }
                if probeSession == 0 {
                    ensureProbeSessionOnQueue()
                }
                applyDesiredOptionsOnQueue()
            }
            return stateOnQueue()
        }
    }

    func setUserPhrases(
        _ phrases: [String],
        revision: String?,
        reloadIfNeeded: Bool = true
    ) -> RimeKeyboardState {
        let content = Self.customPhraseFileContent(from: phrases)
        let signature = Self.customPhraseSignature(content, revision: revision)
        stateLock.lock()
        let changed = desiredUserPhraseSignature != signature
        desiredUserPhraseContent = content
        desiredUserPhraseSignature = signature
        stateLock.unlock()

        guard reloadIfNeeded else {
            return notReadyState()
        }
        guard changed else {
            return state()
        }

        let resetState = rimeQueue.sync {
            if session != 0 {
                api.cleanAllSession()
                session = 0
                probeSession = 0
            }
            selectedSchemaID = nil
            stateLock.lock()
            startupState = .idle
            lastErrorMessage = nil
            stateLock.unlock()
            return notReadyState()
        }
        _ = startIfNeeded()
        return resetState
    }

    func resetUserData() -> RimeKeyboardState {
        let resetState = rimeQueue.sync {
            if session != 0 {
                api.cleanAllSession()
                session = 0
                probeSession = 0
            }
            selectedSchemaID = nil
            stateLock.lock()
            startupState = .idle
            lastErrorMessage = nil
            stateLock.unlock()
            do {
                let userDataURL = try ensureUserDataDirectory()
                appliedUserPhraseSignature = nil
                let contents = try FileManager.default.contentsOfDirectory(
                    at: userDataURL,
                    includingPropertiesForKeys: nil
                )
                for url in contents {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.createDirectory(at: userDataURL, withIntermediateDirectories: true)
            } catch {
                finishStartupOnQueue(.failed, errorMessage: "中文学习数据无法重置")
                rimeLog.error("Failed to reset Rime user data: \(error.localizedDescription, privacy: .public)")
            }
            return notReadyState()
        }
        _ = startIfNeeded()
        return resetState
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

    func processCharacter(
        _ character: String,
        asciiPunctuation: Bool,
        asciiMode: Bool
    ) -> RimeKeyboardState {
        setDesiredOptions(asciiPunctuation: asciiPunctuation, asciiMode: asciiMode)
        guard startIfNeeded(),
              let scalar = character.unicodeScalars.first
        else { return notReadyState() }
        return rimeQueue.sync {
            applyOptionsOnQueue(asciiMode: asciiMode, asciiPunctuation: asciiPunctuation)
            _ = api.processKeyCode(Int32(scalar.value), modifier: 0, andSession: session)
            return stateOnQueue(commitText: drainCommit())
        }
    }

    func processCharacterIfReady(
        _ character: String,
        asciiPunctuation: Bool,
        asciiMode: Bool
    ) -> RimeCharacterProcessResult {
        setDesiredOptions(asciiPunctuation: asciiPunctuation, asciiMode: asciiMode)
        guard startIfNeeded(),
              let scalar = character.unicodeScalars.first
        else { return .notReady(notReadyState()) }
        return rimeQueue.sync {
            guard isReadyOnQueue else { return .notReady(notReadyState()) }
            applyOptionsOnQueue(asciiMode: asciiMode, asciiPunctuation: asciiPunctuation)
            _ = api.processKeyCode(Int32(scalar.value), modifier: 0, andSession: session)
            return .processed(stateOnQueue(commitText: drainCommit()))
        }
    }

    func processKeyCode(_ code: Int32) -> RimeKeyboardState {
        guard startIfNeeded() else { return notReadyState() }
        return rimeQueue.sync {
            _ = api.processKeyCode(code, modifier: 0, andSession: session)
            return stateOnQueue(commitText: drainCommit())
        }
    }

    func processKeyCode(
        _ code: Int32,
        asciiPunctuation: Bool,
        asciiMode: Bool
    ) -> RimeKeyCodeProcessResult {
        setDesiredOptions(asciiPunctuation: asciiPunctuation, asciiMode: asciiMode)
        guard startIfNeeded() else {
            return RimeKeyCodeProcessResult(wasComposing: false, state: notReadyState())
        }
        return rimeQueue.sync {
            guard isReadyOnQueue else {
                return RimeKeyCodeProcessResult(wasComposing: false, state: notReadyState())
            }
            applyOptionsOnQueue(asciiMode: asciiMode, asciiPunctuation: asciiPunctuation)
            let wasComposing = isComposingOnQueue()
            _ = api.processKeyCode(code, modifier: 0, andSession: session)
            return RimeKeyCodeProcessResult(
                wasComposing: wasComposing,
                state: stateOnQueue(commitText: drainCommit())
            )
        }
    }

    func selectCandidate(at index: Int) -> RimeKeyboardState {
        guard startIfNeeded() else { return notReadyState() }
        return rimeQueue.sync {
            _ = api.selectCandidate(session, andIndex: Int32(index))
            return stateOnQueue(commitText: drainCommit())
        }
    }

    func commitComposition() -> RimeKeyboardState {
        guard startIfNeeded() else { return notReadyState() }
        return rimeQueue.sync {
            _ = api.commitComposition(session)
            return stateOnQueue(commitText: drainCommit())
        }
    }

    func commitRawInput() -> RimeKeyboardState {
        guard startIfNeeded() else { return notReadyState() }
        return rimeQueue.sync {
            let rawInput = api.getInput(session) ?? ""
            api.cleanComposition(session)
            return stateOnQueue(commitText: rawInput)
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
        session != 0 && selectedSchemaID == desiredProfileOnQueue.schemaID && lastErrorMessage == nil
    }

    private var desiredProfileOnQueue: RimeKeyboardProfile {
        stateLock.lock()
        defer { stateLock.unlock() }
        return desiredProfile
    }

    private var desiredUserPhraseSignatureOnQueue: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return desiredUserPhraseSignature
    }

    private var desiredUserPhraseSnapshotOnQueue: (content: String, signature: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (desiredUserPhraseContent, desiredUserPhraseSignature)
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
        let pageSize = max(Int(context.menu?.pageSize ?? 0), 1)
        let pageNo = max(Int(context.menu?.pageNo ?? 0), 0)
        let candidateOffset = pageSize * pageNo
        let fetchedCandidates = api.getCandidateWith(
            Int32(candidateOffset),
            andCount: Self.candidateLimit,
            andSession: session
        )
        let menuCandidates = context.menu?.candidates ?? []
        let rawCandidates: [IRimeCandidate]
        let effectiveCandidateOffset: Int
        if let fetchedCandidates, !fetchedCandidates.isEmpty {
            rawCandidates = fetchedCandidates
            effectiveCandidateOffset = candidateOffset
        } else {
            rawCandidates = candidateOffset == 0 ? menuCandidates : []
            effectiveCandidateOffset = 0
        }
        let candidates = rawCandidates.prefix(Int(Self.candidateLimit))
            .compactMap { candidate -> RimeKeyboardCandidate? in
                guard let text = candidate.text, !text.isEmpty else { return nil }
                return RimeKeyboardCandidate(text: text, comment: candidate.comment ?? "")
            }
        var displayCandidates = candidates
        if displayCandidates.isEmpty,
           let preview = context.commitTextPreview,
           !preview.isEmpty,
           preview != input {
            displayCandidates = [RimeKeyboardCandidate(text: preview, comment: "")]
        }

        return RimeKeyboardState(
            isReady: true,
            isComposing: status.isComposing || !input.isEmpty,
            input: input,
            preedit: preedit,
            candidates: displayCandidates,
            candidateOffset: effectiveCandidateOffset,
            hasPreviousPage: pageNo > 0,
            hasNextPage: !(context.menu?.isLastPage ?? true),
            commitText: commitText,
            errorMessage: nil
        )
    }

    private func isComposingOnQueue() -> Bool {
        guard isReadyOnQueue,
              let status = api.getStatus(session)
        else { return false }
        let input = api.getInput(session) ?? ""
        return status.isComposing || !input.isEmpty
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
            candidateOffset: 0,
            hasPreviousPage: false,
            hasNextPage: false,
            commitText: commitText,
            errorMessage: errorMessage
        )
    }

    private func finishStartupOnQueue(_ nextState: StartupState, errorMessage: String?) {
        if nextState == .failed {
            if session != 0 {
                api.cleanAllSession()
                session = 0
                probeSession = 0
            }
            selectedSchemaID = nil
        }
        stateLock.lock()
        startupState = nextState
        lastErrorMessage = errorMessage
        stateLock.unlock()
    }

    private func ensureProbeSessionOnQueue() {
        guard probeSession == 0 else { return }
        let created = api.createSession()
        guard created != 0 else {
            rimeLog.error("Rime probe session creation failed")
            return
        }
        let schemaID = desiredProfileOnQueue.schemaID
        guard api.selectSchema(created, andSchameId: schemaID) else {
            rimeLog.error("Rime probe schema select failed")
            return
        }
        _ = api.setOption(created, andOption: "ascii_mode", andValue: false)
        _ = api.setOption(created, andOption: "ascii_punct", andValue: false)
        probeSession = created
    }

    /// Ask librime whether `left` and `right` candidate letters cleanly extend
    /// the current main-session composition or force a segment split. Used by
    /// the keyboard's hit-test to resolve gutter taps in favour of the
    /// linguistically valid pinyin continuation.
    ///
    /// Runs synchronously on the rime serial queue. Total cost is roughly
    /// `(len(input) + 2) * 2` processKey calls — typically under 2 ms.
    /// Returns `(.unknown, .unknown)` whenever the probe cannot give a useful
    /// signal so the caller can fall back to geometric midpoint resolution.
    func probeGutterValidity(left: Character, right: Character) -> (left: RimeProbeValidity, right: RimeProbeValidity) {
        guard isReady, probeSession != 0 else {
            return (.unknown, .unknown)
        }
        return rimeQueue.sync {
            guard isReadyOnQueue, probeSession != 0 else {
                return (.unknown, .unknown)
            }
            let input = api.getInput(session) ?? ""
            guard !input.isEmpty else {
                return (.unknown, .unknown)
            }
            api.cleanComposition(probeSession)
            for scalar in input.unicodeScalars {
                _ = api.processKeyCode(Int32(scalar.value), modifier: 0, andSession: probeSession)
            }
            let baselinePreedit = api.getContext(probeSession)?.composition?.preedit ?? input
            let baselineInput = api.getInput(probeSession) ?? input
            let leftValidity = probeCandidateOnQueue(
                letter: left,
                baselineInput: baselineInput,
                baselinePreedit: baselinePreedit
            )
            let rightValidity = probeCandidateOnQueue(
                letter: right,
                baselineInput: baselineInput,
                baselinePreedit: baselinePreedit
            )
            return (leftValidity, rightValidity)
        }
    }

    private func probeCandidateOnQueue(
        letter: Character,
        baselineInput: String,
        baselinePreedit: String
    ) -> RimeProbeValidity {
        guard let scalar = letter.unicodeScalars.first else { return .unknown }
        _ = api.processKeyCode(Int32(scalar.value), modifier: 0, andSession: probeSession)
        let inputAfter = api.getInput(probeSession) ?? ""
        let preeditAfter = api.getContext(probeSession)?.composition?.preedit ?? ""
        // Restore probe to the baseline before returning so the next candidate
        // sees the same starting state.
        api.cleanComposition(probeSession)
        for scalar in baselineInput.unicodeScalars {
            _ = api.processKeyCode(Int32(scalar.value), modifier: 0, andSession: probeSession)
        }
        // The character must have appended cleanly to the input buffer. Any
        // other transition (commit, schema-driven rewrite) is treated as
        // unknown so we do not overweight strange Rime states.
        guard inputAfter.count == baselineInput.count + 1 else {
            return .unknown
        }
        // Rime emits a segment delimiter — usually `'` or space — into the
        // preedit when an incoming letter cannot continue the current
        // syllable. Defensively detect any of the common delimiter glyphs.
        let delimiters: Set<Character> = ["'", "\\", " ", "|", "`"]
        let baselineDelimiters = baselinePreedit.filter { delimiters.contains($0) }.count
        let afterDelimiters = preeditAfter.filter { delimiters.contains($0) }.count
        if afterDelimiters > baselineDelimiters {
            return .split
        }
        return .extend
    }

    private func applyDesiredOptionsOnQueue() {
        stateLock.lock()
        let asciiMode = desiredAsciiMode
        let asciiPunctuation = desiredAsciiPunctuation
        stateLock.unlock()
        applyOptionsOnQueue(asciiMode: asciiMode, asciiPunctuation: asciiPunctuation)
    }

    private func setDesiredOptions(asciiPunctuation: Bool, asciiMode: Bool) {
        stateLock.lock()
        desiredAsciiMode = asciiMode
        desiredAsciiPunctuation = asciiPunctuation
        stateLock.unlock()
    }

    private func applyOptionsOnQueue(asciiMode: Bool, asciiPunctuation: Bool) {
        _ = api.setOption(session, andOption: "ascii_mode", andValue: asciiMode)
        _ = api.setOption(session, andOption: "ascii_punct", andValue: asciiPunctuation)
    }

    private func applyCustomPhrasesOnQueue(
        content: String,
        signature: String,
        userDataURL: URL
    ) throws {
        guard appliedUserPhraseSignature != signature else { return }
        let url = userDataURL.appendingPathComponent(Self.customPhraseFileName)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        if existing != content {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        appliedUserPhraseSignature = signature
    }

    private func drainCommit() -> String {
        api.getCommit(session) ?? ""
    }

    private func ensureUserDataDirectory() throws -> URL {
        // Keep Rime's own mutable files in the extension sandbox. Host-owned
        // settings and vocabulary arrive through App Group defaults, then the
        // keyboard materializes them into this Rime user data directory.
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let userDataURL = baseURL
            .appendingPathComponent("Rime", isDirectory: true)
            .appendingPathComponent(Self.dataVersion, isDirectory: true)
        try FileManager.default.createDirectory(at: userDataURL, withIntermediateDirectories: true)
        return userDataURL
    }

    private static func customPhraseFileContent(from phrases: [String]) -> String {
        var rows: [String] = []
        var seenRows = Set<String>()
        for phrase in normalizedUserPhrases(phrases) {
            let codes = customPhraseCodes(for: phrase)
            for (index, code) in codes.enumerated() {
                let rowKey = "\(code)\t\(phrase)"
                guard seenRows.insert(rowKey).inserted else { continue }
                let weight = index == 0 ? 100_000 : 90_000
                rows.append("\(phrase)\t\(code)\t\(weight)")
            }
        }

        var content = "# Rime table\n# encoding: utf-8\n\n"
        if !rows.isEmpty {
            content += rows.joined(separator: "\n")
            content += "\n"
        }
        return content
    }

    private static func customPhraseSignature(_ content: String, revision: String? = nil) -> String {
        let trimmedRevision = revision?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedRevision.isEmpty else { return trimmedRevision }
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedUserPhrases(_ phrases: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for phrase in phrases {
            let cleaned = phrase
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let key = cleaned.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            guard seen.insert(key).inserted else { continue }
            output.append(cleaned)
        }
        return output
    }

    private static func customPhraseCodes(for phrase: String) -> [String] {
        let tokens = pinyinTokens(for: phrase)
        guard !tokens.isEmpty else { return [] }
        var codes: [String] = []
        let fullCode = tokens.joined()
        if fullCode.count >= 2 {
            codes.append(fullCode)
        }
        if tokens.count >= 2 {
            let initials = tokens.compactMap(\.first).map(String.init).joined()
            if initials.count >= 2, initials != fullCode {
                codes.append(initials)
            }
        }
        return codes
    }

    private static func pinyinTokens(for text: String) -> [String] {
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        var transformed = mutable as String
        for value in ["ü", "ǖ", "ǘ", "ǚ", "ǜ", "Ü", "Ǖ", "Ǘ", "Ǚ", "Ǜ"] {
            transformed = transformed.replacingOccurrences(of: value, with: "v")
        }
        let normalized = transformed
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()

        var tokens: [String] = []
        var current = ""
        for scalar in normalized.unicodeScalars {
            let value = scalar.value
            if (97...122).contains(value) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
