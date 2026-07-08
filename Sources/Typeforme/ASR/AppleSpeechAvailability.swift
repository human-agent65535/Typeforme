import Foundation
import os.lock
@preconcurrency import Speech

struct AppleSpeechAvailabilityReport: Sendable, Equatable {
    let canEnable: Bool
    let ready: Bool
    let status: String
    let reason: String
    let localeID: String?
}

enum AppleSpeechAvailability {
    private struct RuntimeState: Sendable {
        var dictationDisabledReason: String?
    }

    private static let runtimeState = OSAllocatedUnfairLock(initialState: RuntimeState())

    static func report(languageIDs: [String]) -> AppleSpeechAvailabilityReport {
        switch AppPermissions.speechRecognitionStatus {
        case .granted:
            break
        case .notDetermined:
            return AppleSpeechAvailabilityReport(
                canEnable: true,
                ready: false,
                status: "needs_permission",
                reason: "Grant Speech Recognition permission before enabling Apple Speech.",
                localeID: nil
            )
        case .denied:
            return AppleSpeechAvailabilityReport(
                canEnable: false,
                ready: false,
                status: "permission_denied",
                reason: "Speech Recognition permission is denied.",
                localeID: nil
            )
        case .restricted:
            return AppleSpeechAvailabilityReport(
                canEnable: false,
                ready: false,
                status: "permission_restricted",
                reason: "Speech Recognition permission is restricted.",
                localeID: nil
            )
        case .unknown:
            return AppleSpeechAvailabilityReport(
                canEnable: false,
                ready: false,
                status: "permission_unknown",
                reason: "Speech Recognition permission status is unknown.",
                localeID: nil
            )
        }

        if let reason = runtimeState.withLock({ $0.dictationDisabledReason }) {
            return AppleSpeechAvailabilityReport(
                canEnable: false,
                ready: false,
                status: "dictation_disabled",
                reason: reason,
                localeID: nil
            )
        }

        guard let resolved = AppleSpeechLanguageSupport.bestSupportedLocaleIdentifierSync(for: languageIDs) else {
            return AppleSpeechAvailabilityReport(
                canEnable: false,
                ready: false,
                status: "unsupported_language",
                reason: "Apple Speech does not support the selected languages on device.",
                localeID: nil
            )
        }

        let locale = Locale(identifier: resolved.localeID)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return AppleSpeechAvailabilityReport(
                canEnable: false,
                ready: false,
                status: "recognizer_missing",
                reason: "Apple Speech recognizer is unavailable for \(resolved.localeID).",
                localeID: resolved.localeID
            )
        }
        guard recognizer.isAvailable else {
            return AppleSpeechAvailabilityReport(
                canEnable: false,
                ready: false,
                status: "recognizer_unavailable",
                reason: "Apple Speech recognizer is unavailable for \(resolved.localeID).",
                localeID: resolved.localeID
            )
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return AppleSpeechAvailabilityReport(
                canEnable: false,
                ready: false,
                status: "on_device_unavailable",
                reason: "Apple Speech on-device recognition is unavailable for \(resolved.localeID).",
                localeID: resolved.localeID
            )
        }

        return AppleSpeechAvailabilityReport(
            canEnable: true,
            ready: true,
            status: "ready",
            reason: "Apple Speech is ready.",
            localeID: resolved.localeID
        )
    }

    static func sourceAvailability(languageIDs: [String]) -> BridgeSourceAvailability {
        let report = report(languageIDs: languageIDs)
        return BridgeSourceAvailability(
            canEnable: report.canEnable,
            ready: report.ready,
            status: report.status,
            reason: report.reason
        )
    }

    static func recordRecognitionSuccess() {
        runtimeState.withLock { state in
            state.dictationDisabledReason = nil
        }
    }

    static func recordRecognitionError(_ error: Error) -> ASRAudioSupportError? {
        guard isDictationDisabledError(error) else { return nil }
        let reason = "Siri and Dictation are disabled. Enable Dictation in System Settings before using Apple Speech."
        runtimeState.withLock { state in
            state.dictationDisabledReason = reason
        }
        return ASRAudioSupportError.httpStatus(503, reason)
    }

    static func clearRuntimeDisabledState() {
        runtimeState.withLock { state in
            state.dictationDisabledReason = nil
        }
    }

    static func isDictationDisabledError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "kLSRErrorDomain", nsError.code == 201,
           hasDictationDisabledMessage(nsError) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           isDictationDisabledError(underlying) {
            return true
        }
        return false
    }

    private static func hasDictationDisabledMessage(_ error: NSError) -> Bool {
        let message = error.localizedDescription.lowercased()
        if message.contains("siri and dictation are disabled") {
            return true
        }
        let userInfoMessages = [
            error.localizedFailureReason,
            error.localizedRecoverySuggestion,
            error.userInfo[NSDebugDescriptionErrorKey] as? String,
        ]
        if userInfoMessages.contains(where: { $0?.lowercased().contains("siri and dictation are disabled") == true }) {
            return true
        }
        return false
    }
}
