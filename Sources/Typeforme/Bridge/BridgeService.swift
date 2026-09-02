import Darwin
import Foundation

enum BridgeServiceError: LocalizedError {
    case invalidAudio
    case emptyTranscript
    case missingSession
    case invalidRequest(String)
    case settingsConflict(String)

    var errorDescription: String? {
        switch self {
        case .invalidAudio:
            return "Invalid or empty audio payload"
        case .emptyTranscript:
            return "Audio produced an empty transcript"
        case .missingSession:
            return "Refine session not found or expired"
        case .invalidRequest(let why):
            return "Invalid request: \(why)"
        case .settingsConflict(let currentRevision):
            return "Settings changed on the Mac; reload before saving (current revision: \(currentRevision))"
        }
    }
}

private struct BridgeSession {
    let id: String
    let rawTranscript: String
    let languageIDs: [String]
    let correctionMode: CorrectionMode
    let appName: String?
    let bundleID: String?
    let appCategory: AppCategory
    let contextBefore: String
    let contextAfter: String
    let createdAt: Date
}

/// The WebSocket audio loop is intentionally not MainActor-bound. Holding the
/// lock through each synchronous append makes deactivation a hard boundary:
/// once `deactivate()` returns, an old socket cannot write into a reset or
/// subsequently reused recognizer session.
final class BridgeLivePreviewInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var process: (any ASRLivePreviewSession)?
    private var lastAppendAt: Date

    init(process: any ASRLivePreviewSession, createdAt: Date = Date()) {
        self.process = process
        self.lastAppendAt = createdAt
    }

    @discardableResult
    func append(_ data: Data, at date: Date = Date()) -> Bool {
        lock.withLock {
            guard let process else { return false }
            process.appendPCM16kMonoFloat32Data(data)
            lastAppendAt = date
            return true
        }
    }

    func deactivate() {
        lock.withLock {
            process = nil
        }
    }

    var lastActivityAt: Date {
        lock.withLock { lastAppendAt }
    }
}

@MainActor
protocol BridgeLivePreviewLeaseProviding {
    func take(
        source: VoiceLivePreviewSource,
        requestedLanguageIDs: [String],
        diagnosticID: String,
        onTranscript: @escaping (String) -> Void
    ) async throws -> ASRLivePreviewLease
}

@MainActor
struct DefaultBridgeLivePreviewLeaseProvider: BridgeLivePreviewLeaseProviding {
    func take(
        source: VoiceLivePreviewSource,
        requestedLanguageIDs: [String],
        diagnosticID: String,
        onTranscript: @escaping (String) -> Void
    ) async throws -> ASRLivePreviewLease {
        try await ASRLivePreviewLeaseFactory.take(
            source: source,
            requestedLanguageIDs: requestedLanguageIDs,
            diagnosticID: diagnosticID,
            onTranscript: onTranscript
        )
    }
}

@MainActor
final class BridgeLivePreviewSession {
    let id: String
    let lease: ASRLivePreviewLease
    let createdAt: Date
    var updatedAt: Date
    var lastTranscript: String?
    let inputGate: BridgeLivePreviewInputGate
    private var finishTask: Task<BridgeLivePreviewFinishOperationResult, Never>?
    private var teardownTask: Task<Void, Never>?

    var provider: String { lease.provider }
    var languageIDs: [String] { lease.languageIDs }
    private var process: any ASRLivePreviewSession { lease.session }
    var lastActivityAt: Date { max(updatedAt, inputGate.lastActivityAt) }

    init(
        id: String,
        lease: ASRLivePreviewLease,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.lease = lease
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.inputGate = BridgeLivePreviewInputGate(
            process: lease.session,
            createdAt: createdAt
        )
    }

    func beginFinish(timeout: TimeInterval) -> Task<BridgeLivePreviewFinishOperationResult, Never> {
        inputGate.deactivate()
        if let finishTask {
            return finishTask
        }
        let process = self.process
        let session = self
        let task = Task { @MainActor [weak session] in
            let completed = await process.finishInputAndWaitForFinal(timeout: timeout)
            let wasCancelled = Task.isCancelled
            if !completed && !wasCancelled {
                process.terminate(reason: "bridge_finish_timeout")
            }
            return BridgeLivePreviewFinishOperationResult(
                completed: completed,
                wasCancelled: wasCancelled,
                transcript: process.currentTranscript() ?? session?.lastTranscript,
                finishedAt: Date()
            )
        }
        finishTask = task
        return task
    }

    /// Cancellation owns teardown once requested. If finalization is already
    /// running, it is cancelled and joined before reset touches the process.
    /// This prevents finish/reset from racing and guarantees one lease return.
    func cancelAndTeardown() -> Task<Void, Never> {
        inputGate.deactivate()
        if let teardownTask {
            return teardownTask
        }
        let finishTask = self.finishTask
        finishTask?.cancel()
        let process = self.process
        let lease = self.lease
        let task = Task { @MainActor in
            if let finishTask {
                _ = await finishTask.value
            }
            let reset = await process.cancelInputAndWaitForReset(timeout: 2)
            if reset {
                await lease.returnIdle(reason: "bridge_cancelled")
            } else {
                process.terminate(reason: "bridge_cancel_timeout")
                await lease.preloadReplacement()
            }
        }
        teardownTask = task
        return task
    }

    func finishAndTeardown(completed: Bool) -> Task<Void, Never> {
        inputGate.deactivate()
        if let teardownTask {
            return teardownTask
        }
        let lease = self.lease
        let task = Task { @MainActor in
            if completed {
                await lease.returnIdle(reason: "bridge_finished")
            } else {
                await lease.preloadReplacement()
            }
        }
        teardownTask = task
        return task
    }
}

struct BridgeLivePreviewFinishOperationResult: Sendable {
    let completed: Bool
    let wasCancelled: Bool
    let transcript: String?
    let finishedAt: Date
}

private struct BridgeCompletedLivePreview {
    let response: BridgeLivePreviewFinishResponse
    let completedAt: Date
}

private struct BridgePendingLivePreviewStart {
    let token: UUID
    let task: Task<BridgeLivePreviewStartResponse, Error>
}

private struct BridgeCorrectionOutput {
    let result: CorrectionResult
    let status: String
    let error: String?
    let debugTrace: CorrectionDebugTrace?
}

@MainActor
final class BridgeService {
    private let dictionary: UserDictionaryStore
    private let textEditService: TextEditService
    private let livePreviewLeaseProvider: any BridgeLivePreviewLeaseProviding
    private let livePreviewRecognitionSourcesProvider: @MainActor () -> [RecognitionSource]
    private var sessions: [String: BridgeSession] = [:]
    private var livePreviewSessions: [String: BridgeLivePreviewSession] = [:]
    private var pendingLivePreviewStarts: [String: BridgePendingLivePreviewStart] = [:]
    private var completedLivePreviews: [String: BridgeCompletedLivePreview] = [:]
    private var inFlightLivePreviewTeardowns: [UUID: Task<Void, Never>] = [:]
    private var livePreviewPruneTask: Task<Void, Never>?
    private var livePreviewStartsOpen = true
    private var livePreviewListenerRunID: UUID?

    private static let sessionTTL: TimeInterval = 15 * 60
    private static let maxSessions = 128
    private static let livePreviewSessionTTL: TimeInterval = 3 * 60
    private static var livePreviewFinishTimeout: TimeInterval { AppSettings.asrTimeoutSeconds }
    private static let livePreviewPruneIntervalNanoseconds: UInt64 = 30 * 1_000_000_000
    private static let maxLivePreviewSessions = 8
    private static let completedLivePreviewTTL: TimeInterval = 60
    private static let maxCompletedLivePreviews = 32

    init(
        dictionary: UserDictionaryStore,
        livePreviewLeaseProvider: any BridgeLivePreviewLeaseProviding = DefaultBridgeLivePreviewLeaseProvider(),
        livePreviewRecognitionSourcesProvider: @escaping @MainActor () -> [RecognitionSource] = {
            AppSettings.enabledRecognitionSources
        }
    ) {
        self.dictionary = dictionary
        self.textEditService = TextEditService(dictionary: dictionary)
        self.livePreviewLeaseProvider = livePreviewLeaseProvider
        self.livePreviewRecognitionSourcesProvider = livePreviewRecognitionSourcesProvider
        self.livePreviewPruneTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.livePreviewPruneIntervalNanoseconds)
                self?.pruneExpiredLivePreviewSessions()
            }
        }
    }

    deinit {
        livePreviewPruneTask?.cancel()
    }

    func health() -> BridgeHealthResponse {
        BridgeHealthResponse(
            ok: true,
            service: "Typeforme Bridge",
            version: appVersion(),
            bridgePort: AppSettings.bridgePort,
            settingsRevision: BridgeSettingsPayload.currentSettingsRevision(
                userDictionary: dictionary.sortedSnapshot()
            )
        )
    }

    func settings() -> BridgeSettingsPayload {
        Task { @MainActor in
            await ASRFactory.shared.preloadNvidiaNemotron()
        }
        return BridgeSettingsPayload.current(userDictionary: dictionary.sortedSnapshot())
    }

    func updateSettings(_ request: BridgeSettingsUpdateRequest) async throws -> BridgeSettingsPayload {
        let currentRevision = BridgeSettingsPayload.currentSettingsRevision(
            userDictionary: dictionary.sortedSnapshot()
        )
        let expectedRevision = request.expectedSettingsRevision
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard expectedRevision == currentRevision else {
            throw BridgeServiceError.settingsConflict(currentRevision)
        }

        let oldSources = AppSettings.configuredRecognitionSources
        let sources = try resolveRecognitionSources(request.enabledRecognitionSources) ?? oldSources
        let settingsFastASRSource = try resolveFastASRSource(request.fastASRSource) ?? AppSettings.fastASRSource
        let settingsCorrectionMode = try resolveSettingsCorrectionMode(request.correctionMode) ?? AppSettings.correctionMode
        try Self.validateEnabledRecognitionSources(
            sources,
            languageIDs: request.languageIDs ?? AppSettings.asrCanonicalLanguageIDs
        )
        let requestedLivePreviewSource: VoiceLivePreviewSource?
        if let rawLivePreviewSource = request.livePreviewSource {
            requestedLivePreviewSource = try resolveLivePreviewSource(
                rawLivePreviewSource,
                sources: sources,
                correctionMode: settingsCorrectionMode
            )
        } else {
            requestedLivePreviewSource = nil
        }
        let supportedLanguages = ASRLanguageSelection.supportedOptions(for: sources)
        let languageIDs: [String]
        if supportedLanguages.isEmpty {
            languageIDs = []
        } else if let requestedLanguageIDs = request.languageIDs {
            languageIDs = try Self.resolveSettingsLanguageIDs(
                requestedLanguageIDs,
                supportedOptions: supportedLanguages
            )
        } else {
            languageIDs = ASRLanguageSelection.validatedIDs(
                AppSettings.asrCanonicalLanguageIDs,
                supportedOptions: supportedLanguages
            )
        }
        try validateCorrectionModeAvailable(
            settingsCorrectionMode,
            sources: sources,
            fastASRSource: settingsFastASRSource,
            languageIDs: languageIDs
        )

        let proposedCorrectionBackend = try request.correctionBackend.map(resolveCorrectionBackend) ?? AppSettings.correctionBackend
        let proposedExternalLLMBaseURL = try request.externalLLMBaseURL.map(normalizedExternalLLMBaseURL)
            ?? AppSettings.externalLLMBaseURL
        let proposedExternalLLMModel = request.externalLLMModel?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? AppSettings.externalLLMModel

        try Self.validateExternalCorrectionSettingsIfNeeded(
            proposedCorrectionBackend,
            externalLLMBaseURL: proposedExternalLLMBaseURL,
            externalLLMModel: proposedExternalLLMModel
        )

        // Resolve every value that can fail before changing any persisted
        // setting. updateSettings is MainActor-isolated, so the synchronous
        // commit below is observed as one revision by other Bridge requests.
        var resolvedModelIDs: [RecognitionSource: String] = [:]
        if let modelIDs = request.asrModelIDsByRecognitionSource {
            for (sourceID, rawModelID) in modelIDs {
                guard let source = RecognitionSource(
                    rawValue: sourceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                ) else {
                    throw BridgeServiceError.invalidRequest("Unknown recognition source: \(sourceID)")
                }
                resolvedModelIDs[source] = try resolveASRModelID(rawModelID, source: source)
            }
        }

        let proposedNumberOutputPreference: NumberOutputPreference?
        if let rawPreference = request.numberOutputPreference {
            guard let preference = NumberOutputPreference(rawValue: rawPreference) else {
                throw BridgeServiceError.invalidRequest("Unknown number output preference: \(rawPreference)")
            }
            proposedNumberOutputPreference = preference
        } else {
            proposedNumberOutputPreference = nil
        }

        let proposedPunctuationPreference: PunctuationOutputPreference?
        if let rawPreference = request.punctuationPreference {
            guard let preference = PunctuationOutputPreference(rawValue: rawPreference) else {
                throw BridgeServiceError.invalidRequest("Unknown punctuation preference: \(rawPreference)")
            }
            proposedPunctuationPreference = preference
        } else {
            proposedPunctuationPreference = nil
        }

        let livePreviewSourceToApply: VoiceLivePreviewSource?
        if let requestedLivePreviewSource {
            livePreviewSourceToApply = requestedLivePreviewSource
        } else if request.enabledRecognitionSources != nil || request.correctionMode != nil {
            livePreviewSourceToApply = BridgeSettingsPayload.normalizedLivePreviewSource(
                AppSettings.voiceLivePreviewSource,
                sources: sources,
                correctionMode: settingsCorrectionMode
            )
        } else {
            livePreviewSourceToApply = nil
        }
        let normalizedDictionary = request.userDictionary.map(DictionaryEntry.normalizedEntries)

        if request.enabledRecognitionSources != nil {
            AppSettings.setEnabledRecognitionSources(sources)
        }

        for (source, modelID) in resolvedModelIDs {
            switch source {
            case .qwen:
                UserDefaults.standard.set(modelID, forKey: AppSettings.Keys.asrQwenLlamaModelID)
            case .nvidiaNemotron:
                UserDefaults.standard.set(modelID, forKey: AppSettings.Keys.asrNvidiaNemotronModelID)
            case .appleSpeech:
                break
            }
        }
        if request.languageIDs != nil || request.enabledRecognitionSources != nil {
            UserDefaults.standard.set(
                ASRLanguageSelection.rawValue(for: languageIDs, supportedOptions: supportedLanguages),
                forKey: AppSettings.Keys.asrLanguageIDs
            )
        }

        if let timeoutSec = request.asrTimeoutSec {
            let clamped = BridgeSettingsPayload.clampedASRTimeoutSec(timeoutSec)
            UserDefaults.standard.set(Double(clamped), forKey: AppSettings.Keys.asrQwenLlamaTimeoutSec)
            UserDefaults.standard.set(Double(clamped), forKey: AppSettings.Keys.asrNvidiaNemotronTimeoutSec)
        }

        if request.correctionBackend != nil {
            UserDefaults.standard.set(proposedCorrectionBackend.rawValue, forKey: AppSettings.Keys.correctionBackend)
        }
        if let timeoutMs = request.correctionTimeoutMs {
            UserDefaults.standard.set(
                BridgeSettingsPayload.clampedCorrectionTimeoutMs(timeoutMs),
                forKey: AppSettings.Keys.correctionTimeoutMs
            )
        }
        if let timeoutMs = request.correctionColdTimeoutMs {
            UserDefaults.standard.set(
                BridgeSettingsPayload.clampedCorrectionColdTimeoutMs(timeoutMs),
                forKey: AppSettings.Keys.correctionColdTimeoutMs
            )
        }
        if request.externalLLMBaseURL != nil {
            UserDefaults.standard.set(proposedExternalLLMBaseURL, forKey: AppSettings.Keys.externalLLMBaseURL)
        }
        if request.externalLLMModel != nil {
            UserDefaults.standard.set(proposedExternalLLMModel, forKey: AppSettings.Keys.externalLLMModel)
        }
        if request.correctionMode != nil {
            UserDefaults.standard.set(settingsCorrectionMode.rawValue, forKey: AppSettings.Keys.correctionMode)
        }
        if request.fastASRSource != nil {
            UserDefaults.standard.set(settingsFastASRSource.rawValue, forKey: AppSettings.Keys.fastASRSource)
        }
        if let livePreviewSourceToApply {
            applyLivePreviewSource(livePreviewSourceToApply)
        }
        if let preference = proposedNumberOutputPreference {
            UserDefaults.standard.set(preference.rawValue, forKey: AppSettings.Keys.numberOutputPreference)
        }
        if let preference = proposedPunctuationPreference {
            UserDefaults.standard.set(preference.rawValue, forKey: AppSettings.Keys.punctuationPreference)
        }

        if let autoCommit = request.autoCommit {
            UserDefaults.standard.set(autoCommit, forKey: AppSettings.Keys.correctionAutoCommit)
        }
        if let normalizedDictionary {
            dictionary.replaceEntries(normalizedDictionary)
        }

        UserDefaults.standard.synchronize()
        startDownloadsForCurrentServerSettings()
        Task { @MainActor in
            await ASRFactory.shared.preloadCachedActiveModel()
            _ = await CorrectorFactory.shared.preloadActiveModels()
        }
        return BridgeSettingsPayload.current(userDictionary: dictionary.sortedSnapshot())
    }

    func startLivePreview(
        _ request: BridgeLivePreviewStartRequest,
        listenerRunID: UUID? = nil
    ) async throws -> BridgeLivePreviewStartResponse {
        guard livePreviewStartsOpen,
              listenerRunID == nil || listenerRunID == livePreviewListenerRunID
        else {
            throw BridgeServiceError.invalidRequest("Bridge listener is stopping")
        }
        pruneExpiredLivePreviewSessions()
        let correctionMode = try resolveCorrectionMode(request.correctionMode)
        let id = UUID().uuidString
        let requestedLanguageIDs = resolveLivePreviewLanguageIDs(ids: request.languageIDs, mode: request.languageMode)
        let previewSource = try resolveLivePreviewSource(
            request.livePreviewSource,
            sources: livePreviewRecognitionSourcesProvider(),
            correctionMode: correctionMode
        )
        guard previewSource != .off else {
            throw BridgeServiceError.invalidRequest("Live preview is off")
        }
        guard livePreviewSessions.count + pendingLivePreviewStarts.count < Self.maxLivePreviewSessions else {
            throw BridgeServiceError.invalidRequest("Too many active live preview sessions")
        }
        let requestStartedAt = Date()
        Log.bridge.notice(
            "Bridge live preview start session=\(Self.logID(id), privacy: .public) source=\(previewSource.rawValue, privacy: .public)"
        )
        let leaseProvider = livePreviewLeaseProvider
        let transcriptHandler: (String) -> Void = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.recordLivePreviewTranscript(sessionID: id, text: text)
            }
        }
        let token = UUID()
        let task = Task { @MainActor [weak self] () throws -> BridgeLivePreviewStartResponse in
            guard let self else { throw CancellationError() }
            return try await self.completeLivePreviewStart(
                sessionID: id,
                token: token,
                listenerRunID: listenerRunID,
                source: previewSource,
                requestedLanguageIDs: requestedLanguageIDs,
                requestStartedAt: requestStartedAt,
                leaseProvider: leaseProvider,
                transcriptHandler: transcriptHandler
            )
        }
        pendingLivePreviewStarts[id] = BridgePendingLivePreviewStart(
            token: token,
            task: task
        )
        defer {
            if pendingLivePreviewStarts[id]?.token == token {
                pendingLivePreviewStarts.removeValue(forKey: id)
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func completeLivePreviewStart(
        sessionID: String,
        token: UUID,
        listenerRunID: UUID?,
        source: VoiceLivePreviewSource,
        requestedLanguageIDs: [String],
        requestStartedAt: Date,
        leaseProvider: any BridgeLivePreviewLeaseProviding,
        transcriptHandler: @escaping (String) -> Void
    ) async throws -> BridgeLivePreviewStartResponse {
        let lease: ASRLivePreviewLease
        do {
            lease = try await leaseProvider.take(
                source: source,
                requestedLanguageIDs: requestedLanguageIDs,
                diagnosticID: sessionID,
                onTranscript: transcriptHandler
            )
        } catch {
            guard livePreviewStartIsCurrent(
                sessionID: sessionID,
                token: token,
                listenerRunID: listenerRunID
            ), !Task.isCancelled else { throw CancellationError() }
            if error is CancellationError {
                throw CancellationError()
            }
            throw BridgeServiceError.invalidRequest(error.localizedDescription)
        }

        guard livePreviewStartIsCurrent(
            sessionID: sessionID,
            token: token,
            listenerRunID: listenerRunID
        ), !Task.isCancelled else {
            await lease.returnIdle(reason: "bridge_start_cancelled")
            throw CancellationError()
        }
        let createdAt = Date()
        livePreviewSessions[sessionID] = BridgeLivePreviewSession(
            id: sessionID,
            lease: lease,
            createdAt: createdAt
        )
        Log.bridge.notice(
            "Bridge live preview started session=\(Self.logID(sessionID), privacy: .public) provider=\(lease.provider, privacy: .public) languages=\(lease.languageIDs.joined(separator: ","), privacy: .public) elapsed_ms=\(self.elapsedMs(since: requestStartedAt), privacy: .public)"
        )
        return BridgeLivePreviewStartResponse(
            sessionID: sessionID,
            provider: lease.provider,
            languageIDs: lease.languageIDs,
            audioFormat: BridgeLivePreviewStartResponse.audioFormat,
            startedAt: createdAt.timeIntervalSince1970
        )
    }

    private func livePreviewStartIsCurrent(
        sessionID: String,
        token: UUID,
        listenerRunID: UUID?
    ) -> Bool {
        livePreviewStartsOpen
            && pendingLivePreviewStarts[sessionID]?.token == token
            && (listenerRunID == nil || listenerRunID == livePreviewListenerRunID)
    }

    func livePreviewInputGate(sessionID: String) throws -> BridgeLivePreviewInputGate {
        pruneExpiredLivePreviewSessions()
        guard let session = livePreviewSessions[sessionID] else {
            throw BridgeServiceError.missingSession
        }
        session.updatedAt = Date()
        return session.inputGate
    }

    func finishLivePreview(sessionID: String) async throws -> BridgeLivePreviewFinishResponse {
        pruneExpiredLivePreviewSessions()
        if let completed = completedLivePreviews[sessionID] {
            return completed.response
        }
        guard let session = livePreviewSessions[sessionID] else {
            throw BridgeServiceError.missingSession
        }
        session.updatedAt = Date()
        Log.bridge.notice(
            "Bridge live preview finish session=\(Self.logID(sessionID), privacy: .public) elapsed_ms=\(self.elapsedMs(since: session.createdAt), privacy: .public)"
        )
        let finishTask = session.beginFinish(timeout: Self.livePreviewFinishTimeout)
        let result = await finishTask.value
        if let completed = completedLivePreviews[sessionID] {
            return completed.response
        }
        guard livePreviewSessions[sessionID] === session else {
            throw BridgeServiceError.missingSession
        }
        let response = BridgeLivePreviewFinishResponse(
            sessionID: session.id,
            provider: session.provider,
            text: result.transcript,
            finishedAt: result.finishedAt.timeIntervalSince1970
        )
        completedLivePreviews[sessionID] = BridgeCompletedLivePreview(
            response: response,
            completedAt: result.finishedAt
        )
        publishLivePreviewEvent(session: session, text: result.transcript, isFinal: true)
        livePreviewSessions.removeValue(forKey: sessionID)
        pruneCompletedLivePreviews()
        let teardownTask = trackLivePreviewTeardown(
            session.finishAndTeardown(completed: result.completed)
        )
        await teardownTask.value
        Log.bridge.notice(
            "Bridge live preview finished session=\(Self.logID(sessionID), privacy: .public) completed=\(result.completed, privacy: .public) text_chars=\(result.transcript?.count ?? 0, privacy: .public) elapsed_ms=\(self.elapsedMs(since: session.createdAt), privacy: .public)"
        )
        return response
    }

    func cancelLivePreview(sessionID: String) async -> BridgeLivePreviewCancelResponse {
        pruneExpiredLivePreviewSessions()
        if let teardownTask = removeLivePreviewSession(id: sessionID) {
            await teardownTask.value
        }
        return BridgeLivePreviewCancelResponse(sessionID: sessionID)
    }

    func beginAcceptingLivePreviews(listenerRunID: UUID) {
        livePreviewStartsOpen = true
        livePreviewListenerRunID = listenerRunID
    }

    func beginCancelAllLivePreviewsIfOwned(
        listenerRunID: UUID
    ) -> Task<Void, Never>? {
        guard livePreviewListenerRunID == listenerRunID else { return nil }
        return beginCancelAllLivePreviews()
    }

    /// Establishes the stop boundary synchronously on the main actor, then
    /// joins every start task and active teardown. Each start task owns its
    /// acquired lease until it either registers a session or returns it.
    func beginCancelAllLivePreviews() -> Task<Void, Never> {
        livePreviewStartsOpen = false
        livePreviewListenerRunID = nil

        let pendingStarts = Array(pendingLivePreviewStarts.values)
        pendingLivePreviewStarts.removeAll()
        for pendingStart in pendingStarts {
            pendingStart.task.cancel()
        }

        let activeIDs = Array(livePreviewSessions.keys)
        for id in activeIDs {
            _ = removeLivePreviewSession(id: id)
        }
        let teardownTasks = Array(inFlightLivePreviewTeardowns.values)
        completedLivePreviews.removeAll()

        return Task { @MainActor in
            for pendingStart in pendingStarts {
                _ = await pendingStart.task.result
            }
            for teardownTask in teardownTasks {
                await teardownTask.value
            }
        }
    }

    func cancelAllLivePreviewsAndWait() async {
        await beginCancelAllLivePreviews().value
    }

    func dictate(_ request: BridgeDictateRequest) async throws -> BridgeDictateResponse {
        pruneExpiredSessions()
        let start = Date()
        let jobID = BridgeClientJobID.normalized(request.clientJobID)
        var audioURLToCleanup = request.audioFileURL
        defer {
            if let audioURLToCleanup {
                try? FileManager.default.removeItem(at: audioURLToCleanup)
            }
        }
        let correctionMode = try resolveCorrectionMode(request.correctionMode)
        try validateCorrectionModeAvailable(correctionMode)
        let requestedLanguageIDs = resolveLanguageIDs(
            ids: request.languageIDs,
            mode: request.languageMode,
            sources: AppSettings.enabledRecognitionSources
        )
        let fastRoute: FastASRRoute?
        if correctionMode == .fast {
            fastRoute = try FastASRRoute.resolve(languageIDs: requestedLanguageIDs)
        } else {
            fastRoute = nil
        }
        let transcriptionSources = try fastRoute.map { [$0.source] } ?? recognitionSources(for: correctionMode)
        guard !transcriptionSources.isEmpty else {
            throw BridgeServiceError.invalidRequest("No ASR source enabled")
        }
        let languageIDs = fastRoute?.languageIDs ?? requestedLanguageIDs
        let numberOutputPreference = AppSettings.numberOutputPreference
        let punctuationPreference = AppSettings.punctuationPreference
        let correctionTimeoutMs = AppSettings.correctionTimeoutMs
        let userDictionary = dictionary.sortedSnapshot()
        let correctionConfiguration: CorrectionSessionConfiguration?
        if correctionMode.usesRefine {
            let correctorConfiguration = CorrectorConfigurationSnapshot.capture()
            correctionConfiguration = CorrectionSessionConfiguration(
                corrector: CorrectorFactory.shared.make(configuration: correctorConfiguration),
                numberOutputPreference: numberOutputPreference,
                punctuationPreference: punctuationPreference,
                timeoutMs: correctionTimeoutMs,
                userDictionary: userDictionary
            )
        } else {
            correctionConfiguration = nil
        }
        let asrService = fastRoute.map { route in
            ASRFactory.shared.getInstalled(source: route.source)
        } ?? ASRFactory.shared.get(sources: transcriptionSources)
        let audioURL = try await writeAudio(request)
        audioURLToCleanup = audioURL
        let audioDurationMs = ASRAudioSupport.audioDurationMilliseconds(for: audioURL)
        await publishJobStatus(
            jobID: jobID,
            stage: .audioReceived,
            message: "Audio received"
        )

        let appCategory = resolveAppCategory(rawValue: request.appCategory, bundleID: request.bundleID)
        let debugLog = DebugLogStore.begin(
            source: "bridge",
            audioURL: audioURL,
            selectedCorrectionMode: correctionMode,
            languageIDs: languageIDs,
            appName: request.appName,
            bundleID: request.bundleID,
            appCategory: appCategory
        )

        let asrStarted = Date()
        let raw: String
        let asrHypotheses: [String]
        let asrSourceHypotheses: [ASRSourceHypothesis]
        let asrWarning: String?
        let transcriptionLatencyMs: Int
        do {
            await publishJobStatus(
                jobID: jobID,
                stage: .transcribing,
                message: "Transcribing audio"
            )
            let asrProgressHandler: ASRTranscriptionProgressHandler? = {
                guard let jobID else { return nil }
                return { progress in
                    guard progress.isMultiSource else { return }
                    let total = max(0, progress.totalSources)
                    let completed = min(max(0, progress.completedSources), total)
                    await BridgeJobStatusCenter.shared.publish(BridgeJobStatusEvent(
                        jobID: jobID,
                        stage: .transcribing,
                        message: total > 0 ? "Transcribing audio (\(completed)/\(total))" : "Transcribing audio",
                        transcriptionCompletedSources: completed,
                        transcriptionTotalSources: total
                    ))
                }
            }()
            let asrResult = try await asrService.transcribeResult(
                audioFileURL: audioURL,
                languageIDs: languageIDs,
                progress: asrProgressHandler
            )
            raw = asrResult.text
            asrHypotheses = Self.combinedASRHypotheses(
                candidates: asrResult.hypotheses.map(Optional.some)
            )
            asrSourceHypotheses = asrResult.sourceHypotheses
            asrWarning = asrResult.warningText
            transcriptionLatencyMs = elapsedMs(since: asrStarted)
            let combinedAlternateTranscripts = Self.combinedAlternateTranscripts(
                primaryTranscript: raw,
                candidates: asrHypotheses.map(Optional.some)
            )
            DebugLogStore.recordASR(
                debugLog,
                text: raw,
                status: "ok",
                latencyMs: transcriptionLatencyMs,
                asrHypotheses: asrHypotheses,
                alternateTranscripts: combinedAlternateTranscripts,
                modelOutputs: asrResult.modelOutputs
            )
        } catch {
            let publishError = Self.bridgeUploadError(from: error)
            DebugLogStore.recordASR(
                debugLog,
                text: nil,
                status: "error",
                error: publishError.localizedDescription,
                latencyMs: elapsedMs(since: asrStarted),
                asrHypotheses: [],
                alternateTranscripts: []
            )
            await publishJobStatus(
                jobID: jobID,
                stage: .failed,
                message: "Transcription failed",
                error: publishError.localizedDescription
            )
            throw publishError
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await publishJobStatus(
                jobID: jobID,
                stage: .failed,
                message: "Audio produced an empty transcript",
                transcriptionLatencyMs: transcriptionLatencyMs,
                error: BridgeServiceError.emptyTranscript.localizedDescription
            )
            throw BridgeServiceError.emptyTranscript
        }
        let combinedAlternateTranscripts = Self.combinedAlternateTranscripts(
            primaryTranscript: trimmed,
            candidates: asrHypotheses.map(Optional.some)
        )
        await publishJobStatus(
            jobID: jobID,
            stage: .transcriptReady,
            message: "Transcript ready",
            rawTranscript: request.includeRawTranscript == true ? trimmed : nil,
            rawTranscriptLength: trimmed.count,
            transcriptionLatencyMs: transcriptionLatencyMs,
            transcriptionCompletedSources: transcriptionSources.count > 1 ? transcriptionSources.count : nil,
            transcriptionTotalSources: transcriptionSources.count > 1 ? transcriptionSources.count : nil,
            warning: asrWarning
        )
        let contextBefore = request.contextBefore ?? ""
        let contextAfter = request.contextAfter ?? ""
        let editRequest = correctionRequest(
            rawTranscript: trimmed,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: request.appName,
            bundleID: request.bundleID,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            audioDurationMs: audioDurationMs,
            alternateTranscripts: combinedAlternateTranscripts,
            asrHypotheses: asrHypotheses,
            sourceHypotheses: asrSourceHypotheses,
            numberOutputPreference: numberOutputPreference,
            punctuationPreference: punctuationPreference,
            userDictionary: userDictionary
        )

        if !correctionMode.usesRefine {
            let correction = skippedFastCorrectionOutput(rawTranscript: trimmed)
            let correctionLatencyMs = 0
            DebugLogStore.recordCorrection(
                debugLog,
                mode: correctionMode,
                text: correction.result.text,
                status: correction.status,
                error: correction.error,
                latencyMs: correctionLatencyMs,
                request: editRequest,
                debugTrace: correction.debugTrace,
                timeoutMs: correctionTimeoutMs
            )
            let sessionID = UUID().uuidString
            storeSession(BridgeSession(
                id: sessionID,
                rawTranscript: trimmed,
                languageIDs: languageIDs,
                correctionMode: correctionMode,
                appName: request.appName,
                bundleID: request.bundleID,
                appCategory: appCategory,
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                createdAt: Date()
            ))
            let response = BridgeDictateResponse(
                sessionID: sessionID,
                text: correction.result.text,
                correctionMode: correctionMode.rawValue,
                languageIDs: languageIDs,
                latencyMs: elapsedMs(since: start),
                transcriptionLatencyMs: transcriptionLatencyMs,
                correctionLatencyMs: correctionLatencyMs,
                rawTranscript: request.includeRawTranscript == true ? trimmed : nil,
                asrWarning: asrWarning,
                correctionStatus: correction.status,
                correctionError: correction.error
            )
            await publishJobStatus(
                jobID: jobID,
                stage: .resultReady,
                message: Self.resultReadyMessage(correctionStatus: correction.status, okMessage: "Refine complete"),
                rawTranscriptLength: trimmed.count,
                text: correction.result.text,
                latencyMs: response.latencyMs,
                transcriptionLatencyMs: transcriptionLatencyMs,
                refineLatencyMs: correctionLatencyMs,
                warning: asrWarning
            )
            return response
        }

        let correctionStarted = Date()
        let correction = try await Self.withCorrectionFailureFallback {
            guard let correctionConfiguration else {
                throw CorrectorError.unavailable("Correction backend is no longer available")
            }
            await publishJobStatus(
                jobID: jobID,
                stage: .refining,
                message: "Refining transcript",
                rawTranscriptLength: trimmed.count,
                transcriptionLatencyMs: transcriptionLatencyMs
            )
            return try await correct(
                rawTranscript: trimmed,
                languageIDs: languageIDs,
                correctionMode: correctionMode,
                appName: request.appName,
                bundleID: request.bundleID,
                appCategory: appCategory,
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                audioDurationMs: audioDurationMs,
                alternateTranscripts: combinedAlternateTranscripts,
                asrHypotheses: asrHypotheses,
                sourceHypotheses: asrSourceHypotheses,
                configuration: correctionConfiguration
            )
        } fallback: { error in
            fallbackCorrectionOutput(
                rawTranscript: trimmed,
                languageIDs: languageIDs,
                correctionMode: correctionMode,
                punctuationPreference: punctuationPreference,
                error: error
            )
        }
        let correctionLatencyMs = elapsedMs(since: correctionStarted)
        DebugLogStore.recordCorrection(
            debugLog,
            mode: correctionMode,
            text: correction.result.text,
            status: correction.status,
            error: correction.error,
            latencyMs: correctionLatencyMs,
            request: editRequest,
            debugTrace: correction.debugTrace,
            timeoutMs: correctionTimeoutMs
        )

        let sessionID = UUID().uuidString
        storeSession(BridgeSession(
            id: sessionID,
            rawTranscript: trimmed,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: request.appName,
            bundleID: request.bundleID,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            createdAt: Date()
        ))

        let response = BridgeDictateResponse(
            sessionID: sessionID,
            text: correction.result.text,
            correctionMode: correctionMode.rawValue,
            languageIDs: languageIDs,
            latencyMs: elapsedMs(since: start),
            transcriptionLatencyMs: transcriptionLatencyMs,
            correctionLatencyMs: correctionLatencyMs,
            rawTranscript: request.includeRawTranscript == true ? trimmed : nil,
            asrWarning: asrWarning,
            correctionStatus: correction.status,
            correctionError: correction.error
        )
        await publishJobStatus(
            jobID: jobID,
            stage: .resultReady,
            message: Self.resultReadyMessage(correctionStatus: correction.status, okMessage: "Refine complete"),
            rawTranscriptLength: trimmed.count,
            text: correction.result.text,
            latencyMs: response.latencyMs,
            transcriptionLatencyMs: transcriptionLatencyMs,
            refineLatencyMs: correctionLatencyMs,
            warning: asrWarning,
            error: correction.error
        )
        return response
    }

    func refine(_ request: BridgeRefineRequest) async throws -> BridgeRefineResponse {
        pruneExpiredSessions()
        let start = Date()
        let jobID = BridgeClientJobID.normalized(request.clientJobID)
        let session = request.sessionID.flatMap { sessions[$0] }
        let correctionMode = try resolveCorrectionMode(request.correctionMode ?? session?.correctionMode.rawValue)
        try validateCorrectionModeAvailable(correctionMode)
        let providedRawTranscript = request.rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTranscript = session?.rawTranscript ?? providedRawTranscript
        guard let rawTranscript, !rawTranscript.isEmpty else {
            throw BridgeServiceError.missingSession
        }

        let languageIDs = resolveLanguageIDs(
            ids: request.languageIDs ?? session?.languageIDs,
            mode: request.languageMode
        )
        let bundleID = request.bundleID ?? session?.bundleID
        let appName = request.appName ?? session?.appName
        let contextBefore = request.contextBefore ?? session?.contextBefore ?? ""
        let contextAfter = request.contextAfter ?? session?.contextAfter ?? ""
        let appCategory = resolveAppCategory(
            rawValue: request.appCategory,
            bundleID: bundleID,
            defaultCategory: session?.appCategory ?? .unknown
        )
        let numberOutputPreference = AppSettings.numberOutputPreference
        let punctuationPreference = AppSettings.punctuationPreference
        let correctionTimeoutMs = AppSettings.correctionTimeoutMs
        let userDictionary = dictionary.sortedSnapshot()
        let correctionConfiguration: CorrectionSessionConfiguration?
        if correctionMode.usesRefine {
            let correctorConfiguration = CorrectorConfigurationSnapshot.capture()
            correctionConfiguration = CorrectionSessionConfiguration(
                corrector: CorrectorFactory.shared.make(configuration: correctorConfiguration),
                numberOutputPreference: numberOutputPreference,
                punctuationPreference: punctuationPreference,
                timeoutMs: correctionTimeoutMs,
                userDictionary: userDictionary
            )
        } else {
            correctionConfiguration = nil
        }
        let editRequest = correctionRequest(
            rawTranscript: rawTranscript,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: appName,
            bundleID: bundleID,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            numberOutputPreference: numberOutputPreference,
            punctuationPreference: punctuationPreference,
            userDictionary: userDictionary
        )
        let debugLog = DebugLogStore.beginRefine(
            source: "bridge_refine",
            selectedCorrectionMode: correctionMode,
            languageIDs: languageIDs
        )

        if !correctionMode.usesRefine {
            let correction = skippedFastCorrectionOutput(rawTranscript: rawTranscript)
            DebugLogStore.recordCorrection(
                debugLog,
                mode: correctionMode,
                text: correction.result.text,
                status: correction.status,
                error: correction.error,
                latencyMs: 0,
                request: editRequest,
                debugTrace: correction.debugTrace,
                timeoutMs: correctionTimeoutMs
            )
            let sessionID = session?.id ?? UUID().uuidString
            storeSession(BridgeSession(
                id: sessionID,
                rawTranscript: rawTranscript,
                languageIDs: languageIDs,
                correctionMode: correctionMode,
                appName: appName,
                bundleID: bundleID,
                appCategory: appCategory,
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                createdAt: Date()
            ))
            let response = BridgeRefineResponse(
                sessionID: sessionID,
                text: correction.result.text,
                correctionMode: correctionMode.rawValue,
                languageIDs: languageIDs,
                latencyMs: elapsedMs(since: start),
                correctionLatencyMs: 0,
                correctionStatus: correction.status,
                correctionError: correction.error
            )
            await publishJobStatus(
                jobID: jobID,
                stage: .resultReady,
                message: Self.resultReadyMessage(correctionStatus: correction.status, okMessage: "Refine complete"),
                rawTranscriptLength: rawTranscript.count,
                text: correction.result.text,
                latencyMs: response.latencyMs,
                refineLatencyMs: 0,
                error: correction.error
            )
            return response
        }

        let correctionStarted = Date()
        let correction = try await Self.withCorrectionFailureFallback {
            guard let correctionConfiguration else {
                throw CorrectorError.unavailable("Correction backend is no longer available")
            }
            await publishJobStatus(
                jobID: jobID,
                stage: .refining,
                message: "Refining text",
                rawTranscriptLength: rawTranscript.count
            )
            return try await correct(
                rawTranscript: rawTranscript,
                languageIDs: languageIDs,
                correctionMode: correctionMode,
                appName: appName,
                bundleID: bundleID,
                appCategory: appCategory,
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                configuration: correctionConfiguration
            )
        } fallback: { error in
            fallbackCorrectionOutput(
                rawTranscript: rawTranscript,
                languageIDs: languageIDs,
                correctionMode: correctionMode,
                punctuationPreference: punctuationPreference,
                error: error
            )
        }
        let correctionLatencyMs = elapsedMs(since: correctionStarted)
        DebugLogStore.recordCorrection(
            debugLog,
            mode: correctionMode,
            text: correction.result.text,
            status: correction.status,
            error: correction.error,
            latencyMs: correctionLatencyMs,
            request: editRequest,
            debugTrace: correction.debugTrace,
            timeoutMs: correctionTimeoutMs
        )
        let sessionID = session?.id ?? UUID().uuidString
        storeSession(BridgeSession(
            id: sessionID,
            rawTranscript: rawTranscript,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: appName,
            bundleID: bundleID,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            createdAt: Date()
        ))

        let response = BridgeRefineResponse(
            sessionID: sessionID,
            text: correction.result.text,
            correctionMode: correctionMode.rawValue,
            languageIDs: languageIDs,
            latencyMs: elapsedMs(since: start),
            correctionLatencyMs: correctionLatencyMs,
            correctionStatus: correction.status,
            correctionError: correction.error
        )
        await publishJobStatus(
            jobID: jobID,
            stage: .resultReady,
            message: Self.resultReadyMessage(correctionStatus: correction.status, okMessage: "Refine complete"),
            rawTranscriptLength: rawTranscript.count,
            text: correction.result.text,
            latencyMs: response.latencyMs,
            refineLatencyMs: correctionLatencyMs,
            error: correction.error
        )
        return response
    }

    static func refineFailureStatus(for error: Error) -> String {
        isCorrectionTimeout(error) ? "refine_timeout" : "refine_error"
    }

    static func withCorrectionFailureFallback<Value>(
        _ operation: () async throws -> Value,
        fallback: (Error) -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return fallback(error)
        }
    }

    private static func isCorrectionTimeout(_ error: Error) -> Bool {
        if let correctorError = error as? CorrectorError, correctorError == .timeout {
            return true
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("timed out")
    }

    static func resultReadyMessage(correctionStatus: String, okMessage: String) -> String {
        let normalized = correctionStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "ok":
            return okMessage
        case "skipped_fast_mode":
            return "Fast transcript ready"
        case "empty":
            return "No reliable transcript"
        case "refine_timeout":
            return "Without refine: refine timeout"
        case "refine_error":
            return "Without refine: refine error"
        default:
            return "Without refine"
        }
    }

    private func skippedFastCorrectionOutput(rawTranscript: String) -> BridgeCorrectionOutput {
        BridgeCorrectionOutput(
            result: CorrectionResult(action: .commit, text: rawTranscript, risk: .low),
            status: "skipped_fast_mode",
            error: nil,
            debugTrace: nil
        )
    }

    private func fallbackCorrectionOutput(
        rawTranscript: String,
        languageIDs: [String],
        correctionMode: CorrectionMode,
        punctuationPreference: PunctuationOutputPreference,
        error: Error
    ) -> BridgeCorrectionOutput {
        let fallbackResult = normalize(
            CorrectionResult(action: .commit, text: rawTranscript, risk: .medium),
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            punctuationPreference: punctuationPreference
        )
        return BridgeCorrectionOutput(
            result: fallbackResult,
            status: Self.refineFailureStatus(for: error),
            error: error.localizedDescription,
            debugTrace: (error as? CorrectorError)?.correctionDebugTrace
        )
    }

    func editText(_ request: BridgeTextEditRequest) async throws -> BridgeTextEditResponse {
        let start = Date()
        let jobID = BridgeClientJobID.normalized(request.clientJobID)
        let intent = try resolveTextEditIntent(request.intent)
        let contextBefore = request.contextBefore ?? ""
        let targetText = intent == .pinyinToChinese
            ? (request.targetText ?? "")
            : (request.targetText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        let contextAfter = request.contextAfter ?? ""
        let spokenInstruction = request.spokenInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeServiceError.invalidRequest("target_text is required")
        }
        guard intent == .pinyinToChinese || !spokenInstruction.isEmpty else {
            throw BridgeServiceError.invalidRequest("spoken_instruction is required")
        }

        let correctionConfiguration = CorrectionSessionConfiguration.capture(
            userDictionary: dictionary.sortedSnapshot()
        )
        let languageIDs = resolveLanguageIDs(ids: request.languageIDs, mode: request.languageMode)
        let appCategory = resolveAppCategory(rawValue: request.appCategory, bundleID: request.bundleID)
        let debugLog = DebugLogStore.beginTextEdit(
            source: "bridge-edit-text",
            intent: intent,
            languageIDs: languageIDs
        )
        let editRequest = textEditService.makeRequest(
            intent: intent,
            contextBefore: contextBefore,
            targetText: targetText,
            contextAfter: contextAfter,
            spokenInstruction: spokenInstruction,
            languageIDs: languageIDs,
            appName: request.appName,
            bundleID: request.bundleID,
            appCategory: appCategory,
            configuration: correctionConfiguration
        )
        await publishJobStatus(
            jobID: jobID,
            stage: .refining,
            message: intent == .pinyinToChinese ? "Converting pinyin" : "Editing text",
            rawTranscriptLength: targetText.count
        )
        let editStarted = Date()
        let result: TextEditResult
        let editLatencyMs: Int
        do {
            result = try await textEditService.edit(
                editRequest,
                configuration: correctionConfiguration
            )
            editLatencyMs = elapsedMs(since: editStarted)
            DebugLogStore.recordTextEdit(
                debugLog,
                intent: intent,
                text: result.text,
                status: "ok",
                latencyMs: editLatencyMs,
                request: editRequest,
                timeoutMs: correctionConfiguration.timeoutMs
            )
        } catch {
            let latencyMs = elapsedMs(since: editStarted)
            DebugLogStore.recordTextEdit(
                debugLog,
                intent: intent,
                text: nil,
                status: "error",
                error: error.localizedDescription,
                latencyMs: latencyMs,
                request: editRequest,
                timeoutMs: correctionConfiguration.timeoutMs
            )
            await publishJobStatus(
                jobID: jobID,
                stage: .failed,
                message: "Edit failed",
                rawTranscriptLength: targetText.count,
                refineLatencyMs: latencyMs,
                error: error.localizedDescription
            )
            throw error
        }
        let response = BridgeTextEditResponse(
            text: result.text,
            action: result.action.rawValue,
            languageIDs: languageIDs,
            latencyMs: elapsedMs(since: start),
            editLatencyMs: editLatencyMs,
            editStatus: "ok",
            editError: nil
        )
        await publishJobStatus(
            jobID: jobID,
            stage: .resultReady,
            message: "Edit complete",
            rawTranscriptLength: targetText.count,
            text: result.text,
            latencyMs: response.latencyMs,
            refineLatencyMs: editLatencyMs
        )
        return response
    }

    private func correct(
        rawTranscript: String,
        languageIDs: [String],
        correctionMode: CorrectionMode,
        appName: String?,
        bundleID: String?,
        appCategory: AppCategory,
        contextBefore: String = "",
        contextAfter: String = "",
        audioDurationMs: Int? = nil,
        alternateTranscripts: [String] = [],
        asrHypotheses: [String] = [],
        sourceHypotheses: [ASRSourceHypothesis] = [],
        configuration: CorrectionSessionConfiguration
    ) async throws -> BridgeCorrectionOutput {
        let request = correctionRequest(
            rawTranscript: rawTranscript,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: appName,
            bundleID: bundleID,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            audioDurationMs: audioDurationMs,
            alternateTranscripts: alternateTranscripts,
            asrHypotheses: asrHypotheses,
            sourceHypotheses: sourceHypotheses,
            numberOutputPreference: configuration.numberOutputPreference,
            punctuationPreference: configuration.punctuationPreference,
            userDictionary: configuration.userDictionary
        )

        let output = try await configuration.corrector.correct(
            request,
            timeoutMs: configuration.timeoutMs
        )
        var result = output.result
        result = normalize(
            result,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            punctuationPreference: configuration.punctuationPreference
        )
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return BridgeCorrectionOutput(result: result, status: "empty", error: nil, debugTrace: output.debugTrace)
        }
        return BridgeCorrectionOutput(result: result, status: "ok", error: nil, debugTrace: output.debugTrace)
    }

    private func correctionRequest(
        rawTranscript: String,
        languageIDs: [String],
        correctionMode: CorrectionMode,
        appName: String?,
        bundleID: String?,
        appCategory: AppCategory,
        contextBefore: String = "",
        contextAfter: String = "",
        audioDurationMs: Int? = nil,
        alternateTranscripts: [String] = [],
        asrHypotheses: [String] = [],
        sourceHypotheses: [ASRSourceHypothesis] = [],
        numberOutputPreference: NumberOutputPreference,
        punctuationPreference: PunctuationOutputPreference,
        userDictionary: [DictionaryEntry]
    ) -> CorrectionRequest {
        CorrectionRequest(
            correctionMode: correctionMode,
            frontmostAppName: appName,
            frontmostBundleID: bundleID,
            appCategory: appCategory,
            languageIDs: languageIDs,
            rawTranscript: rawTranscript,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            numberOutputPreference: numberOutputPreference,
            punctuationPreference: punctuationPreference,
            userDictionary: userDictionary,
            audioDurationMs: audioDurationMs,
            alternateTranscripts: alternateTranscripts,
            asrHypotheses: asrHypotheses,
            sourceHypotheses: sourceHypotheses
        )
    }

    private static func combinedASRHypotheses(candidates: [String?]) -> [String] {
        CorrectionRequest.normalizedASRHypotheses(candidates: candidates)
    }

    private static func combinedAlternateTranscripts(
        primaryTranscript: String,
        candidates: [String?]
    ) -> [String] {
        CorrectionRequest.normalizedAlternateTranscripts(
            primaryTranscript: primaryTranscript,
            candidates: candidates
        )
    }

    private func normalize(
        _ result: CorrectionResult,
        languageIDs: [String],
        correctionMode: CorrectionMode,
        punctuationPreference: PunctuationOutputPreference
    ) -> CorrectionResult {
        var normalized = result
        normalized.text = LocaleTextNormalizer.normalize(result.text, languageIDs: languageIDs)
        normalized.text = TranscriptPostProcessor.clean(
            normalized.text,
            languageIDs: languageIDs,
            preserveLineBreaks: correctionMode == .structurePlus,
            punctuationPreference: punctuationPreference
        )
        return normalized
    }

    private func writeAudio(_ request: BridgeDictateRequest) async throws -> URL {
        if let audioFileURL = request.audioFileURL {
            let ext = try Self.validatedClientAudioExtension(request.audioExtension)
            let size = (try? FileManager.default.attributesOfItem(atPath: audioFileURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else {
                throw BridgeServiceError.invalidAudio
            }
            guard audioFileURL.pathExtension.lowercased() == ext else {
                throw BridgeServiceError.invalidRequest("Audio file extension does not match audio_extension")
            }
            guard BridgeAudioFormat.isFLACFile(audioFileURL) else {
                throw BridgeServiceError.invalidAudio
            }
            guard BridgeAudioFormat.isWithinUploadDurationLimit(audioFileURL) else {
                throw BridgeServiceError.invalidRequest(
                    "Audio duration must be known and no longer than \(Int(BridgeAudioRecordingContract.maximumDurationSeconds)) seconds"
                )
            }
            return audioFileURL
        }
        guard let data = request.audioData, !data.isEmpty else {
            throw BridgeServiceError.invalidAudio
        }
        let ext = try Self.validatedClientAudioExtension(request.audioExtension)
        guard BridgeAudioFormat.hasFLACMagic(data) else {
            throw BridgeServiceError.invalidAudio
        }
        let url = try await Task.detached(priority: .utility) {
            try AppPaths.ensureDirectories()
            let url = BridgeMultipart.makeAudioFileURL(in: AppPaths.bridgeDir, fileExtension: ext)
            try data.write(to: url, options: .atomic)
            return url
        }.value
        guard BridgeAudioFormat.isFLACFile(url) else {
            try? FileManager.default.removeItem(at: url)
            throw BridgeServiceError.invalidAudio
        }
        guard BridgeAudioFormat.isWithinUploadDurationLimit(url) else {
            try? FileManager.default.removeItem(at: url)
            throw BridgeServiceError.invalidRequest(
                "Audio duration must be known and no longer than \(Int(BridgeAudioRecordingContract.maximumDurationSeconds)) seconds"
            )
        }
        return url
    }

    private static func validatedClientAudioExtension(_ extensionHint: String?) throws -> String {
        guard let extensionHint else {
            throw BridgeServiceError.invalidRequest("Missing audio_extension")
        }
        guard let ext = BridgeAudioFormat.normalizedExtension(extensionHint) else {
            throw BridgeServiceError.invalidRequest("Unsupported audio extension: \(extensionHint)")
        }
        return ext
    }

    private static func bridgeUploadError(from error: Error) -> Error {
        if let asrError = error as? ASRAudioSupportError {
            switch asrError {
            case .audioConversionFailed:
                return BridgeServiceError.invalidAudio
            case .emptyTranscript:
                return BridgeServiceError.emptyTranscript
            case .requestBodyFailed, .invalidResponse, .httpStatus, .timeout, .unsupportedBridgeAudioExtension:
                return error
            }
        }
        return error
    }

    private func resolveCorrectionMode(_ rawMode: String?) throws -> CorrectionMode {
        if let rawMode, !rawMode.isEmpty {
            guard let mode = CorrectionMode(rawValue: rawMode) else {
                throw BridgeServiceError.invalidRequest("Unknown correction mode: \(rawMode)")
            }
            return mode
        }
        return AppSettings.correctionMode
    }

    private func resolveSettingsCorrectionMode(_ rawMode: String?) throws -> CorrectionMode? {
        guard let rawMode, !rawMode.isEmpty else { return nil }
        guard let mode = CorrectionMode(rawValue: rawMode) else {
            throw BridgeServiceError.invalidRequest("Unknown correction mode: \(rawMode)")
        }
        return mode
    }

    private func validateCorrectionModeAvailable(
        _ mode: CorrectionMode,
        sources: [RecognitionSource] = AppSettings.configuredRecognitionSources,
        fastASRSource: RecognitionSource = AppSettings.fastASRSource,
        languageIDs: [String] = AppSettings.asrCanonicalLanguageIDs
    ) throws {
        guard mode == .fast else { return }
        let readiness = FastASRRoute.readinessReport(
            for: fastASRSource,
            languageIDs: languageIDs,
            enabledSources: sources
        )
        guard readiness.ready else {
            throw BridgeServiceError.invalidRequest("Fast mode is unavailable: \(readiness.reason)")
        }
    }

    private func recognitionSources(for correctionMode: CorrectionMode) throws -> [RecognitionSource] {
        if correctionMode == .fast {
            let sources = AppSettings.enabledRecognitionSources
            let languageIDs = ASRLanguageSelection.validatedIDsForTranscription(
                AppSettings.asrCanonicalLanguageIDs,
                sources: sources
            )
            return [try FastASRRoute.resolve(languageIDs: languageIDs).source]
        }
        return AppSettings.enabledRecognitionSources
    }

    private func resolveTextEditIntent(_ rawIntent: String?) throws -> TextEditIntent {
        guard let rawIntent, !rawIntent.isEmpty else { return .repairSelection }
        guard let intent = TextEditIntent(rawValue: rawIntent) else {
            throw BridgeServiceError.invalidRequest("Unknown text edit intent: \(rawIntent)")
        }
        return intent
    }

    static func resolveSettingsLanguageIDs(
        _ rawIDs: [String],
        supportedOptions: [ASRLanguageOption]
    ) throws -> [String] {
        let supportedIDs = Set(supportedOptions.map(\.id))
        var requestedIDs: [String] = []
        var seen = Set<String>()
        for rawID in rawIDs {
            let trimmedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty else {
                throw BridgeServiceError.invalidRequest("Language ID cannot be empty")
            }
            guard rawID == trimmedID, supportedIDs.contains(rawID) else {
                throw BridgeServiceError.invalidRequest("Unsupported language ID: \(rawID)")
            }
            if seen.insert(rawID).inserted {
                requestedIDs.append(rawID)
            }
        }
        guard !requestedIDs.isEmpty else {
            throw BridgeServiceError.invalidRequest("At least one language must be selected")
        }
        let requested = Set(requestedIDs)
        return supportedOptions.map(\.id).filter { requested.contains($0) }
    }

    private func resolveLanguageIDs(
        ids: [String]?,
        mode: String?,
        sources: [RecognitionSource] = AppSettings.enabledRecognitionSources
    ) -> [String] {
        if let ids, !ids.isEmpty {
            return ASRLanguageSelection.validatedIDsForTranscription(ids, sources: sources)
        }
        switch mode?.lowercased() {
        case "zh", "zh-cn", "chinese", "chinese_simplified":
            return ASRLanguageSelection.validatedIDsForTranscription(["zh-CN"], sources: sources)
        case "en", "en-us", "english":
            return ASRLanguageSelection.validatedIDsForTranscription(["en-US"], sources: sources)
        case "mixed", "multi", "multilingual", "zh-en":
            return ASRLanguageSelection.validatedIDsForTranscription(
                ["zh-CN", "en-US"],
                sources: sources
            )
        default:
            return ASRLanguageSelection.validatedIDsForTranscription(
                AppSettings.asrCanonicalLanguageIDs,
                sources: sources
            )
        }
    }

    private func resolveLivePreviewLanguageIDs(ids: [String]?, mode: String?) -> [String] {
        if let ids, !ids.isEmpty {
            return ids
        }
        switch mode?.lowercased() {
        case "zh", "zh-cn", "chinese", "chinese_simplified":
            return ["zh-CN"]
        case "en", "en-us", "english":
            return ["en-US"]
        case "mixed", "multi", "multilingual", "zh-en":
            return ["zh-CN", "en-US"]
        default:
            return AppSettings.asrCanonicalLanguageIDs
        }
    }

    private func resolveRecognitionSources(_ raw: [String]?) throws -> [RecognitionSource]? {
        guard let raw else { return nil }
        var sources: [RecognitionSource] = []
        var seen = Set<RecognitionSource>()
        for item in raw {
            let value = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty else { continue }
            guard let source = RecognitionSource(rawValue: value) else {
                throw BridgeServiceError.invalidRequest("Unknown recognition source: \(item)")
            }
            if seen.insert(source).inserted {
                sources.append(source)
            }
        }
        return AppSettings.normalizedServerRecognitionSources(sources)
    }

    private func resolveFastASRSource(_ raw: String?) throws -> RecognitionSource? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else {
            throw BridgeServiceError.invalidRequest("Fast ASR source cannot be empty")
        }
        guard let source = RecognitionSource(rawValue: value) else {
            throw BridgeServiceError.invalidRequest("Unknown Fast ASR source: \(raw)")
        }
        return source
    }

    static func validateEnabledRecognitionSources(
        _ sources: [RecognitionSource],
        languageIDs: [String]
    ) throws {
        guard !sources.isEmpty else {
            throw BridgeServiceError.invalidRequest("Enable at least one ASR source")
        }
        guard sources.contains(.appleSpeech) else { return }
        guard AppleSpeechLanguageSupport.resolutionState == .resolved else {
            AppleSpeechLanguageSupport.refreshInBackgroundIfNeeded()
            throw BridgeServiceError.invalidRequest(
                "Apple Speech language support is still loading; retry after it finishes"
            )
        }
        let report = AppleSpeechAvailability.report(languageIDs: languageIDs)
        guard report.ready else {
            throw BridgeServiceError.invalidRequest(report.reason)
        }
    }

    private func resolveASRModelID(_ raw: String, source: RecognitionSource) throws -> String {
        guard source.hasModelConfiguration else { return "" }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else {
            throw BridgeServiceError.invalidRequest("ASR model cannot be empty")
        }
        let options = BridgeSettingsPayload.controllableASRModelOptionsByRecognitionSource[source.rawValue] ?? []
        guard options.contains(where: { $0.id == value }) else {
            throw BridgeServiceError.invalidRequest("Unknown ASR model for \(source.displayName): \(raw)")
        }
        return value
    }

    private func resolveCorrectionBackend(_ raw: String) throws -> CorrectionBackendKind {
        guard let backend = CorrectionBackendKind(rawValue: raw),
              BridgeSettingsPayload.controllableCorrectionBackends.contains(backend)
        else {
            throw BridgeServiceError.invalidRequest("Unknown correction backend: \(raw)")
        }
        return backend
    }

    static func validateExternalCorrectionSettingsIfNeeded(
        _ backend: CorrectionBackendKind,
        externalLLMBaseURL: String,
        externalLLMModel: String
    ) throws {
        guard backend.isExternalCompatible else { return }
        let model = externalLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw BridgeServiceError.invalidRequest("External refine model is empty")
        }
        do {
            let apiKind = try ExternalCompatibleCorrectorService.apiKind(for: backend)
            _ = try ExternalCompatibleCorrectorService.completionsEndpoint(
                baseURL: externalLLMBaseURL,
                apiKind: apiKind
            )
        } catch let error as BridgeServiceError {
            throw error
        } catch {
            throw BridgeServiceError.invalidRequest(error.localizedDescription)
        }
    }

    private func settingPath(forKey key: String, fallback: String) -> String {
        let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? fallback : value
    }

    private func settingValue(forKey key: String, fallback: String) -> String {
        let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? fallback : value
    }

    private func startDownloadsForCurrentServerSettings() {
        let sources = AppSettings.configuredRecognitionSources
        if sources.contains(.qwen) {
            let spec = QwenASRModelCatalog.spec(for: AppSettings.asrQwenLlamaModelID)
            startModelDownloadIfMissing(
                path: settingPath(forKey: spec.modelPathKey, fallback: spec.defaultModelPath),
                downloadURLString: settingValue(forKey: spec.modelURLKey, fallback: spec.defaultModelURL),
                label: "\(spec.label) model"
            )
            startModelDownloadIfMissing(
                path: settingPath(forKey: spec.mmprojPathKey, fallback: spec.defaultMMProjPath),
                downloadURLString: settingValue(forKey: spec.mmprojURLKey, fallback: spec.defaultMMProjURL),
                label: "\(spec.label) mmproj"
            )
        }
        if sources.contains(.nvidiaNemotron) {
            let spec = NvidiaNemotronASRModelCatalog.spec(for: AppSettings.asrNvidiaNemotronModelID)
            for file in spec.files {
                startModelDownloadIfMissing(
                    path: settingPath(forKey: file.pathKey, fallback: file.defaultPath),
                    downloadURLString: settingValue(forKey: file.urlKey, fallback: file.defaultURL),
                    label: "NVIDIA Nemotron \(file.label)",
                    expectedBytes: file.expectedBytes
                )
            }
        }
        if let spec = localLlamaModels.first(where: { $0.backendKind == AppSettings.correctionBackend }) {
            startModelDownloadIfMissing(
                path: settingPath(forKey: spec.pathKey, fallback: spec.defaultPath),
                downloadURLString: settingValue(forKey: spec.urlKey, fallback: ""),
                label: spec.label
            )
        }
    }

    private func startModelDownloadIfMissing(
        path: String,
        downloadURLString: String,
        label: String,
        expectedBytes: Int64? = nil
    ) {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        ModelInstallRegistry.markInstalling(path: path, label: label)
        Task {
            defer { ModelInstallRegistry.markFinished(path: path) }
            do {
                try await ModelAutoInstaller.shared.ensureFile(
                    atPath: path,
                    downloadURLString: downloadURLString,
                    label: label,
                    expectedBytes: expectedBytes
                )
            } catch {
                Log.store.error("model download after settings save failed: \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func resolveLivePreviewSource(
        _ raw: String,
        sources: [RecognitionSource],
        correctionMode: CorrectionMode
    ) throws -> VoiceLivePreviewSource {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source = VoiceLivePreviewSource(rawValue: value) else {
            throw BridgeServiceError.invalidRequest("Unknown live preview source: \(raw)")
        }
        guard VoiceLivePreviewSource.options(
            forRecognitionSources: sources,
            correctionMode: correctionMode
        ).contains(source) else {
            throw BridgeServiceError.invalidRequest("Live preview source is not enabled: \(raw)")
        }
        return source
    }

    private func applyLivePreviewSource(_ source: VoiceLivePreviewSource) {
        if source == .off {
            UserDefaults.standard.set(false, forKey: AppSettings.Keys.voiceLivePreview)
            UserDefaults.standard.set(VoiceLivePreviewSource.off.rawValue, forKey: AppSettings.Keys.voiceLivePreviewSource)
        } else {
            UserDefaults.standard.set(true, forKey: AppSettings.Keys.voiceLivePreview)
            UserDefaults.standard.set(source.rawValue, forKey: AppSettings.Keys.voiceLivePreviewSource)
        }
    }

    private func normalizedExternalLLMBaseURL(_ raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return value
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host,
              Self.isLoopbackOrPrivateHost(host)
        else {
            throw BridgeServiceError.invalidRequest("Invalid external LLM base URL: \(raw)")
        }
        return value
    }

    private static func isLoopbackOrPrivateHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "localhost" || lower == "::1" {
            return true
        }
        if lower.contains(":") {
            return lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd")
        }
        var addr = in_addr()
        guard inet_pton(AF_INET, lower, &addr) == 1 else { return false }
        let value = UInt32(bigEndian: addr.s_addr)
        let first = (value >> 24) & 0xff
        let second = (value >> 16) & 0xff
        if first == 10 || first == 127 || (first == 192 && second == 168) {
            return true
        }
        if first == 172 && (16...31).contains(second) {
            return true
        }
        if first == 169 && second == 254 {
            return true
        }
        return false
    }

    private func resolveAppCategory(
        rawValue: String?,
        bundleID: String?,
        defaultCategory: AppCategory = .unknown
    ) -> AppCategory {
        if let rawValue, let category = AppCategory(rawValue: rawValue) {
            return category
        }
        let inferred = AppCategory.from(bundleID: bundleID)
        return inferred == .unknown ? defaultCategory : inferred
    }

    private func pruneExpiredSessions() {
        let cutoff = Date().addingTimeInterval(-Self.sessionTTL)
        sessions = sessions.filter { $0.value.createdAt >= cutoff }
    }

    private func pruneExpiredLivePreviewSessions() {
        pruneCompletedLivePreviews()
        let cutoff = Date().addingTimeInterval(-Self.livePreviewSessionTTL)
        let expiredIDs = livePreviewSessions.values
            .filter { $0.lastActivityAt < cutoff }
            .map(\.id)
        for id in expiredIDs {
            _ = removeLivePreviewSession(id: id)
        }
        guard livePreviewSessions.count > Self.maxLivePreviewSessions else { return }
        let overflow = livePreviewSessions.count - Self.maxLivePreviewSessions
        let overflowIDs = livePreviewSessions.values
            .sorted { $0.lastActivityAt < $1.lastActivityAt }
            .prefix(overflow)
            .map(\.id)
        for id in overflowIDs {
            _ = removeLivePreviewSession(id: id)
        }
    }

    private func pruneCompletedLivePreviews() {
        let cutoff = Date().addingTimeInterval(-Self.completedLivePreviewTTL)
        completedLivePreviews = completedLivePreviews.filter { $0.value.completedAt >= cutoff }
        guard completedLivePreviews.count > Self.maxCompletedLivePreviews else { return }
        let overflow = completedLivePreviews.count - Self.maxCompletedLivePreviews
        let expiredIDs = completedLivePreviews
            .sorted {
                if $0.value.completedAt == $1.value.completedAt {
                    return $0.key < $1.key
                }
                return $0.value.completedAt < $1.value.completedAt
            }
            .prefix(overflow)
            .map(\.key)
        for id in expiredIDs {
            completedLivePreviews.removeValue(forKey: id)
        }
    }

    private func recordLivePreviewTranscript(sessionID: String, text: String) {
        guard let session = livePreviewSessions[sessionID] else { return }
        session.lastTranscript = text
        session.updatedAt = Date()
        Log.bridge.debug(
            "Bridge live preview transcript session=\(Self.logID(sessionID), privacy: .public) text_chars=\(text.count, privacy: .public) elapsed_ms=\(self.elapsedMs(since: session.createdAt), privacy: .public)"
        )
        publishLivePreviewEvent(session: session, text: text, isFinal: false)
    }

    private func removeLivePreviewSession(id: String) -> Task<Void, Never>? {
        guard let session = livePreviewSessions.removeValue(forKey: id) else { return nil }
        let teardownTask = trackLivePreviewTeardown(session.cancelAndTeardown())
        Log.bridge.notice(
            "Bridge live preview removed session=\(Self.logID(id), privacy: .public) text_chars=\(session.lastTranscript?.count ?? 0, privacy: .public) elapsed_ms=\(self.elapsedMs(since: session.createdAt), privacy: .public)"
        )
        publishLivePreviewEvent(session: session, text: session.lastTranscript, isFinal: true)
        return teardownTask
    }

    /// Removing a session from the externally addressable map does not end
    /// Bridge ownership. Keep its teardown task registered until the lease has
    /// actually been returned or replaced, so a later stop can join it.
    private func trackLivePreviewTeardown(
        _ teardownTask: Task<Void, Never>
    ) -> Task<Void, Never> {
        let teardownID = UUID()
        inFlightLivePreviewTeardowns[teardownID] = teardownTask
        Task { @MainActor [weak self] in
            await teardownTask.value
            self?.inFlightLivePreviewTeardowns.removeValue(forKey: teardownID)
        }
        return teardownTask
    }

    private func publishLivePreviewEvent(
        session: BridgeLivePreviewSession,
        text: String?,
        isFinal: Bool
    ) {
        let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = BridgeLivePreviewEvent(
            sessionID: session.id,
            provider: session.provider,
            text: cleaned?.isEmpty == true ? nil : cleaned,
            isFinal: isFinal,
            updatedAt: Date().timeIntervalSince1970
        )
        Task {
            await BridgeLivePreviewEventCenter.shared.publish(event)
        }
    }

    private func storeSession(_ session: BridgeSession) {
        sessions[session.id] = session
        pruneExpiredSessions()
        guard sessions.count > Self.maxSessions else { return }
        let overflow = sessions.count - Self.maxSessions
        let expiredIDs = sessions.values
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(overflow)
            .map(\.id)
        for id in expiredIDs {
            sessions.removeValue(forKey: id)
        }
    }

    private static func logID(_ id: String) -> String {
        String(id.prefix(8))
    }

    private func elapsedMs(since date: Date) -> Int {
        Int((Date().timeIntervalSince(date) * 1000).rounded())
    }

    private func publishJobStatus(
        jobID: String?,
        stage: BridgeJobStatusStage,
        message: String,
        rawTranscript: String? = nil,
        rawTranscriptLength: Int? = nil,
        text: String? = nil,
        latencyMs: Int? = nil,
        transcriptionLatencyMs: Int? = nil,
        transcriptionCompletedSources: Int? = nil,
        transcriptionTotalSources: Int? = nil,
        refineLatencyMs: Int? = nil,
        warning: String? = nil,
        error: String? = nil
    ) async {
        guard let jobID else { return }
        await BridgeJobStatusCenter.shared.publish(BridgeJobStatusEvent(
            jobID: jobID,
            stage: stage,
            message: message,
            rawTranscript: rawTranscript,
            rawTranscriptLength: rawTranscriptLength,
            text: text,
            latencyMs: latencyMs,
            transcriptionLatencyMs: transcriptionLatencyMs,
            transcriptionCompletedSources: transcriptionCompletedSources,
            transcriptionTotalSources: transcriptionTotalSources,
            refineLatencyMs: refineLatencyMs,
            warning: warning,
            error: error
        ))
    }

    private func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }

}
