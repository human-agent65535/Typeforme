import XCTest
@testable import Typeforme

final class KeyboardRimeActivationPolicyTests: XCTestCase {
    private struct Configuration: Equatable, Sendable {
        let profile: String
        let phraseSignature: String
        let resetGeneration: Int
    }

    private let initial = Configuration(
        profile: "standard",
        phraseSignature: "a",
        resetGeneration: 0
    )

    func testIdenticalConfigurationDoesNotInvalidateReadyGeneration() throws {
        var policy = KeyboardRimeActivationPolicy(initialConfiguration: initial)
        let first = try XCTUnwrap(policy.requestActivation(now: 0, retryInterval: 2))
        XCTAssertEqual(policy.complete(first, succeeded: true, now: 0), .publish)
        XCTAssertTrue(policy.isReady)

        XCTAssertFalse(policy.replaceDesiredConfiguration(initial))
        XCTAssertNil(policy.requestActivation(now: 1, retryInterval: 2))
        XCTAssertTrue(policy.isReady)
    }

    func testSuspensionInvalidationRequiresFreshActivationForSameConfiguration() throws {
        var policy = KeyboardRimeActivationPolicy(initialConfiguration: initial)
        let first = try XCTUnwrap(policy.requestActivation(now: 0, retryInterval: 2))
        XCTAssertEqual(policy.complete(first, succeeded: true, now: 0), .publish)
        XCTAssertTrue(policy.isReady)
        XCTAssertTrue(policy.shouldDeliverPublication(for: first))

        policy.invalidateAppliedConfiguration()

        XCTAssertFalse(policy.isReady)
        XCTAssertFalse(policy.shouldDeliverPublication(for: first))
        let resumed = try XCTUnwrap(policy.requestActivation(now: 1, retryInterval: 2))
        XCTAssertEqual(resumed.configuration, initial)
        XCTAssertEqual(policy.complete(resumed, succeeded: true, now: 1), .publish)
        XCTAssertTrue(policy.isReady)
    }

    func testSuspensionInvalidationDiscardsAnOutstandingActivation() throws {
        var policy = KeyboardRimeActivationPolicy(initialConfiguration: initial)
        let interrupted = try XCTUnwrap(policy.requestActivation(now: 0, retryInterval: 2))

        policy.invalidateAppliedConfiguration()

        XCTAssertFalse(policy.hasActivationInFlight)
        XCTAssertEqual(
            policy.complete(interrupted, succeeded: true, now: 0.5),
            .discard
        )
        XCTAssertNotNil(policy.requestActivation(now: 0.5, retryInterval: 2))
    }

    func testOneFlightDrainsDirectlyToLatestCompleteSnapshot() throws {
        var policy = KeyboardRimeActivationPolicy(initialConfiguration: initial)
        let first = try XCTUnwrap(policy.requestActivation(now: 0, retryInterval: 2))
        let second = Configuration(
            profile: "extended",
            phraseSignature: "b",
            resetGeneration: 1
        )
        let latest = Configuration(
            profile: "large",
            phraseSignature: "c",
            resetGeneration: 2
        )

        XCTAssertTrue(policy.replaceDesiredConfiguration(second))
        XCTAssertTrue(policy.replaceDesiredConfiguration(latest))
        XCTAssertNil(policy.requestActivation(now: 0.5, retryInterval: 2))

        guard case .continueWith(let drained) = policy.complete(
            first,
            succeeded: true,
            now: 1
        ) else {
            return XCTFail("intermediate generation must drain instead of publish")
        }
        XCTAssertEqual(drained.configuration, latest)
        XCTAssertEqual(drained.generation, policy.desiredGeneration)
        XCTAssertTrue(policy.hasActivationInFlight)

        XCTAssertEqual(policy.complete(drained, succeeded: true, now: 1), .publish)
        XCTAssertTrue(policy.isReady)
        XCTAssertTrue(policy.shouldDeliverPublication(for: drained))
        XCTAssertFalse(policy.shouldDeliverPublication(for: first))
    }

    func testStaleFailureCannotPublishOverNewerGeneration() throws {
        var policy = KeyboardRimeActivationPolicy(initialConfiguration: initial)
        let first = try XCTUnwrap(policy.requestActivation(now: 0, retryInterval: 2))
        let latest = Configuration(
            profile: "large",
            phraseSignature: "latest",
            resetGeneration: 0
        )
        XCTAssertTrue(policy.replaceDesiredConfiguration(latest))

        guard case .continueWith(let drained) = policy.complete(
            first,
            succeeded: false,
            now: 0.5
        ) else {
            return XCTFail("stale failure must continue to the latest generation")
        }
        XCTAssertFalse(policy.shouldDeliverPublication(for: first))
        XCTAssertEqual(policy.complete(drained, succeeded: true, now: 1), .publish)
        XCTAssertTrue(policy.isReady)
    }

    func testSameGenerationRetryInvalidatesDelayedFailureCallback() throws {
        var policy = KeyboardRimeActivationPolicy(initialConfiguration: initial)
        let failed = try XCTUnwrap(policy.requestActivation(now: 0, retryInterval: 2))
        XCTAssertEqual(policy.complete(failed, succeeded: false, now: 0), .publish)
        XCTAssertTrue(policy.shouldDeliverPublication(for: failed))
        XCTAssertNil(policy.requestActivation(now: 1, retryInterval: 2))

        let retry = try XCTUnwrap(policy.requestActivation(now: 2, retryInterval: 2))
        XCTAssertFalse(policy.shouldDeliverPublication(for: failed))
        XCTAssertNotEqual(retry.attempt, failed.attempt)
        XCTAssertEqual(policy.complete(retry, succeeded: true, now: 2), .publish)
        XCTAssertTrue(policy.shouldDeliverPublication(for: retry))
    }

    func testDuplicateCompletionIsDiscardedAfterFlightMovesOn() throws {
        var policy = KeyboardRimeActivationPolicy(initialConfiguration: initial)
        let first = try XCTUnwrap(policy.requestActivation(now: 0, retryInterval: 2))
        XCTAssertTrue(policy.replaceDesiredConfiguration(Configuration(
            profile: "extended",
            phraseSignature: "b",
            resetGeneration: 0
        )))
        guard case .continueWith = policy.complete(first, succeeded: true, now: 1) else {
            return XCTFail("new configuration must continue the existing flight")
        }
        XCTAssertEqual(policy.complete(first, succeeded: true, now: 1), .discard)
    }

    func testLiveOptionsDoNotInvalidateAppliedActivation() throws {
        var policy = KeyboardRimeActivationPolicy(initialConfiguration: initial)
        let first = try XCTUnwrap(policy.requestActivation(now: 0, retryInterval: 2))
        XCTAssertEqual(policy.complete(first, succeeded: true, now: 0), .publish)

        var options = KeyboardRimeInputOptions(
            asciiMode: false,
            asciiPunctuation: false
        )
        options = KeyboardRimeInputOptions(
            asciiMode: true,
            asciiPunctuation: true
        )

        XCTAssertEqual(options, KeyboardRimeInputOptions(
            asciiMode: true,
            asciiPunctuation: true
        ))
        XCTAssertTrue(policy.isReady)
        XCTAssertNil(policy.requestActivation(now: 1, retryInterval: 2))
    }

    func testPinnedFallbackSurvivesLiveSessionMutation() {
        var resolverCalls = 0
        let effective = KeyboardRimeSessionProfilePolicy.effectiveProfile(
            requestedProfile: "large",
            activeRequestedProfile: "large",
            activeEffectiveProfile: "standard",
            hasSession: true,
            requiresSessionReplacement: false
        ) {
            resolverCalls += 1
            return "large"
        }

        XCTAssertEqual(effective, "standard")
        XCTAssertEqual(resolverCalls, 0)
    }

    func testSessionReplacementReevaluatesFallback() {
        var resolverCalls = 0
        let effective = KeyboardRimeSessionProfilePolicy.effectiveProfile(
            requestedProfile: "large",
            activeRequestedProfile: "large",
            activeEffectiveProfile: "standard",
            hasSession: true,
            requiresSessionReplacement: true
        ) {
            resolverCalls += 1
            return "large"
        }

        XCTAssertEqual(effective, "large")
        XCTAssertEqual(resolverCalls, 1)
    }

    func testResetAndPhraseChangeCollapseIntoOneSessionReplacement() {
        let plan = KeyboardRimeSessionMutationPlan.make(
            desiredPhraseSignature: "new",
            appliedPhraseSignature: "old",
            desiredResetGeneration: 3,
            appliedResetGeneration: 2,
            hasSession: true
        )

        XCTAssertEqual(
            plan,
            KeyboardRimeSessionMutationPlan(
                shouldResetUserData: true,
                shouldWriteUserPhrases: true,
                requiresSessionReplacement: true
            )
        )
    }

    func testPhraseOnlyChangeReplacesSessionWithoutResettingUserData() {
        let plan = KeyboardRimeSessionMutationPlan.make(
            desiredPhraseSignature: "new",
            appliedPhraseSignature: "old",
            desiredResetGeneration: 2,
            appliedResetGeneration: 2,
            hasSession: true
        )

        XCTAssertFalse(plan.shouldResetUserData)
        XCTAssertTrue(plan.shouldWriteUserPhrases)
        XCTAssertTrue(plan.requiresSessionReplacement)
    }

    func testResetIsAcknowledgedByAppliedGenerationRatherThanRepeatedFlag() {
        let first = KeyboardRimeSessionMutationPlan.make(
            desiredPhraseSignature: "same",
            appliedPhraseSignature: "same",
            desiredResetGeneration: 4,
            appliedResetGeneration: 3,
            hasSession: true
        )
        let afterSuccess = KeyboardRimeSessionMutationPlan.make(
            desiredPhraseSignature: "same",
            appliedPhraseSignature: "same",
            desiredResetGeneration: 4,
            appliedResetGeneration: 4,
            hasSession: true
        )

        XCTAssertTrue(first.shouldResetUserData)
        XCTAssertFalse(afterSuccess.shouldResetUserData)
        XCTAssertFalse(afterSuccess.requiresSessionReplacement)
    }
}
