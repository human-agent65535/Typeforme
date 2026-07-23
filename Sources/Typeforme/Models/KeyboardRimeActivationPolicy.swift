import Foundation

/// Session-local switches that can be changed on a live Rime session. They are
/// deliberately not part of `KeyboardRimeActivationPolicy`: changing input
/// language or punctuation must not make a healthy session unavailable or
/// rebuild its schema and user-data state.
struct KeyboardRimeInputOptions: Equatable, Sendable {
    let asciiMode: Bool
    let asciiPunctuation: Bool
}

/// Pure lifecycle state for applying the latest complete session-replacing
/// Rime configuration (schema, phrases, and reset generation).
/// The controller owns locking and queueing; this value owns only generation,
/// retry, and publication decisions so the concurrency contract is testable
/// without loading librime or relying on timing-based tests.
struct KeyboardRimeActivationPolicy<Configuration: Equatable & Sendable>: Sendable {
    struct Snapshot: Equatable, Sendable {
        let generation: UInt64
        let attempt: UInt64
        let configuration: Configuration
    }

    enum Completion: Equatable, Sendable {
        case continueWith(Snapshot)
        case publish
        case discard
    }

    private(set) var desiredConfiguration: Configuration
    private(set) var desiredGeneration: UInt64 = 0
    private(set) var appliedGeneration: UInt64?
    private(set) var inFlightSnapshot: Snapshot?
    private(set) var failedGeneration: UInt64?
    private(set) var lastCompletedAttempt: UInt64?
    private var nextAttempt: UInt64 = 0
    private var lastAttemptAt: TimeInterval?

    init(initialConfiguration: Configuration) {
        desiredConfiguration = initialConfiguration
    }

    var isReady: Bool {
        inFlightSnapshot == nil
            && appliedGeneration == desiredGeneration
            && failedGeneration != desiredGeneration
    }

    var hasActivationInFlight: Bool {
        inFlightSnapshot != nil
    }

    /// Replaces the complete desired value. Identical observations are a no-op:
    /// per-key option refreshes must not continuously invalidate a ready engine.
    @discardableResult
    mutating func replaceDesiredConfiguration(_ configuration: Configuration) -> Bool {
        guard configuration != desiredConfiguration else { return false }
        desiredConfiguration = configuration
        desiredGeneration &+= 1
        failedGeneration = nil
        return true
    }

    /// Starts one flight when the current generation is not applied. A failed
    /// generation retries only after an explicit caller action and the cooldown;
    /// there is no timer or autonomous retry loop.
    mutating func requestActivation(
        now: TimeInterval,
        retryInterval: TimeInterval
    ) -> Snapshot? {
        guard inFlightSnapshot == nil, !isReady else { return nil }
        if failedGeneration == desiredGeneration,
           let lastAttemptAt,
           now - lastAttemptAt < retryInterval {
            return nil
        }
        return beginAttempt(now: now)
    }

    /// Finishes one immutable snapshot. If configuration changed while the
    /// engine was working, the same flight drains directly to the latest full
    /// snapshot and never publishes the intermediate result.
    mutating func complete(
        _ snapshot: Snapshot,
        succeeded: Bool,
        now: TimeInterval
    ) -> Completion {
        guard inFlightSnapshot?.attempt == snapshot.attempt else {
            return .discard
        }
        if desiredGeneration != snapshot.generation {
            return .continueWith(beginAttempt(now: now))
        }

        inFlightSnapshot = nil
        lastCompletedAttempt = snapshot.attempt
        if succeeded {
            appliedGeneration = snapshot.generation
            failedGeneration = nil
        } else {
            failedGeneration = snapshot.generation
        }
        return .publish
    }

    /// A main-queue callback is current only while both its configuration and
    /// its activation attempt remain the last stable completion. This also
    /// rejects a delayed failure callback after a same-generation retry starts.
    func shouldDeliverPublication(for snapshot: Snapshot) -> Bool {
        desiredGeneration == snapshot.generation
            && inFlightSnapshot == nil
            && lastCompletedAttempt == snapshot.attempt
    }

    private mutating func beginAttempt(now: TimeInterval) -> Snapshot {
        nextAttempt &+= 1
        let snapshot = Snapshot(
            generation: desiredGeneration,
            attempt: nextAttempt,
            configuration: desiredConfiguration
        )
        inFlightSnapshot = snapshot
        lastAttemptAt = now
        return snapshot
    }
}

/// Decides whether a live session may keep its already-resolved fallback
/// profile. Wall-clock fallback policy is intentionally outside this helper and
/// is consulted only when a new session/schema activation is actually needed.
enum KeyboardRimeSessionProfilePolicy {
    static func effectiveProfile<Profile: Equatable>(
        requestedProfile: Profile,
        activeRequestedProfile: Profile?,
        activeEffectiveProfile: Profile?,
        hasSession: Bool,
        requiresSessionReplacement: Bool,
        resolveForNewActivation: () -> Profile
    ) -> Profile {
        if hasSession,
           !requiresSessionReplacement,
           activeRequestedProfile == requestedProfile,
           let activeEffectiveProfile {
            return activeEffectiveProfile
        }
        return resolveForNewActivation()
    }
}

/// Derives destructive work from monotonic facts instead of one-shot reload or
/// reset flags. Reset subsumes phrase replacement because deleting user data
/// also deletes the materialized custom-phrase file.
struct KeyboardRimeSessionMutationPlan: Equatable, Sendable {
    let shouldResetUserData: Bool
    let shouldWriteUserPhrases: Bool
    let requiresSessionReplacement: Bool

    static func make(
        desiredPhraseSignature: String,
        appliedPhraseSignature: String?,
        desiredResetGeneration: Int,
        appliedResetGeneration: Int,
        hasSession: Bool
    ) -> KeyboardRimeSessionMutationPlan {
        let shouldResetUserData = desiredResetGeneration > appliedResetGeneration
        let shouldWriteUserPhrases = shouldResetUserData
            || desiredPhraseSignature != appliedPhraseSignature
        return KeyboardRimeSessionMutationPlan(
            shouldResetUserData: shouldResetUserData,
            shouldWriteUserPhrases: shouldWriteUserPhrases,
            requiresSessionReplacement: !hasSession || shouldWriteUserPhrases
        )
    }
}
