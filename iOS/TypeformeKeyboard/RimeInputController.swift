import CryptoKit
import Foundation
#if !targetEnvironment(simulator)
import LibrimeKit
#endif
import OSLog

private let rimeLog = Logger(subsystem: TypeformeBundleConfiguration.keyboardBundleIdentifier, category: "rime")
private let rimePerformanceLog = OSLog(
    subsystem: TypeformeBundleConfiguration.keyboardBundleIdentifier,
    category: "rime-performance"
)

struct RimeKeyboardCandidate {
    let text: String
    let selectionIndex: Int

    init(text: String, selectionIndex: Int) {
        self.text = text
        self.selectionIndex = selectionIndex
    }
}

struct RimeCompositionSnapshot {
    struct Identity: Equatable {
        let isComposing: Bool
        let input: String
        let preedit: String
        let preeditSelectionStart: Int
        let preeditSelectionEnd: Int

        static let unavailable = Identity(
            isComposing: false,
            input: "",
            preedit: "",
            preeditSelectionStart: 0,
            preeditSelectionEnd: 0
        )
    }

    let revision: UInt64
    let isReady: Bool
    let isComposing: Bool
    let input: String
    let preedit: String
    let preeditSelectionStart: Int
    let preeditSelectionEnd: Int
    /// Persistent engine availability error for this projection. Keeping it
    /// with the composition avoids a second UI-side cache when candidates are
    /// replaced independently by scrolling.
    let errorMessage: String?

    static let unavailable = RimeCompositionSnapshot(
        revision: 0,
        isReady: false,
        isComposing: false,
        input: "",
        preedit: "",
        preeditSelectionStart: 0,
        preeditSelectionEnd: 0,
        errorMessage: nil
    )

    var identity: Identity {
        Identity(
            isComposing: isComposing,
            input: input,
            preedit: preedit,
            preeditSelectionStart: preeditSelectionStart,
            preeditSelectionEnd: preeditSelectionEnd
        )
    }

    func visibleCompositionText(preferRawInput: Bool = false) -> String {
        guard isComposing else { return "" }
        if preferRawInput {
            return input
        }
        return preedit.isEmpty ? input : preedit
    }

    /// Text to commit when a UI boundary ends the marked-text session. Rime's
    /// preedit is presentation (syllable spacing and u/v -> ü included), so
    /// the shared policy takes only a confirmed prefix from it and preserves
    /// the active suffix as raw input.
    func committableCompositionText(preferRawInput: Bool = false) -> String {
        guard isComposing else { return "" }
        return KeyboardRimeCompositionPolicy.committableText(
            rawInput: input,
            preedit: preedit,
            preeditSelectionStart: preeditSelectionStart,
            preeditSelectionEnd: preeditSelectionEnd,
            preferRawInput: preferRawInput
        )
    }

}

struct RimeCandidateWindow {
    let revision: UInt64
    /// Identity of the composition that produced this candidate projection.
    /// Candidate-only expansion must match it before appending a suffix.
    let compositionIdentity: RimeCompositionSnapshot.Identity
    let candidates: [RimeKeyboardCandidate]
    /// Candidate prefix before display filtering, retained so scrolling can
    /// append only the missing Rime suffix instead of rebuilding from zero.
    let retainedCandidates: [RimeKeyboardCandidate]
    let offset: Int
    let pageSize: Int
    /// Absolute Rime candidate index immediately after this window. Display
    /// filtering never changes this cursor or any candidate selection index.
    let endIndex: Int
    /// Rime generates candidates lazily and exposes no authoritative total.
    /// `true` means another bounded prefix request may produce more candidates.
    let mayHaveMore: Bool
    let hasPreviousPage: Bool
    let hasNextPage: Bool

    var loadedCandidateCount: Int {
        max(0, endIndex - offset)
    }

    static let unavailable = RimeCandidateWindow.empty(revision: 0)

    static func empty(
        revision: UInt64,
        compositionIdentity: RimeCompositionSnapshot.Identity = .unavailable
    ) -> RimeCandidateWindow {
        RimeCandidateWindow(
            revision: revision,
            compositionIdentity: compositionIdentity,
            candidates: [],
            retainedCandidates: [],
            offset: 0,
            pageSize: 1,
            endIndex: 0,
            mayHaveMore: false,
            hasPreviousPage: false,
            hasNextPage: false
        )
    }
}

/// One mutation result. Composition and candidates are projections of the same
/// engine capture; commits are ordered events drained after each processed key.
/// Keep the events separate for learning, but replace the document's marked
/// range with their concatenation plus any UI-owned suffix in one mutation.
/// UI text is deliberately not an engine commit or a learning event.
struct RimeKeyboardUpdate {
    let composition: RimeCompositionSnapshot
    let candidateWindow: RimeCandidateWindow
    let committedTexts: [String]
    let documentCommitText: String
    var errorMessage: String? { composition.errorMessage }

    init(
        composition: RimeCompositionSnapshot,
        candidateWindow: RimeCandidateWindow,
        committedTexts: [String],
        documentCommitText: String? = nil
    ) {
        precondition(
            composition.revision == candidateWindow.revision,
            "Rime composition and candidate projections must share a revision"
        )
        self.composition = composition
        self.candidateWindow = candidateWindow
        self.committedTexts = committedTexts
        self.documentCommitText = documentCommitText ?? committedTexts.joined()
    }

    func appendingDocumentText(_ text: String) -> RimeKeyboardUpdate {
        guard !text.isEmpty else { return self }
        return RimeKeyboardUpdate(
            composition: composition,
            candidateWindow: candidateWindow,
            committedTexts: committedTexts,
            documentCommitText: documentCommitText + text
        )
    }
}

enum RimeInputProcessResult {
    case processed(RimeKeyboardUpdate)
    case notReady(RimeKeyboardUpdate)
}

struct RimeKeyCodeProcessResult {
    let wasComposing: Bool
    let update: RimeKeyboardUpdate
}

struct RimeKeyboardProfile: Equatable, Sendable {
    var dictionaryTier: KeyboardRimeDictionaryTier = .standard
    var learningEnabled: Bool = true
    var correctionEnabled: Bool = false

    var schemaID: String {
        let base: String
        switch dictionaryTier {
        case .standard:
            base = "typeforme_pinyin"
        case .extended:
            base = "typeforme_pinyin_ext"
        case .large:
            base = "typeforme_pinyin_large"
        }
        switch (correctionEnabled, learningEnabled) {
        case (true, true):
            return base
        case (false, true):
            return "\(base)_no_correction"
        case (true, false):
            return "\(base)_no_learning"
        case (false, false):
            return "\(base)_no_correction_no_learning"
        }
    }
}

#if targetEnvironment(simulator)
/// The checked-in librime XCFramework has a device arm64 slice and a simulator
/// x86_64 slice, but no simulator arm64 slice. Modern Apple-silicon simulator
/// devices reject the translated x86_64 extension entirely. Keep visual and
/// UIKit lifecycle checks available with an inert projection; physical builds
/// always compile the real engine below.
final class RimeInputController: @unchecked Sendable {
    var onActivation: ((RimeKeyboardUpdate) -> Void)?
    var onResetUserDataApplied: ((Int) -> Void)?

    init(acknowledgedResetUserDataGeneration: Int = 0) {}

    var isReady: Bool { true }

    @discardableResult
    func startIfNeeded(bundle: Bundle = .main) -> Bool { true }

    func prepareForSuspension() {}

    @discardableResult
    func resumeAfterSuspension(bundle: Bundle = .main) -> Bool { true }

    func applyInputOptions(asciiPunctuation: Bool, asciiMode: Bool) {}

    func activateDesiredConfigurationAfterTextBoundary() {
        publishCurrentActivationIfAvailable()
    }

    func setDesiredConfiguration(
        profile: RimeKeyboardProfile,
        asciiPunctuation: Bool,
        asciiMode: Bool,
        userPhrases: [String],
        userPhrasesRevision: String?,
        resetUserDataGeneration: Int
    ) {
        onResetUserDataApplied?(max(0, resetUserDataGeneration))
    }

    func publishCurrentActivationIfAvailable() {
        onActivation?(emptyUpdate())
    }

    func processInputIfReady(
        _ input: KeyboardPendingRimeInput,
        asciiPunctuation: Bool,
        asciiMode: Bool
    ) -> RimeInputProcessResult {
        .processed(emptyUpdate())
    }

    func processKeyCode(_ code: Int32) -> RimeKeyboardUpdate {
        emptyUpdate()
    }

    func replaceCompositionInput(
        _ input: String,
        asciiPunctuation: Bool,
        asciiMode: Bool
    ) -> RimeKeyboardUpdate {
        emptyUpdate()
    }

    func processKeyCode(
        _ code: Int32,
        asciiPunctuation: Bool,
        asciiMode: Bool
    ) -> RimeKeyCodeProcessResult {
        RimeKeyCodeProcessResult(wasComposing: false, update: emptyUpdate())
    }

    func selectCandidate(at index: Int) -> RimeKeyboardUpdate {
        emptyUpdate()
    }

    func commitVisibleComposition(_ text: String) -> RimeKeyboardUpdate {
        emptyUpdate(documentCommitText: text)
    }

    func clearComposition() -> RimeKeyboardUpdate {
        emptyUpdate()
    }

    func expandedCandidateWindow(
        upTo candidateCount: Int,
        matching expectedWindow: RimeCandidateWindow
    ) -> RimeCandidateWindow? {
        expectedWindow
    }

    private func emptyUpdate(documentCommitText: String = "") -> RimeKeyboardUpdate {
        let composition = RimeCompositionSnapshot(
            revision: 1,
            isReady: true,
            isComposing: false,
            input: "",
            preedit: "",
            preeditSelectionStart: 0,
            preeditSelectionEnd: 0,
            errorMessage: nil
        )
        return RimeKeyboardUpdate(
            composition: composition,
            candidateWindow: .empty(revision: composition.revision),
            committedTexts: [],
            documentCommitText: documentCommitText
        )
    }
}
#else
final class RimeInputController: @unchecked Sendable {
    private final class GlobalLifecycle: @unchecked Sendable {
        private let lock = NSLock()
        private var didSetup = false
        private var didInitialize = false
        private var activeOwners: Set<UUID> = []

        func prepareIfNeeded(api: IRimeAPI, traits: IRimeTraits, ownerID: UUID) {
            lock.lock()
            defer { lock.unlock() }

            if !didSetup {
                api.setup(traits)
                didSetup = true
            }
            if !didInitialize {
                api.initialize(traits)
                didInitialize = true
            }
            activeOwners.insert(ownerID)
        }

        /// RimeCleanupAllSessions releases the visible sessions, but global
        /// registry components can retain a LevelDB handle. Finalization is the
        /// process-wide boundary that releases those file locks before UIKit
        /// suspends the keyboard extension.
        func releaseIfNeeded(api: IRimeAPI, ownerID: UUID) {
            lock.lock()
            defer { lock.unlock() }

            activeOwners.remove(ownerID)
            guard activeOwners.isEmpty, didInitialize else { return }
            api.finalize()
            didInitialize = false
        }
    }

    /// Values that require a schema/session activation. Live input options are
    /// intentionally excluded: toggling ASCII mode or punctuation on an
    /// existing session must not invalidate composition ownership.
    private struct DesiredRimeActivationConfiguration: Equatable, Sendable {
        let profile: RimeKeyboardProfile
        let userPhraseContent: String
        let userPhraseSignature: String
        let resetUserDataGeneration: Int
    }

    /// Queue-owned identity of the live main session. The effective profile is
    /// resolved only at an actual session/schema boundary and remains pinned
    /// for that session even if a persisted fallback later expires.
    private struct ActiveSessionConfiguration {
        let requestedProfile: RimeKeyboardProfile
        let effectiveProfile: RimeKeyboardProfile
    }

    private struct ActivationAttemptResult {
        let succeeded: Bool
        let errorMessage: String?
    }

    private static let distributionName = "Typeforme"
    private static let distributionCodeName = "typeforme"
    private static let dataVersion = "typeforme-pinyin-v2"
    private static let customPhraseFileName = "typeforme_custom_phrase.txt"
    private static let startupRetryInterval: TimeInterval = 2.0
    private static let startupAttemptDefaultsKey = "rime.startupAttempt.v1"
    private static let startupFallbackDefaultsKey = "rime.startupFallback.v1"
    private static let startupAttemptMaxAge: TimeInterval = 24 * 60 * 60
    private static let startupFallbackFailureWindow: TimeInterval = 30 * 60
    private static let startupFallbackDurations: [TimeInterval] = [
        2 * 60,
        10 * 60,
        30 * 60,
        2 * 60 * 60,
    ]
    private static let globalLifecycle = GlobalLifecycle()

    private struct StartupAttemptMarker: Codable {
        let schemaID: String
        let dictionaryTier: KeyboardRimeDictionaryTier
        let startedAt: TimeInterval
    }

    private struct StartupFallbackMarker: Codable {
        let dictionaryTier: KeyboardRimeDictionaryTier
        let failureCount: Int
        let firstFailedAt: TimeInterval
        let lastFailedAt: TimeInterval
        let expiresAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case dictionaryTier
            case failureCount
            case firstFailedAt
            case lastFailedAt
            case expiresAt
        }

        init(
            dictionaryTier: KeyboardRimeDictionaryTier,
            failureCount: Int,
            firstFailedAt: TimeInterval,
            lastFailedAt: TimeInterval,
            expiresAt: TimeInterval
        ) {
            self.dictionaryTier = dictionaryTier
            self.failureCount = failureCount
            self.firstFailedAt = firstFailedAt
            self.lastFailedAt = lastFailedAt
            self.expiresAt = expiresAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            dictionaryTier = try container.decode(KeyboardRimeDictionaryTier.self, forKey: .dictionaryTier)
            expiresAt = try container.decode(TimeInterval.self, forKey: .expiresAt)
            failureCount = try container.decodeIfPresent(Int.self, forKey: .failureCount) ?? 1
            lastFailedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .lastFailedAt) ?? expiresAt
            firstFailedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .firstFailedAt) ?? lastFailedAt
        }
    }

    /// librime's service and registry are process-global. UIKit may overlap
    /// keyboard-controller lifetimes during a handoff, so every controller
    /// must serialize C API access through this one process-wide queue.
    private static let sharedRimeQueue = DispatchQueue(
        label: "\(TypeformeBundleConfiguration.keyboardBundleIdentifier).rime",
        qos: .userInitiated
    )
    private let api = IRimeAPI()
    private let ownerID = UUID()
    private var rimeQueue: DispatchQueue { Self.sharedRimeQueue }
    private let stateLock = NSLock()
    private var activationPolicy: KeyboardRimeActivationPolicy<DesiredRimeActivationConfiguration>
    /// Protected by stateLock. These options are applied as serialized live
    /// session mutations; they never advance the activation generation.
    private var desiredInputOptions = KeyboardRimeInputOptions(
        asciiMode: false,
        asciiPunctuation: false
    )
    /// Protected by stateLock. A controller starts suspended because UIKit can
    /// construct a keyboard surface without completing its presentation. Rime
    /// may acquire its user database only after `viewDidAppear`, and must stay
    /// blocked again from `viewWillDisappear` until the next visible surface.
    private var isSuspended = true
    private var lastErrorMessage: String?
    /// Accessed only on rimeQueue.
    private var selectedSchemaID: String?
    private var session: RimeSessionId = 0
    /// Queue-owned last-issued value for the two live session switches.
    /// Desired options may be observed on every key, but librime is mutated
    /// only when their complete value actually changes.
    private var appliedInputOptions: KeyboardRimeInputOptions?
    private var activeSessionConfiguration: ActiveSessionConfiguration?
    private var appliedUserPhraseSignature: String?
    private var appliedResetUserDataGeneration: Int
    /// Accessed only on rimeQueue. Every engine mutation finishes by replacing
    /// this projection, so pre-mutation behavior need not query Rime twice.
    private var latestCompositionOnQueue = RimeCompositionSnapshot.unavailable
    /// Protected by stateLock. Revision zero is reserved for static unavailable
    /// projections; every controller-issued projection advances this value.
    private var lastIssuedRevision: UInt64 = 0
    /// Protected by stateLock. Rebinding the keyboard UI can replay this stable
    /// lifecycle projection without touching the Rime queue; revision ordering
    /// discards it if a newer key projection is already visible.
    private var latestActivationPublication: (
        target: KeyboardRimeActivationPolicy<DesiredRimeActivationConfiguration>.Snapshot,
        update: RimeKeyboardUpdate
    )?

    var onActivation: ((RimeKeyboardUpdate) -> Void)?
    /// Kept separate from UI projection delivery so a reset that finishes while
    /// the keyboard is disappearing is still durably acknowledged exactly once.
    var onResetUserDataApplied: ((Int) -> Void)?

    init(acknowledgedResetUserDataGeneration: Int = 0) {
        let initialPhraseContent = Self.customPhraseFileContent(from: [])
        let initialConfiguration = DesiredRimeActivationConfiguration(
            profile: RimeKeyboardProfile(),
            userPhraseContent: initialPhraseContent,
            userPhraseSignature: Self.customPhraseSignature(initialPhraseContent),
            resetUserDataGeneration: max(0, acknowledgedResetUserDataGeneration)
        )
        activationPolicy = KeyboardRimeActivationPolicy(
            initialConfiguration: initialConfiguration
        )
        appliedResetUserDataGeneration = max(0, acknowledgedResetUserDataGeneration)
    }

    var isReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !isSuspended && activationPolicy.isReady && lastErrorMessage == nil
    }

    @discardableResult
    func startIfNeeded(bundle: Bundle = .main) -> Bool {
        let now = Date().timeIntervalSince1970
        stateLock.lock()
        if isSuspended {
            stateLock.unlock()
            return false
        }
        if activationPolicy.isReady, lastErrorMessage == nil {
            stateLock.unlock()
            return true
        }
        let target = activationPolicy.requestActivation(
            now: now,
            retryInterval: Self.startupRetryInterval
        )
        if target != nil {
            lastErrorMessage = nil
        }
        stateLock.unlock()

        guard let target else { return false }
        scheduleActivationFlight(target, bundle: bundle)
        return false
    }

    /// Closes every librime session before UIKit can suspend the extension.
    /// Live sessions own LevelDB/file locks; retaining those locks across a
    /// keyboard handoff causes a RUNNINGBOARD 0xdead10cc termination.
    func prepareForSuspension() {
        stateLock.lock()
        isSuspended = true
        stateLock.unlock()

        rimeQueue.sync {
            resetAllSessionsOnQueue()
            Self.globalLifecycle.releaseIfNeeded(api: api, ownerID: ownerID)
            stateLock.lock()
            activationPolicy.invalidateAppliedConfiguration()
            latestActivationPublication = nil
            lastErrorMessage = nil
            stateLock.unlock()
        }
    }

    /// Re-enables engine activation for a newly presented keyboard surface.
    @discardableResult
    func resumeAfterSuspension(bundle: Bundle = .main) -> Bool {
        stateLock.lock()
        isSuspended = false
        stateLock.unlock()
        return startIfNeeded(bundle: bundle)
    }

    /// Applies session-local options without entering activation. The queued
    /// mutation either updates the current session or becomes a no-op while a
    /// replacement is in progress; the replacement reads the same desired
    /// option snapshot before it publishes ready.
    func applyInputOptions(
        asciiPunctuation: Bool,
        asciiMode: Bool
    ) {
        setDesiredOptions(
            asciiPunctuation: asciiPunctuation,
            asciiMode: asciiMode
        )
        applyDesiredOptionsToLiveSession()
    }

    /// The caller must end pending/live marked-text ownership before invoking
    /// this session/schema replacement entrypoint.
    func activateDesiredConfigurationAfterTextBoundary() {
        _ = startIfNeeded()
    }

    /// Stores one complete host settings snapshot without touching the live
    /// session. Cold launch calls this before the visible presentation resumes
    /// Rime; a live refresh follows it with
    /// `activateDesiredConfigurationAfterTextBoundary` after ending any
    /// destructive text ownership boundary.
    func setDesiredConfiguration(
        profile: RimeKeyboardProfile,
        asciiPunctuation: Bool,
        asciiMode: Bool,
        userPhrases: [String],
        userPhrasesRevision: String?,
        resetUserDataGeneration: Int
    ) {
        let content = Self.customPhraseFileContent(from: userPhrases)
        let configuration = DesiredRimeActivationConfiguration(
            profile: profile,
            userPhraseContent: content,
            userPhraseSignature: Self.customPhraseSignature(
                content,
                revision: userPhrasesRevision
            ),
            resetUserDataGeneration: max(0, resetUserDataGeneration)
        )
        stateLock.lock()
        if activationPolicy.replaceDesiredConfiguration(configuration) {
            lastErrorMessage = nil
        }
        desiredInputOptions = KeyboardRimeInputOptions(
            asciiMode: asciiMode,
            asciiPunctuation: asciiPunctuation
        )
        stateLock.unlock()
    }

    private func scheduleActivationFlight(
        _ initialTarget: KeyboardRimeActivationPolicy<DesiredRimeActivationConfiguration>.Snapshot,
        bundle: Bundle
    ) {
        rimeQueue.async { [weak self] in
            self?.drainActivationFlight(initialTarget: initialTarget, bundle: bundle)
        }
    }

    private func drainActivationFlight(
        initialTarget: KeyboardRimeActivationPolicy<DesiredRimeActivationConfiguration>.Snapshot,
        bundle: Bundle
    ) {
        var target = initialTarget
        while true {
            let startedAt = Date()
            let result = activateOnQueue(configuration: target.configuration, bundle: bundle)
            let elapsedMS = Date().timeIntervalSince(startedAt) * 1000
            if result.succeeded {
                rimeLog.notice(
                    "Rime activation ready generation=\(target.generation, privacy: .public) attempt=\(target.attempt, privacy: .public) in \(elapsedMS, privacy: .public) ms"
                )
            } else {
                rimeLog.error(
                    "Rime activation failed generation=\(target.generation, privacy: .public) attempt=\(target.attempt, privacy: .public) in \(elapsedMS, privacy: .public) ms"
                )
            }

            stateLock.lock()
            let completion = activationPolicy.complete(
                target,
                succeeded: result.succeeded,
                now: Date().timeIntervalSince1970
            )
            switch completion {
            case .continueWith:
                break
            case .publish:
                lastErrorMessage = result.errorMessage
            case .discard:
                break
            }
            stateLock.unlock()

            switch completion {
            case .continueWith(let latestTarget):
                target = latestTarget
                continue
            case .discard:
                return
            case .publish:
                let update = captureUpdateOnQueue()
                stateLock.lock()
                let shouldPublish = activationPolicy.shouldDeliverPublication(for: target)
                if shouldPublish {
                    latestActivationPublication = (target, update)
                }
                stateLock.unlock()
                guard shouldPublish else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.shouldDeliverActivationPublication(for: target)
                    else { return }
                    self.onActivation?(update)
                }
                return
            }
        }
    }

    private func shouldDeliverActivationPublication(
        for target: KeyboardRimeActivationPolicy<DesiredRimeActivationConfiguration>.Snapshot
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activationPolicy.shouldDeliverPublication(for: target)
    }

    /// Replays only the last stable activation result. This is used when UIKit
    /// recreates/re-presents the keyboard after the original main callback was
    /// intentionally detached in `viewWillDisappear`.
    func publishCurrentActivationIfAvailable() {
        stateLock.lock()
        let publication = latestActivationPublication.flatMap { publication in
            activationPolicy.shouldDeliverPublication(for: publication.target)
                ? publication
                : nil
        }
        stateLock.unlock()
        guard let publication else { return }
        onActivation?(publication.update)
    }

    private func activateOnQueue(
        configuration: DesiredRimeActivationConfiguration,
        bundle: Bundle
    ) -> ActivationAttemptResult {
        let mutationPlan = KeyboardRimeSessionMutationPlan.make(
            desiredPhraseSignature: configuration.userPhraseSignature,
            appliedPhraseSignature: appliedUserPhraseSignature,
            desiredResetGeneration: configuration.resetUserDataGeneration,
            appliedResetGeneration: appliedResetUserDataGeneration,
            hasSession: session != 0
        )
        let effectiveProfile = KeyboardRimeSessionProfilePolicy.effectiveProfile(
            requestedProfile: configuration.profile,
            activeRequestedProfile: activeSessionConfiguration?.requestedProfile,
            activeEffectiveProfile: activeSessionConfiguration?.effectiveProfile,
            hasSession: session != 0,
            requiresSessionReplacement: mutationPlan.requiresSessionReplacement
        ) {
            Self.effectiveStartupProfile(
                for: configuration.profile,
                now: Date().timeIntervalSince1970
            )
        }
        let requiresSchemaActivation = selectedSchemaID != effectiveProfile.schemaID
        let recordsStartupAttempt = mutationPlan.requiresSessionReplacement
            || activeSessionConfiguration?.requestedProfile != configuration.profile
            || requiresSchemaActivation
        let activationStartedAt = Date().timeIntervalSince1970
        if recordsStartupAttempt {
            Self.recordStartupAttempt(profile: effectiveProfile, now: activationStartedAt)
        }
        defer {
            if recordsStartupAttempt {
                Self.clearStartupAttempt()
            }
        }

        // A profile/schema change can reuse the live session and its pinned
        // fallback profile when phrases and user data are unchanged. The UI
        // has already ended its old marked-text transaction at this boundary.
        if !mutationPlan.requiresSessionReplacement, session != 0 {
            if requiresSchemaActivation {
                api.cleanComposition(session)
                guard api.selectSchema(session, andSchameId: effectiveProfile.schemaID) else {
                    return failActivationOnQueue(errorMessage: "中文数据不可用")
                }
                selectedSchemaID = effectiveProfile.schemaID
                appliedInputOptions = nil
            }
            applyDesiredOptionsOnQueue()
            activeSessionConfiguration = ActiveSessionConfiguration(
                requestedProfile: configuration.profile,
                effectiveProfile: effectiveProfile
            )
            return ActivationAttemptResult(succeeded: true, errorMessage: nil)
        }

        guard let sharedSupportURL = bundle.resourceURL?.appendingPathComponent("RimeSharedSupport", isDirectory: true),
              FileManager.default.fileExists(atPath: sharedSupportURL.path)
        else {
            rimeLog.error("RimeSharedSupport is missing from the keyboard bundle")
            return failActivationOnQueue(errorMessage: "中文数据缺失")
        }

        let prebuiltDataURL = sharedSupportURL.appendingPathComponent("build", isDirectory: true)
        guard FileManager.default.fileExists(atPath: prebuiltDataURL.appendingPathComponent("default.yaml").path) else {
            rimeLog.error("Rime prebuilt data is missing from RimeSharedSupport/build")
            return failActivationOnQueue(errorMessage: "中文数据未编译")
        }
        rimeLog.notice(
            "Rime activation resources ready schema=\(effectiveProfile.schemaID, privacy: .public)"
        )

        do {
            // The keyboard extension must only open prebuilt Rime data. Do not
            // run librime maintenance or deployment synchronously here: first
            // launch has to stay inside the extension watchdog budget.
            if mutationPlan.shouldResetUserData {
                try resetUserDataOnQueue()
                appliedResetUserDataGeneration = configuration.resetUserDataGeneration
                let appliedGeneration = appliedResetUserDataGeneration
                DispatchQueue.main.async { [weak self] in
                    self?.onResetUserDataApplied?(appliedGeneration)
                }
            } else if session != 0, mutationPlan.shouldWriteUserPhrases {
                resetAllSessionsOnQueue()
            }
            let userDataURL = try ensureUserDataDirectory()
            if mutationPlan.shouldWriteUserPhrases {
                try applyCustomPhrasesOnQueue(
                    content: configuration.userPhraseContent,
                    signature: configuration.userPhraseSignature,
                    userDataURL: userDataURL
                )
            }
            let traits = IRimeTraits()
            traits.sharedDataDir = sharedSupportURL.path
            traits.userDataDir = userDataURL.path
            traits.prebuiltDataDir = prebuiltDataURL.path
            traits.stagingDir = userDataURL.appendingPathComponent("build", isDirectory: true).path
            traits.distributionName = Self.distributionName
            traits.distributionCodeName = Self.distributionCodeName
            traits.distributionVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            // Do not set appName in an iOS keyboard extension. RimeSetup uses
            // it to initialize glog, whose file destination holds an
            // fcntl(F_SETLK) write lock. RimeFinalize does not shut glog down,
            // so that lock survives otherwise-complete Rime session cleanup
            // and iOS terminates the suspended extension with 0xdead10cc.
            // Typeforme already routes runtime diagnostics through OSLog.

            Self.globalLifecycle.prepareIfNeeded(
                api: api,
                traits: traits,
                ownerID: ownerID
            )
            if session == 0 {
                session = api.createSession()
                guard session != 0 else {
                    return failActivationOnQueue(errorMessage: "中文输入暂不可用")
                }
            }
            let schemaID = effectiveProfile.schemaID
            if selectedSchemaID != schemaID {
                let didSelectSchema = api.selectSchema(session, andSchameId: schemaID)
                if !didSelectSchema {
                    return failActivationOnQueue(errorMessage: "中文数据不可用")
                }
                selectedSchemaID = schemaID
                appliedInputOptions = nil
            }

            applyDesiredOptionsOnQueue()
            activeSessionConfiguration = ActiveSessionConfiguration(
                requestedProfile: configuration.profile,
                effectiveProfile: effectiveProfile
            )
            return ActivationAttemptResult(succeeded: true, errorMessage: nil)
        } catch {
            rimeLog.error("Failed to prepare Rime user data: \(error.localizedDescription, privacy: .public)")
            let message = mutationPlan.shouldResetUserData
                ? "中文学习数据无法重置"
                : "中文数据不可用"
            return failActivationOnQueue(errorMessage: message)
        }
    }

    private func resetAllSessionsOnQueue() {
        if session != 0 {
            _ = api.destroySession(session)
        }
        session = 0
        selectedSchemaID = nil
        appliedInputOptions = nil
        activeSessionConfiguration = nil
        latestCompositionOnQueue = .unavailable
    }

    private func resetUserDataOnQueue() throws {
        resetAllSessionsOnQueue()
        let userDataURL = try ensureUserDataDirectory()
        let contents = try FileManager.default.contentsOfDirectory(
            at: userDataURL,
            includingPropertiesForKeys: nil
        )
        for url in contents {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: userDataURL, withIntermediateDirectories: true)
        appliedUserPhraseSignature = nil
    }

    private func failActivationOnQueue(errorMessage: String) -> ActivationAttemptResult {
        resetAllSessionsOnQueue()
        return ActivationAttemptResult(succeeded: false, errorMessage: errorMessage)
    }

    /// Replays queued input as one engine transaction. A direct boundary uses
    /// the same raw fallback as Return instead of selecting a candidate; a
    /// later engine operation starts a fresh composition. The reusable
    /// projection is captured only once after the complete transaction.
    func processInputIfReady(
        _ input: KeyboardPendingRimeInput,
        asciiPunctuation: Bool,
        asciiMode: Bool
    ) -> RimeInputProcessResult {
        setDesiredOptions(asciiPunctuation: asciiPunctuation, asciiMode: asciiMode)
        guard startIfNeeded() else { return .notReady(notReadyUpdate()) }
        return rimeQueue.sync {
            guard isReadyOnQueue else { return .notReady(notReadyUpdate()) }
            applyOptionsOnQueue(asciiMode: asciiMode, asciiPunctuation: asciiPunctuation)
            var committedTexts: [String] = []
            var documentCommitText = ""
            func drainEngineCommit() {
                let priorCount = committedTexts.count
                drainCommit(into: &committedTexts)
                if committedTexts.count > priorCount {
                    documentCommitText += committedTexts[priorCount...].joined()
                }
            }
            for operation in input.operations {
                switch operation {
                case .engineCharacters(let characters):
                    for character in characters {
                        guard let scalar = character.unicodeScalars.first else { continue }
                        _ = api.processKeyCode(Int32(scalar.value), modifier: 0, andSession: session)
                        drainEngineCommit()
                    }
                case .spaceKey:
                    let hasComposition = !(api.getInput(session) ?? "").isEmpty
                        || api.getStatus(session)?.isComposing == true
                    if hasComposition {
                        _ = api.processKeyCode(32, modifier: 0, andSession: session)
                        drainEngineCommit()
                    } else {
                        documentCommitText += " "
                    }
                case .rawLiteralBoundary(let text):
                    let rawInput = api.getInput(session) ?? ""
                    api.cleanComposition(session)
                    documentCommitText += rawInput + text
                case .returnKey:
                    let rawInput = api.getInput(session) ?? ""
                    api.cleanComposition(session)
                    if !rawInput.isEmpty {
                        documentCommitText += rawInput
                    } else {
                        documentCommitText += "\n"
                    }
                }
            }
            return .processed(captureUpdateOnQueue(
                committedTexts: committedTexts,
                documentCommitText: documentCommitText
            ))
        }
    }

    func processKeyCode(_ code: Int32) -> RimeKeyboardUpdate {
        guard startIfNeeded() else { return notReadyUpdate() }
        return rimeQueue.sync {
            guard isReadyOnQueue else { return notReadyUpdate() }
            _ = api.processKeyCode(code, modifier: 0, andSession: session)
            var committedTexts: [String] = []
            drainCommit(into: &committedTexts)
            return captureUpdateOnQueue(committedTexts: committedTexts)
        }
    }

    func replaceCompositionInput(
        _ input: String,
        asciiPunctuation: Bool,
        asciiMode: Bool
    ) -> RimeKeyboardUpdate {
        setDesiredOptions(asciiPunctuation: asciiPunctuation, asciiMode: asciiMode)
        guard startIfNeeded() else { return notReadyUpdate() }
        return rimeQueue.sync {
            guard isReadyOnQueue else { return notReadyUpdate() }
            applyOptionsOnQueue(asciiMode: asciiMode, asciiPunctuation: asciiPunctuation)
            api.cleanComposition(session)
            var committedTexts: [String] = []
            for scalar in input.unicodeScalars {
                _ = api.processKeyCode(Int32(scalar.value), modifier: 0, andSession: session)
                drainCommit(into: &committedTexts)
            }
            return captureUpdateOnQueue(committedTexts: committedTexts)
        }
    }

    func processKeyCode(
        _ code: Int32,
        asciiPunctuation: Bool,
        asciiMode: Bool
    ) -> RimeKeyCodeProcessResult {
        setDesiredOptions(asciiPunctuation: asciiPunctuation, asciiMode: asciiMode)
        guard startIfNeeded() else {
            return RimeKeyCodeProcessResult(wasComposing: false, update: notReadyUpdate())
        }
        return rimeQueue.sync {
            guard isReadyOnQueue else {
                return RimeKeyCodeProcessResult(wasComposing: false, update: notReadyUpdate())
            }
            applyOptionsOnQueue(asciiMode: asciiMode, asciiPunctuation: asciiPunctuation)
            let wasComposing = latestCompositionOnQueue.isComposing
            _ = api.processKeyCode(code, modifier: 0, andSession: session)
            var committedTexts: [String] = []
            drainCommit(into: &committedTexts)
            return RimeKeyCodeProcessResult(
                wasComposing: wasComposing,
                update: captureUpdateOnQueue(committedTexts: committedTexts)
            )
        }
    }

    func selectCandidate(at index: Int) -> RimeKeyboardUpdate {
        guard startIfNeeded() else { return notReadyUpdate() }
        return rimeQueue.sync {
            guard isReadyOnQueue else { return notReadyUpdate() }
            _ = api.selectCandidate(session, andIndex: Int32(index))
            var committedTexts: [String] = []
            drainCommit(into: &committedTexts)
            return captureUpdateOnQueue(committedTexts: committedTexts)
        }
    }

    func commitVisibleComposition(_ text: String) -> RimeKeyboardUpdate {
        guard startIfNeeded() else {
            return notReadyUpdate(committedTexts: text.isEmpty ? [] : [text])
        }
        return rimeQueue.sync {
            guard isReadyOnQueue else {
                return notReadyUpdate(committedTexts: text.isEmpty ? [] : [text])
            }
            api.cleanComposition(session)
            return captureUpdateOnQueue(committedTexts: text.isEmpty ? [] : [text])
        }
    }

    func clearComposition() -> RimeKeyboardUpdate {
        guard startIfNeeded() else { return notReadyUpdate() }
        return rimeQueue.sync {
            guard isReadyOnQueue else { return notReadyUpdate() }
            api.cleanComposition(session)
            return captureUpdateOnQueue()
        }
    }

    /// Extends only the candidate projection for an already-rendered revision.
    /// It cannot produce commits or rewrite the composition projection.
    func expandedCandidateWindow(
        upTo candidateCount: Int,
        matching expectedWindow: RimeCandidateWindow
    ) -> RimeCandidateWindow? {
        guard candidateCount > expectedWindow.loadedCandidateCount else {
            return expectedWindow
        }
        guard expectedWindow.mayHaveMore else { return expectedWindow }
        guard isLatestRevision(expectedWindow.revision) else { return nil }
        guard startIfNeeded() else { return nil }

        return rimeQueue.sync {
            guard isLatestRevision(expectedWindow.revision) else { return nil }
            let signpostID = OSSignpostID(log: rimePerformanceLog)
            os_signpost(
                .begin,
                log: rimePerformanceLog,
                name: "RimeCandidateWindowExtension",
                signpostID: signpostID,
                "requested=%{public}d",
                candidateCount - expectedWindow.loadedCandidateCount
            )
            var loadedCandidateCount = 0
            defer {
                os_signpost(
                    .end,
                    log: rimePerformanceLog,
                    name: "RimeCandidateWindowExtension",
                    signpostID: signpostID,
                    "loaded=%{public}d",
                    loadedCandidateCount
                )
            }

            guard isReadyOnQueue,
                  let status = api.getStatus(session),
                  let context = api.getContext(session)
            else { return nil }

            let input = api.getInput(session) ?? ""
            let composition = context.composition
            let preedit = composition?.preedit ?? input
            let pageSize = max(Int(context.menu?.pageSize ?? 0), 1)
            let pageNo = max(Int(context.menu?.pageNo ?? 0), 0)
            let candidateOffset = pageSize * pageNo
            let liveIdentity = RimeCompositionSnapshot.Identity(
                isComposing: status.isComposing || !input.isEmpty,
                input: input,
                preedit: preedit,
                preeditSelectionStart: Int(composition?.selStart ?? 0),
                preeditSelectionEnd: Int(composition?.selEnd ?? 0)
            )
            guard liveIdentity == expectedWindow.compositionIdentity,
                  candidateOffset == expectedWindow.offset
            else { return nil }

            let missingCount = candidateCount - expectedWindow.loadedCandidateCount
            let additionalCandidates = api.getCandidateWith(
                Int32(expectedWindow.endIndex),
                andCount: Int32(missingCount),
                andSession: session
            ) ?? []
            loadedCandidateCount = additionalCandidates.count
            let additionalRawCandidates = makeKeyboardCandidates(
                from: additionalCandidates,
                absoluteStartIndex: expectedWindow.endIndex
            )
            var rawCandidates = expectedWindow.retainedCandidates
            rawCandidates.append(contentsOf: additionalRawCandidates)
            var displayCandidates = rawCandidates
            if displayCandidates.isEmpty,
               let preview = context.commitTextPreview,
               !preview.isEmpty,
               preview != input {
                displayCandidates = [RimeKeyboardCandidate(text: preview, selectionIndex: 0)]
            }
            let candidateWindowEndIndex = expectedWindow.endIndex
                + additionalCandidates.count

            return RimeCandidateWindow(
                revision: expectedWindow.revision,
                compositionIdentity: expectedWindow.compositionIdentity,
                candidates: displayCandidates,
                retainedCandidates: rawCandidates,
                offset: candidateOffset,
                pageSize: pageSize,
                endIndex: candidateWindowEndIndex,
                mayHaveMore: !(context.menu?.isLastPage ?? true)
                    && additionalCandidates.count >= missingCount,
                hasPreviousPage: pageNo > 0,
                hasNextPage: !(context.menu?.isLastPage ?? true)
            )
        }
    }

    private var isReadyOnQueue: Bool {
        stateLock.lock()
        let lifecycleIsReady = !isSuspended
            && activationPolicy.isReady
            && lastErrorMessage == nil
        stateLock.unlock()
        guard lifecycleIsReady,
              session != 0,
              let activeSessionConfiguration
        else { return false }
        return selectedSchemaID == activeSessionConfiguration.effectiveProfile.schemaID
    }

    private func issueProjectionRevision() -> (revision: UInt64, errorMessage: String?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        lastIssuedRevision += 1
        return (lastIssuedRevision, lastErrorMessage)
    }

    private func isLatestRevision(_ revision: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return revision != 0 && revision == lastIssuedRevision
    }

    private func captureUpdateOnQueue(
        committedTexts: [String] = [],
        documentCommitText: String? = nil
    ) -> RimeKeyboardUpdate {
        let signpostID = OSSignpostID(log: rimePerformanceLog)
        os_signpost(
            .begin,
            log: rimePerformanceLog,
            name: "RimeCandidateSnapshot",
            signpostID: signpostID
        )
        var loadedCandidateCount = 0
        defer {
            os_signpost(
                .end,
                log: rimePerformanceLog,
                name: "RimeCandidateSnapshot",
                signpostID: signpostID,
                "loaded=%{public}d",
                loadedCandidateCount
            )
        }

        let projection = issueProjectionRevision()
        guard isReadyOnQueue,
              let status = api.getStatus(session),
              let context = api.getContext(session)
        else {
            return unavailableUpdate(
                revision: projection.revision,
                errorMessage: projection.errorMessage,
                committedTexts: committedTexts,
                documentCommitText: documentCommitText
            )
        }

        let input = api.getInput(session) ?? ""
        let composition = context.composition
        let preedit = composition?.preedit ?? input
        let preeditSelectionStart = Int(composition?.selStart ?? 0)
        let preeditSelectionEnd = Int(composition?.selEnd ?? 0)
        let pageSize = max(Int(context.menu?.pageSize ?? 0), 1)
        let pageNo = max(Int(context.menu?.pageNo ?? 0), 0)
        let candidateOffset = pageSize * pageNo
        let menuCandidates = context.menu?.candidates ?? []
        let isLastPage = context.menu?.isLastPage ?? true
        let requestedCount = min(
            KeyboardCandidateWindowPolicy.initialEngineCount(
                menuCount: menuCandidates.count,
                pageSize: pageSize,
                isLastPage: isLastPage
            ),
            Int(Int32.max)
        )
        var rawCandidates = Array(menuCandidates.prefix(requestedCount))
        let missingCount = requestedCount - rawCandidates.count
        if missingCount > 0,
           let additionalCandidates = api.getCandidateWith(
               Int32(candidateOffset + rawCandidates.count),
               andCount: Int32(missingCount),
               andSession: session
           ) {
            rawCandidates.append(contentsOf: additionalCandidates.prefix(missingCount))
        }
        loadedCandidateCount = rawCandidates.count
        let candidates = makeKeyboardCandidates(
            from: rawCandidates,
            absoluteStartIndex: candidateOffset
        )
        var displayCandidates = candidates
        if displayCandidates.isEmpty,
           let preview = context.commitTextPreview,
           !preview.isEmpty,
           preview != input {
            displayCandidates = [RimeKeyboardCandidate(text: preview, selectionIndex: 0)]
        }

        let compositionSnapshot = RimeCompositionSnapshot(
            revision: projection.revision,
            isReady: true,
            isComposing: status.isComposing || !input.isEmpty,
            input: input,
            preedit: preedit,
            preeditSelectionStart: preeditSelectionStart,
            preeditSelectionEnd: preeditSelectionEnd,
            errorMessage: nil
        )
        let candidateWindow = RimeCandidateWindow(
            revision: projection.revision,
            compositionIdentity: compositionSnapshot.identity,
            candidates: displayCandidates,
            retainedCandidates: candidates,
            offset: candidateOffset,
            pageSize: pageSize,
            endIndex: candidateOffset + rawCandidates.count,
            mayHaveMore: requestedCount > 0
                && !isLastPage
                && rawCandidates.count >= requestedCount,
            hasPreviousPage: pageNo > 0,
            hasNextPage: !isLastPage
        )
        latestCompositionOnQueue = compositionSnapshot
        return RimeKeyboardUpdate(
            composition: compositionSnapshot,
            candidateWindow: candidateWindow,
            committedTexts: committedTexts,
            documentCommitText: documentCommitText
        )
    }

    private func makeKeyboardCandidates(
        from candidates: [IRimeCandidate],
        absoluteStartIndex: Int
    ) -> [RimeKeyboardCandidate] {
        candidates.enumerated().compactMap { rawIndex, candidate in
            guard let text = candidate.text, !text.isEmpty else { return nil }
            return RimeKeyboardCandidate(
                text: text,
                selectionIndex: KeyboardCandidateWindowPolicy.absoluteSelectionIndex(
                    candidateOffset: absoluteStartIndex,
                    rawIndex: rawIndex
                )
            )
        }
    }

    private func notReadyUpdate(committedTexts: [String] = []) -> RimeKeyboardUpdate {
        let projection = issueProjectionRevision()
        return unavailableUpdate(
            revision: projection.revision,
            errorMessage: projection.errorMessage,
            committedTexts: committedTexts
        )
    }

    private func unavailableUpdate(
        revision: UInt64,
        errorMessage: String?,
        committedTexts: [String],
        documentCommitText: String? = nil
    ) -> RimeKeyboardUpdate {
        let composition = RimeCompositionSnapshot(
            revision: revision,
            isReady: false,
            isComposing: false,
            input: "",
            preedit: "",
            preeditSelectionStart: 0,
            preeditSelectionEnd: 0,
            errorMessage: errorMessage
        )
        return RimeKeyboardUpdate(
            composition: composition,
            candidateWindow: .empty(
                revision: revision,
                compositionIdentity: composition.identity
            ),
            committedTexts: committedTexts,
            documentCommitText: documentCommitText
        )
    }

    private func setDesiredOptions(asciiPunctuation: Bool, asciiMode: Bool) {
        stateLock.lock()
        desiredInputOptions = KeyboardRimeInputOptions(
            asciiMode: asciiMode,
            asciiPunctuation: asciiPunctuation
        )
        stateLock.unlock()
    }

    private func desiredInputOptionsSnapshot() -> KeyboardRimeInputOptions {
        stateLock.lock()
        defer { stateLock.unlock() }
        return desiredInputOptions
    }

    /// Preference-only changes are serialized with key mutations, but never
    /// enter the activation lifecycle. If startup is still running, that
    /// activation reads the same desired snapshot before publishing ready.
    private func applyDesiredOptionsToLiveSession() {
        rimeQueue.async { [weak self] in
            guard let self, self.isReadyOnQueue else { return }
            self.applyDesiredOptionsOnQueue()
        }
    }

    private func applyDesiredOptionsOnQueue() {
        let options = desiredInputOptionsSnapshot()
        applyOptionsOnQueue(
            asciiMode: options.asciiMode,
            asciiPunctuation: options.asciiPunctuation
        )
    }

    private func applyOptionsOnQueue(asciiMode: Bool, asciiPunctuation: Bool) {
        let options = KeyboardRimeInputOptions(
            asciiMode: asciiMode,
            asciiPunctuation: asciiPunctuation
        )
        guard appliedInputOptions != options else { return }
        _ = api.setOption(session, andOption: "ascii_mode", andValue: asciiMode)
        _ = api.setOption(session, andOption: "ascii_punct", andValue: asciiPunctuation)
        appliedInputOptions = options
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

    private func drainCommit(into committedTexts: inout [String]) {
        guard let text = api.getCommit(session), !text.isEmpty else { return }
        committedTexts.append(text)
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

    private static func effectiveStartupProfile(
        for profile: RimeKeyboardProfile,
        now: TimeInterval
    ) -> RimeKeyboardProfile {
        guard profile.dictionaryTier != .standard else { return profile }
        if let fallback = activeStartupFallback(now: now),
           fallback.dictionaryTier == profile.dictionaryTier {
            return standardFallbackProfile(from: profile, reason: "active fallback")
        }
        guard let attempt = unresolvedStartupAttempt(now: now),
              attempt.dictionaryTier == profile.dictionaryTier
        else { return profile }
        _ = saveStartupFallback(dictionaryTier: profile.dictionaryTier, now: now)
        reportStartupFallbackToHost(dictionaryTier: profile.dictionaryTier)
        return standardFallbackProfile(from: profile, reason: "previous startup did not finish")
    }

    private static func standardFallbackProfile(
        from profile: RimeKeyboardProfile,
        reason: String
    ) -> RimeKeyboardProfile {
        var fallback = profile
        fallback.dictionaryTier = .standard
        rimeLog.error(
            "Rime startup falling back to standard dictionary from \(profile.dictionaryTier.rawValue, privacy: .public): \(reason, privacy: .public)"
        )
        return fallback
    }

    private static func unresolvedStartupAttempt(now: TimeInterval) -> StartupAttemptMarker? {
        guard let data = UserDefaults.standard.data(forKey: startupAttemptDefaultsKey),
              let attempt = try? JSONDecoder().decode(StartupAttemptMarker.self, from: data)
        else { return nil }
        let age = now - attempt.startedAt
        guard age >= 0, age <= startupAttemptMaxAge else {
            UserDefaults.standard.removeObject(forKey: startupAttemptDefaultsKey)
            return nil
        }
        return attempt
    }

    private static func activeStartupFallback(now: TimeInterval) -> StartupFallbackMarker? {
        guard let fallback = storedStartupFallback(now: now),
              now <= fallback.expiresAt
        else { return nil }
        return fallback
    }

    private static func storedStartupFallback(now: TimeInterval) -> StartupFallbackMarker? {
        guard let data = UserDefaults.standard.data(forKey: startupFallbackDefaultsKey),
              let fallback = try? JSONDecoder().decode(StartupFallbackMarker.self, from: data)
        else { return nil }
        let historyExpiresAt = max(fallback.expiresAt, fallback.lastFailedAt + startupFallbackFailureWindow)
        guard now <= historyExpiresAt else {
            UserDefaults.standard.removeObject(forKey: startupFallbackDefaultsKey)
            return nil
        }
        return fallback
    }

    private static func recordStartupAttempt(profile: RimeKeyboardProfile, now: TimeInterval) {
        let marker = StartupAttemptMarker(
            schemaID: profile.schemaID,
            dictionaryTier: profile.dictionaryTier,
            startedAt: now
        )
        guard let data = try? JSONEncoder().encode(marker) else { return }
        UserDefaults.standard.set(data, forKey: startupAttemptDefaultsKey)
    }

    private static func clearStartupAttempt() {
        UserDefaults.standard.removeObject(forKey: startupAttemptDefaultsKey)
    }

    @discardableResult
    private static func saveStartupFallback(
        dictionaryTier: KeyboardRimeDictionaryTier,
        now: TimeInterval
    ) -> StartupFallbackMarker {
        let previous = storedStartupFallback(now: now)
        let continuesRecentFailure: Bool
        if let previous {
            continuesRecentFailure = previous.dictionaryTier == dictionaryTier
                && now - previous.lastFailedAt <= startupFallbackFailureWindow
        } else {
            continuesRecentFailure = false
        }
        let failureCount = continuesRecentFailure ? min((previous?.failureCount ?? 0) + 1, startupFallbackDurations.count) : 1
        let firstFailedAt = continuesRecentFailure ? (previous?.firstFailedAt ?? now) : now
        let duration = startupFallbackDuration(forFailureCount: failureCount)
        let marker = StartupFallbackMarker(
            dictionaryTier: dictionaryTier,
            failureCount: failureCount,
            firstFailedAt: firstFailedAt,
            lastFailedAt: now,
            expiresAt: now + duration
        )
        if let data = try? JSONEncoder().encode(marker) {
            UserDefaults.standard.set(data, forKey: startupFallbackDefaultsKey)
        }
        return marker
    }

    private static func startupFallbackDuration(forFailureCount failureCount: Int) -> TimeInterval {
        let index = min(max(failureCount, 1) - 1, startupFallbackDurations.count - 1)
        return startupFallbackDurations[index]
    }

    private static func reportStartupFallbackToHost(
        dictionaryTier: KeyboardRimeDictionaryTier
    ) {
        let issue = KeyboardHostIssueReport(
            commandID: nil,
            message: "中文词典 \(dictionaryTier.title) 上次启动未完成，已临时切回 Standard；后续重新启动输入引擎时会再次尝试。"
        )
        if KeyboardSharedDefaults.saveKeyboardHostIssue(issue) {
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.keyboardIssueReported)
        }
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
        RimeUserPhraseNormalizer.normalized(phrases, sortsOutput: false)
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
#endif
