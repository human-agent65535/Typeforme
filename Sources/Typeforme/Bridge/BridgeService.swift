import Darwin
import Foundation

enum BridgeServiceError: LocalizedError {
    case invalidAudio
    case emptyTranscript
    case missingSession
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .invalidAudio:
            return "Invalid or empty audio payload"
        case .emptyTranscript:
            return "Audio produced an empty transcript"
        case .missingSession:
            return "Restyle session not found or expired"
        case .invalidRequest(let why):
            return "Invalid request: \(why)"
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

private final class BridgeLivePreviewSession {
    let id: String
    let clientJobID: String?
    let provider: String
    let languageIDs: [String]
    let process: NvidiaNemotronLivePreviewSession
    let createdAt: Date
    var updatedAt: Date
    var lastTranscript: String?

    init(
        id: String,
        clientJobID: String?,
        provider: String,
        languageIDs: [String],
        process: NvidiaNemotronLivePreviewSession,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.clientJobID = clientJobID
        self.provider = provider
        self.languageIDs = languageIDs
        self.process = process
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

private struct BridgeCorrectionOutput {
    let result: CorrectionResult
    let status: String
    let error: String?
}

@MainActor
final class BridgeService {
    private let dictionary: UserDictionaryStore
    private let textEditService: TextEditService
    private var sessions: [String: BridgeSession] = [:]
    private var livePreviewSessions: [String: BridgeLivePreviewSession] = [:]
    private var livePreviewPruneTask: Task<Void, Never>?

    private static let sessionTTL: TimeInterval = 15 * 60
    private static let maxSessions = 128
    private static let livePreviewSessionTTL: TimeInterval = 3 * 60
    private static let livePreviewFinishTimeout: TimeInterval = 4
    private static let livePreviewPruneIntervalNanoseconds: UInt64 = 30 * 1_000_000_000
    private static let maxLivePreviewSessions = 8

    init(dictionary: UserDictionaryStore) {
        self.dictionary = dictionary
        self.textEditService = TextEditService(dictionary: dictionary)
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
        NvidiaNemotronWarmPool.shared.preloadForCurrentSettings()
        return BridgeSettingsPayload.current(userDictionary: dictionary.sortedSnapshot())
    }

    func updateSettings(_ request: BridgeSettingsUpdateRequest) async throws -> BridgeSettingsPayload {
        let oldSources = AppSettings.enabledRecognitionSources
        let oldQwenASRModelID = AppSettings.asrQwenLlamaModelID
        let sources = try resolveRecognitionSources(request.enabledRecognitionSources) ?? oldSources
        let requestedLivePreviewSource: VoiceLivePreviewSource?
        if let rawLivePreviewSource = request.livePreviewSource {
            requestedLivePreviewSource = try resolveLivePreviewSource(rawLivePreviewSource, sources: sources)
        } else {
            requestedLivePreviewSource = nil
        }
        let supportedLanguages = ASRLanguageSelection.supportedOptions(for: sources)
        let languageIDs = ASRLanguageSelection.validatedIDs(
            request.languageIDs ?? AppSettings.asrLanguageIDs,
            supportedOptions: supportedLanguages
        )

        if request.enabledRecognitionSources != nil {
            UserDefaults.standard.set(sources.contains(.qwen), forKey: AppSettings.Keys.asrQwenEnabled)
            UserDefaults.standard.set(sources.contains(.nvidiaNemotron), forKey: AppSettings.Keys.asrNvidiaNemotronEnabled)
            UserDefaults.standard.set(sources.contains(.appleSpeech), forKey: AppSettings.Keys.asrAppleSpeechEnabled)
        }

        if let modelIDs = request.asrModelIDsByRecognitionSource {
            for (sourceID, rawModelID) in modelIDs {
                guard let source = RecognitionSource(rawValue: sourceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                    throw BridgeServiceError.invalidRequest("Unknown recognition source: \(sourceID)")
                }
                let modelID = try resolveASRModelID(rawModelID, source: source)
                switch source {
                case .qwen:
                    UserDefaults.standard.set(modelID, forKey: AppSettings.Keys.asrQwenLlamaModelID)
                case .nvidiaNemotron:
                    UserDefaults.standard.set(modelID, forKey: AppSettings.Keys.asrNvidiaNemotronModelID)
                case .appleSpeech:
                    break
                }
            }
        }
        if request.languageIDs != nil || request.enabledRecognitionSources != nil {
            UserDefaults.standard.set(
                ASRLanguageSelection.rawValue(for: languageIDs, supportedOptions: supportedLanguages),
                forKey: AppSettings.Keys.asrLanguageIDs
            )
        }

        if let timeouts = request.asrTimeoutSecByRecognitionSource {
            for (sourceID, timeoutSec) in timeouts {
                guard let source = RecognitionSource(rawValue: sourceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                    throw BridgeServiceError.invalidRequest("Unknown recognition source: \(sourceID)")
                }
                let clamped = BridgeSettingsPayload.clampedASRTimeoutSec(timeoutSec)
                switch source {
                case .qwen:
                    UserDefaults.standard.set(Double(clamped), forKey: AppSettings.Keys.asrQwenLlamaTimeoutSec)
                case .nvidiaNemotron:
                    UserDefaults.standard.set(Double(clamped), forKey: AppSettings.Keys.asrNvidiaNemotronTimeoutSec)
                case .appleSpeech:
                    break
                }
            }
        }

        if let rawBackend = request.correctionBackend {
            let backend = try resolveCorrectionBackend(rawBackend)
            UserDefaults.standard.set(backend.rawValue, forKey: AppSettings.Keys.correctionBackend)
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
        if let rawURL = request.externalLLMBaseURL {
            UserDefaults.standard.set(try normalizedExternalLLMBaseURL(rawURL), forKey: AppSettings.Keys.externalLLMBaseURL)
        }
        if let rawModel = request.externalLLMModel {
            UserDefaults.standard.set(rawModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: AppSettings.Keys.externalLLMModel)
        }
        if let requestedLivePreviewSource {
            applyLivePreviewSource(requestedLivePreviewSource)
        } else if request.enabledRecognitionSources != nil {
            let livePreviewSource = BridgeSettingsPayload.normalizedLivePreviewSource(
                AppSettings.voiceLivePreviewSource,
                sources: sources
            )
            applyLivePreviewSource(livePreviewSource)
        }

        if let rawMode = request.correctionMode {
            guard let mode = CorrectionMode(rawValue: rawMode) else {
                throw BridgeServiceError.invalidRequest("Unknown correction mode: \(rawMode)")
            }
            UserDefaults.standard.set(mode.rawValue, forKey: AppSettings.Keys.correctionMode)
        }
        if let rawPreference = request.numberOutputPreference {
            guard let preference = NumberOutputPreference(rawValue: rawPreference) else {
                throw BridgeServiceError.invalidRequest("Unknown number output preference: \(rawPreference)")
            }
            UserDefaults.standard.set(preference.rawValue, forKey: AppSettings.Keys.numberOutputPreference)
        }
        if let rawPreference = request.punctuationPreference {
            guard let preference = PunctuationOutputPreference(rawValue: rawPreference) else {
                throw BridgeServiceError.invalidRequest("Unknown punctuation preference: \(rawPreference)")
            }
            UserDefaults.standard.set(preference.rawValue, forKey: AppSettings.Keys.punctuationPreference)
        }

        if let autoCommit = request.autoCommit {
            UserDefaults.standard.set(autoCommit, forKey: AppSettings.Keys.correctionAutoCommit)
        }
        if let debugMode = request.debugMode {
            UserDefaults.standard.set(debugMode, forKey: AppSettings.Keys.diagnosticsDebugMode)
        }
        if let userDictionary = request.userDictionary {
            dictionary.replaceEntries(userDictionary)
        }

        UserDefaults.standard.synchronize()
        let newSources = AppSettings.enabledRecognitionSources
        let newQwenASRModelID = AppSettings.asrQwenLlamaModelID
        Task { @MainActor in
            if (oldSources.contains(.qwen) && !newSources.contains(.qwen))
                || oldQwenASRModelID != newQwenASRModelID {
                await ASRFactory.shared.stopQwenLlama()
            }
            async let asrPreload: Void = ASRFactory.shared.preloadCachedActiveModel()
            async let correctionPreload: CorrectorPreloadResult = CorrectorFactory.shared.preloadActiveModels()
            _ = await (asrPreload, correctionPreload)
        }
        return BridgeSettingsPayload.current(userDictionary: dictionary.sortedSnapshot())
    }

    func startLivePreview(_ request: BridgeLivePreviewStartRequest) async throws -> BridgeLivePreviewStartResponse {
        pruneExpiredLivePreviewSessions()
        guard AppSettings.enabledRecognitionSources.contains(.nvidiaNemotron) else {
            throw BridgeServiceError.invalidRequest("NVIDIA Nemotron ASR is not enabled")
        }
        guard livePreviewSessions.count < Self.maxLivePreviewSessions else {
            throw BridgeServiceError.invalidRequest("Too many active live preview sessions")
        }

        let id = UUID().uuidString
        let requestedLanguageIDs = resolveLivePreviewLanguageIDs(ids: request.languageIDs, mode: request.languageMode)
        let languageIDs = ASRLanguageSelection.effectiveIDs(requestedLanguageIDs, for: .nvidiaNemotron)
        guard !languageIDs.isEmpty else {
            throw BridgeServiceError.invalidRequest(
                "NVIDIA Nemotron ASR does not support the selected live preview languages"
            )
        }
        Log.bridge.notice(
            "Bridge live preview start session=\(Self.logID(id), privacy: .public) languages=\(languageIDs.joined(separator: ","), privacy: .public)"
        )
        LivePreviewFileTrace.record(
            "mac_bridge_start",
            sessionID: id,
            fields: ["languages": languageIDs.joined(separator: ",")]
        )
        let process = try NvidiaNemotronWarmPool.shared.takeOrStart(languageIDs: languageIDs, diagnosticID: id) { [weak self] text in
            Task { @MainActor [weak self] in
                self?.recordLivePreviewTranscript(sessionID: id, text: text)
            }
        }
        let createdAt = Date()
        livePreviewSessions[id] = BridgeLivePreviewSession(
            id: id,
            clientJobID: BridgeClientJobID.normalized(request.clientJobID),
            provider: "nvidia-nemotron-asr",
            languageIDs: languageIDs,
            process: process,
            createdAt: createdAt
        )
        Log.bridge.notice(
            "Bridge live preview started session=\(Self.logID(id), privacy: .public) elapsed_ms=\(self.elapsedMs(since: createdAt), privacy: .public)"
        )
        LivePreviewFileTrace.record(
            "mac_bridge_started",
            sessionID: id,
            fields: ["elapsed_ms": self.elapsedMs(since: createdAt)]
        )
        return BridgeLivePreviewStartResponse(
            sessionID: id,
            provider: "nvidia-nemotron-asr",
            languageIDs: languageIDs,
            startedAt: createdAt.timeIntervalSince1970
        )
    }

    func livePreviewAudioProcess(sessionID: String) throws -> NvidiaNemotronLivePreviewSession {
        pruneExpiredLivePreviewSessions()
        guard let session = livePreviewSessions[sessionID] else {
            throw BridgeServiceError.missingSession
        }
        session.updatedAt = Date()
        return session.process
    }

    func touchLivePreviewSession(sessionID: String) {
        livePreviewSessions[sessionID]?.updatedAt = Date()
    }

    func finishLivePreview(sessionID: String) async throws -> BridgeLivePreviewFinishResponse {
        pruneExpiredLivePreviewSessions()
        guard let session = livePreviewSessions[sessionID] else {
            throw BridgeServiceError.missingSession
        }
        session.updatedAt = Date()
        Log.bridge.notice(
            "Bridge live preview finish session=\(Self.logID(sessionID), privacy: .public) elapsed_ms=\(self.elapsedMs(since: session.createdAt), privacy: .public)"
        )
        LivePreviewFileTrace.record(
            "mac_bridge_finish",
            sessionID: sessionID,
            fields: ["elapsed_ms": self.elapsedMs(since: session.createdAt)]
        )
        let completed = await session.process.finishInputAndWaitForFinal(
            timeout: Self.livePreviewFinishTimeout
        )
        if !completed {
            session.process.terminate(reason: "bridge_finish_timeout")
        }
        let transcript = session.process.currentTranscript() ?? session.lastTranscript
        publishLivePreviewEvent(session: session, text: transcript, isFinal: true)
        livePreviewSessions.removeValue(forKey: sessionID)
        if completed {
            NvidiaNemotronWarmPool.shared.returnIdle(
                session.process,
                languageIDs: session.languageIDs,
                reason: "bridge_finished"
            )
        } else {
            NvidiaNemotronWarmPool.shared.preload(languageIDs: session.languageIDs)
        }
        let finishedAt = Date()
        Log.bridge.notice(
            "Bridge live preview finished session=\(Self.logID(sessionID), privacy: .public) completed=\(completed, privacy: .public) text_chars=\(transcript?.count ?? 0, privacy: .public) elapsed_ms=\(self.elapsedMs(since: session.createdAt), privacy: .public)"
        )
        LivePreviewFileTrace.record(
            "mac_bridge_finished",
            sessionID: sessionID,
            fields: [
                "completed": completed,
                "elapsed_ms": self.elapsedMs(since: session.createdAt),
                "text_chars": transcript?.count ?? 0,
            ]
        )
        return BridgeLivePreviewFinishResponse(
            sessionID: session.id,
            text: transcript,
            finishedAt: finishedAt.timeIntervalSince1970
        )
    }

    func cancelLivePreview(sessionID: String) {
        pruneExpiredLivePreviewSessions()
        removeLivePreviewSession(id: sessionID)
    }

    func dictate(_ request: BridgeDictateRequest) async throws -> BridgeDictateResponse {
        pruneExpiredSessions()
        let start = Date()
        let jobID = BridgeClientJobID.normalized(request.clientJobID)
        let languageIDs = resolveLanguageIDs(ids: request.languageIDs, mode: request.languageMode)
        let correctionMode = try resolveCorrectionMode(request.correctionMode)
        let audioURL = try await writeAudio(request)
        defer { try? FileManager.default.removeItem(at: audioURL) }
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
        let asrAlternateTranscripts: [String]
        let asrHypotheses: [String]
        let asrWarning: String?
        let transcriptionLatencyMs: Int
        do {
            await publishJobStatus(
                jobID: jobID,
                stage: .transcribing,
                message: "Transcribing audio"
            )
            let asrResult = try await ASRFactory.shared.get().transcribeResult(audioFileURL: audioURL, languageIDs: languageIDs)
            raw = asrResult.text
            asrAlternateTranscripts = asrResult.alternateTranscripts
            asrHypotheses = Self.combinedASRHypotheses(
                candidates: asrResult.hypotheses.map(Optional.some) + [request.alternateTranscript]
            )
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
            DebugLogStore.recordASR(
                debugLog,
                text: nil,
                status: "error",
                error: error.localizedDescription,
                latencyMs: elapsedMs(since: asrStarted),
                asrHypotheses: request.alternateTranscript.map { [$0] } ?? [],
                alternateTranscripts: request.alternateTranscript.map { [$0] } ?? []
            )
            await publishJobStatus(
                jobID: jobID,
                stage: .failed,
                message: "Transcription failed",
                error: error.localizedDescription
            )
            throw error
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
            alternateTranscripts: combinedAlternateTranscripts,
            asrHypotheses: asrHypotheses
        )

        let correctionStarted = Date()
        let correction: BridgeCorrectionOutput
        let correctionLatencyMs: Int
        do {
            await publishJobStatus(
                jobID: jobID,
                stage: .refining,
                message: "Refining transcript",
                rawTranscriptLength: trimmed.count,
                transcriptionLatencyMs: transcriptionLatencyMs
            )
            correction = try await correct(
                rawTranscript: trimmed,
                languageIDs: languageIDs,
                correctionMode: correctionMode,
                appName: request.appName,
                bundleID: request.bundleID,
                appCategory: appCategory,
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                alternateTranscripts: combinedAlternateTranscripts,
                asrHypotheses: asrHypotheses
            )
            correctionLatencyMs = elapsedMs(since: correctionStarted)
        } catch {
            let latencyMs = elapsedMs(since: correctionStarted)
            guard Self.canFallbackToRawTranscript(error) else {
                DebugLogStore.recordCorrection(
                    debugLog,
                    mode: correctionMode,
                    text: nil,
                    status: "error",
                    error: error.localizedDescription,
                    latencyMs: latencyMs,
                    request: editRequest,
                    timeoutMs: AppSettings.correctionTimeoutMs
                )
                await publishJobStatus(
                    jobID: jobID,
                    stage: .failed,
                    message: "Refine failed",
                    rawTranscriptLength: trimmed.count,
                    transcriptionLatencyMs: transcriptionLatencyMs,
                    refineLatencyMs: latencyMs,
                    error: error.localizedDescription
                )
                throw error
            }
            correction = fallbackCorrectionOutput(
                rawTranscript: trimmed,
                languageIDs: languageIDs,
                correctionMode: correctionMode,
                error: error
            )
            correctionLatencyMs = latencyMs
        }
        DebugLogStore.recordCorrection(
            debugLog,
            mode: correctionMode,
            text: correction.result.text,
            status: correction.status,
            error: correction.error,
            latencyMs: correctionLatencyMs,
            request: editRequest,
            timeoutMs: AppSettings.correctionTimeoutMs
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

    func restyle(_ request: BridgeRestyleRequest) async throws -> BridgeRestyleResponse {
        pruneExpiredSessions()
        let start = Date()
        let jobID = BridgeClientJobID.normalized(request.clientJobID)
        let session = request.sessionID.flatMap { sessions[$0] }
        let correctionMode = try resolveCorrectionMode(request.correctionMode ?? session?.correctionMode.rawValue)
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

        let correctionStarted = Date()
        let correction: BridgeCorrectionOutput
        let correctionLatencyMs: Int
        do {
            await publishJobStatus(
                jobID: jobID,
                stage: .refining,
                message: "Refining text",
                rawTranscriptLength: rawTranscript.count
            )
            correction = try await correct(
                rawTranscript: rawTranscript,
                languageIDs: languageIDs,
                correctionMode: correctionMode,
                appName: appName,
                bundleID: bundleID,
                appCategory: appCategory,
                contextBefore: contextBefore,
                contextAfter: contextAfter
            )
            correctionLatencyMs = elapsedMs(since: correctionStarted)
        } catch {
            let latencyMs = elapsedMs(since: correctionStarted)
            guard Self.canFallbackToRawTranscript(error) else {
                await publishJobStatus(
                    jobID: jobID,
                    stage: .failed,
                    message: "Refine failed",
                    rawTranscriptLength: rawTranscript.count,
                    refineLatencyMs: latencyMs,
                    error: error.localizedDescription
                )
                throw error
            }
            correction = fallbackCorrectionOutput(
                rawTranscript: rawTranscript,
                languageIDs: languageIDs,
                correctionMode: correctionMode,
                error: error
            )
            correctionLatencyMs = latencyMs
        }
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

        let response = BridgeRestyleResponse(
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

    private static func isCorrectionTimeout(_ error: Error) -> Bool {
        if let correctorError = error as? CorrectorError, correctorError == .timeout {
            return true
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("timed out")
    }

    /// `.timeout`, `.unavailable`, `.requestFailed`, `.validationFailed` are
    /// all "ASR succeeded but correction backend let us down" — fall back to
    /// the raw transcript instead of dropping the dictation. `.empty` stays
    /// throw-only because there's nothing to fall back to.
    private static func canFallbackToRawTranscript(_ error: Error) -> Bool {
        if let correctorError = error as? CorrectorError {
            switch correctorError {
            case .timeout, .unavailable, .requestFailed, .validationFailed:
                return true
            case .empty:
                return false
            }
        }
        // Network errors that escaped CorrectorError translation.
        let message = error.localizedDescription.lowercased()
        return message.contains("offline")
            || message.contains("timed out")
            || message.contains("unreach")
            || message.contains("connection")
    }

    private static func fallbackCorrectionStatus(_ error: Error) -> String {
        if let correctorError = error as? CorrectorError, correctorError == .timeout {
            return "timeout"
        }
        return "fallback"
    }

    static func resultReadyMessage(correctionStatus: String, okMessage: String) -> String {
        let normalized = correctionStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "ok" ? okMessage : "Without refine"
    }

    private func fallbackCorrectionOutput(
        rawTranscript: String,
        languageIDs: [String],
        correctionMode: CorrectionMode,
        error: Error
    ) -> BridgeCorrectionOutput {
        // Correction backend failed after ASR succeeded. Keep dictation usable
        // by returning normalized raw text instead of dropping the audio result.
        let fallbackResult = normalize(
            CorrectionResult(action: .commit, text: rawTranscript, risk: .medium),
            languageIDs: languageIDs,
            correctionMode: correctionMode
        )
        return BridgeCorrectionOutput(
            result: fallbackResult,
            status: Self.fallbackCorrectionStatus(error),
            error: error.localizedDescription
        )
    }

    func editText(_ request: BridgeTextEditRequest) async throws -> BridgeTextEditResponse {
        let start = Date()
        let jobID = BridgeClientJobID.normalized(request.clientJobID)
        let intent = try resolveTextEditIntent(request.intent)
        let contextBefore = request.contextBefore ?? ""
        let targetText = request.targetText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let contextAfter = request.contextAfter ?? ""
        let spokenInstruction = request.spokenInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !targetText.isEmpty else {
            throw BridgeServiceError.invalidRequest("target_text is required")
        }
        guard !spokenInstruction.isEmpty else {
            throw BridgeServiceError.invalidRequest("spoken_instruction is required")
        }

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
            appCategory: appCategory
        )
        await publishJobStatus(
            jobID: jobID,
            stage: .refining,
            message: "Editing text",
            rawTranscriptLength: targetText.count
        )
        let editStarted = Date()
        let result: TextEditResult
        let editLatencyMs: Int
        do {
            result = try await textEditService.edit(editRequest)
            editLatencyMs = elapsedMs(since: editStarted)
            DebugLogStore.recordTextEdit(
                debugLog,
                intent: intent,
                text: result.text,
                status: "ok",
                latencyMs: editLatencyMs,
                request: editRequest,
                timeoutMs: AppSettings.correctionTimeoutMs
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
                timeoutMs: AppSettings.correctionTimeoutMs
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
        alternateTranscripts: [String] = [],
        asrHypotheses: [String] = []
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
            alternateTranscripts: alternateTranscripts,
            asrHypotheses: asrHypotheses
        )

        var result = try await CorrectorFactory.shared.make().correct(
            request,
            timeoutMs: AppSettings.correctionTimeoutMs
        )
        result = normalize(result, languageIDs: languageIDs, correctionMode: correctionMode)
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CorrectorError.empty
        }
        return BridgeCorrectionOutput(result: result, status: "ok", error: nil)
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
        alternateTranscripts: [String] = [],
        asrHypotheses: [String] = []
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
            numberOutputPreference: AppSettings.numberOutputPreference,
            punctuationPreference: AppSettings.punctuationPreference,
            userDictionary: dictionary.sortedSnapshot(),
            alternateTranscripts: alternateTranscripts,
            asrHypotheses: asrHypotheses
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
        correctionMode: CorrectionMode
    ) -> CorrectionResult {
        var normalized = result
        normalized.text = LocaleTextNormalizer.normalize(result.text, languageIDs: languageIDs)
        normalized.text = TranscriptPostProcessor.clean(
            normalized.text,
            languageIDs: languageIDs,
            preserveLineBreaks: correctionMode == .structurePlus,
            numberPreference: AppSettings.numberOutputPreference,
            punctuationPreference: AppSettings.punctuationPreference
        )
        return normalized
    }

    private func writeAudio(_ request: BridgeDictateRequest) async throws -> URL {
        if let audioFileURL = request.audioFileURL {
            _ = try Self.validatedClientAudioExtension(request.audioExtension)
            let size = (try? FileManager.default.attributesOfItem(atPath: audioFileURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else {
                throw BridgeServiceError.invalidAudio
            }
            return audioFileURL
        }
        guard let data = request.audioData, !data.isEmpty else {
            throw BridgeServiceError.invalidAudio
        }
        let ext = try Self.validatedClientAudioExtension(request.audioExtension)
        return try await Task.detached(priority: .utility) {
            try AppPaths.ensureDirectories()
            let url = AppPaths.bridgeDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }

    private static func validatedClientAudioExtension(_ extensionHint: String?) throws -> String {
        let defaultExtension = "m4a"
        guard let extensionHint else { return defaultExtension }
        let allowed = extensionHint
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        guard !allowed.isEmpty, allowed.count <= 8 else {
            throw BridgeServiceError.invalidRequest("Unsupported audio extension")
        }
        guard ["m4a", "aac"].contains(allowed) else {
            throw BridgeServiceError.invalidRequest("Unsupported audio extension: \(allowed)")
        }
        return allowed
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

    private func resolveTextEditIntent(_ rawIntent: String?) throws -> TextEditIntent {
        guard let rawIntent, !rawIntent.isEmpty else { return .repairSelection }
        guard let intent = TextEditIntent(rawValue: rawIntent) else {
            throw BridgeServiceError.invalidRequest("Unknown text edit intent: \(rawIntent)")
        }
        return intent
    }

    private func resolveLanguageIDs(ids: [String]?, mode: String?) -> [String] {
        let supportedOptions = ASRLanguageSelection.supportedOptions(for: AppSettings.enabledRecognitionSources)
        if let ids, !ids.isEmpty {
            return ASRLanguageSelection.validatedIDs(ids, supportedOptions: supportedOptions)
        }
        switch mode?.lowercased() {
        case "zh", "zh-cn", "chinese", "chinese_simplified":
            return ASRLanguageSelection.validatedIDs(["zh-CN"], supportedOptions: supportedOptions)
        case "en", "en-us", "english":
            return ASRLanguageSelection.validatedIDs(["en-US"], supportedOptions: supportedOptions)
        case "mixed", "multi", "multilingual", "zh-en":
            return ASRLanguageSelection.validatedIDs(["zh-CN", "en-US"], supportedOptions: supportedOptions)
        default:
            return ASRLanguageSelection.validatedIDs(AppSettings.asrLanguageIDs, supportedOptions: supportedOptions)
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
            return AppSettings.asrLanguageIDs
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
        guard !sources.isEmpty else {
            throw BridgeServiceError.invalidRequest("At least one recognition source must be enabled")
        }
        return sources
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

    private func resolveLivePreviewSource(
        _ raw: String,
        sources: [RecognitionSource]
    ) throws -> VoiceLivePreviewSource {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source = VoiceLivePreviewSource(rawValue: value) else {
            throw BridgeServiceError.invalidRequest("Unknown live preview source: \(raw)")
        }
        guard VoiceLivePreviewSource.options(forRecognitionSources: sources).contains(source) else {
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
        let cutoff = Date().addingTimeInterval(-Self.livePreviewSessionTTL)
        let expiredIDs = livePreviewSessions.values
            .filter { $0.updatedAt < cutoff }
            .map(\.id)
        for id in expiredIDs {
            removeLivePreviewSession(id: id)
        }
        guard livePreviewSessions.count > Self.maxLivePreviewSessions else { return }
        let overflow = livePreviewSessions.count - Self.maxLivePreviewSessions
        let overflowIDs = livePreviewSessions.values
            .sorted { $0.updatedAt < $1.updatedAt }
            .prefix(overflow)
            .map(\.id)
        for id in overflowIDs {
            removeLivePreviewSession(id: id)
        }
    }

    private func recordLivePreviewTranscript(sessionID: String, text: String) {
        guard let session = livePreviewSessions[sessionID] else { return }
        session.lastTranscript = text
        session.updatedAt = Date()
        Log.bridge.notice(
            "Bridge live preview transcript session=\(Self.logID(sessionID), privacy: .public) text_chars=\(text.count, privacy: .public) elapsed_ms=\(self.elapsedMs(since: session.createdAt), privacy: .public)"
        )
        LivePreviewFileTrace.record(
            "mac_bridge_transcript",
            sessionID: sessionID,
            fields: [
                "elapsed_ms": self.elapsedMs(since: session.createdAt),
                "text_chars": text.count,
            ]
        )
        publishLivePreviewEvent(session: session, text: text, isFinal: false)
    }

    private func removeLivePreviewSession(id: String) {
        guard let session = livePreviewSessions.removeValue(forKey: id) else { return }
        Task { @MainActor in
            let reset = await session.process.cancelInputAndWaitForReset(timeout: 2)
            if reset {
                NvidiaNemotronWarmPool.shared.returnIdle(
                    session.process,
                    languageIDs: session.languageIDs,
                    reason: "bridge_cancelled"
                )
            } else {
                session.process.terminate(reason: "bridge_cancel_timeout")
                NvidiaNemotronWarmPool.shared.preload(languageIDs: session.languageIDs)
            }
        }
        Log.bridge.notice(
            "Bridge live preview removed session=\(Self.logID(id), privacy: .public) text_chars=\(session.lastTranscript?.count ?? 0, privacy: .public) elapsed_ms=\(self.elapsedMs(since: session.createdAt), privacy: .public)"
        )
        LivePreviewFileTrace.record(
            "mac_bridge_removed",
            sessionID: id,
            fields: [
                "elapsed_ms": self.elapsedMs(since: session.createdAt),
                "text_chars": session.lastTranscript?.count ?? 0,
            ]
        )
        publishLivePreviewEvent(session: session, text: session.lastTranscript, isFinal: true)
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
