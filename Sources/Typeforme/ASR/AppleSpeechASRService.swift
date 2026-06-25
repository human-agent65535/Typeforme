import Foundation
@preconcurrency import Speech

struct AppleSpeechASRService: ASRService {
    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        let recognitionURL = try await ASRAudioSupport.wavUploadableAudioURL(for: audioFileURL)
        defer {
            if recognitionURL != audioFileURL {
                try? FileManager.default.removeItem(at: recognitionURL)
            }
        }

        guard let resolved = await AppleSpeechLanguageSupport.bestSupportedLocaleIdentifier(for: languageIDs) else {
            throw ASRAudioSupportError.httpStatus(422, "Apple Speech does not support the selected languages on device")
        }
        let localeID = resolved.localeID

        let status = await AppPermissions.requestSpeechRecognition()
        guard status == .granted else {
            throw ASRAudioSupportError.httpStatus(403, "Apple Speech recognition permission is not authorized")
        }

        let locale = Locale(identifier: localeID)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw ASRAudioSupportError.httpStatus(503, "Apple Speech recognizer is unavailable for \(localeID)")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw ASRAudioSupportError.httpStatus(422, "Apple Speech on-device recognition is unavailable for \(localeID)")
        }

        let request = SFSpeechURLRecognitionRequest(url: recognitionURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        if #available(macOS 13.0, *) {
            request.addsPunctuation = AppSettings.punctuationPreference != .spaces
        }

        let text = try await Self.runRecognition(recognizer: recognizer, request: request)
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ASRAudioSupportError.emptyTranscript }
        return cleaned
    }

    private static func runRecognition(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechURLRecognitionRequest
    ) async throws -> String {
        let taskBox = SpeechRecognitionTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeBox = SpeechRecognitionContinuationBox(continuation)
                taskBox.task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        resumeBox.resume(.failure(error))
                        return
                    }
                    guard let result, result.isFinal else { return }
                    resumeBox.resume(.success(result.bestTranscription.formattedString))
                }
            }
        } onCancel: {
            taskBox.cancel()
        }
    }
}

private final class SpeechRecognitionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _task: SFSpeechRecognitionTask?

    var task: SFSpeechRecognitionTask? {
        get {
            lock.withLock { _task }
        }
        set {
            lock.withLock { _task = newValue }
        }
    }

    func cancel() {
        lock.withLock { _task?.cancel() }
    }
}

private final class SpeechRecognitionContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<String, any Error>

    init(_ continuation: CheckedContinuation<String, any Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<String, any Error>) {
        let shouldResume = lock.withLock { () -> Bool in
            guard !didResume else { return false }
            didResume = true
            return true
        }
        guard shouldResume else { return }
        switch result {
        case .success(let text):
            continuation.resume(returning: text)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
