import Testing
@testable import Typeforme

@Suite("TextCommitCancellationPolicy")
struct TextCommitCancellationPolicyTests {
    @Test func cancellationAtIrreversibleBoundaryAbortsCommit() {
        #expect(TextCommitCancellationPolicy.shouldAbort(
            taskIsCancelled: true,
            tokenIsCancelled: false
        ))
        #expect(TextCommitCancellationPolicy.shouldAbort(
            taskIsCancelled: false,
            tokenIsCancelled: true
        ))
        #expect(!TextCommitCancellationPolicy.shouldAbort(
            taskIsCancelled: false,
            tokenIsCancelled: false
        ))
    }

    @Test func tokenCancellationAndCommitBoundaryHaveOneWinner() async {
        let cancelled = CommitCancellationToken()
        #expect(await cancelled.cancel())
        #expect(!(await cancelled.beginCommit(taskIsCancelled: false)))

        let committed = CommitCancellationToken()
        #expect(await committed.beginCommit(taskIsCancelled: false))
        #expect(!(await committed.cancel()))

        let taskCancelled = CommitCancellationToken()
        #expect(!(await taskCancelled.beginCommit(taskIsCancelled: true)))
    }

    @Test @MainActor func eventSequencePreparesEverythingBeforeCancellationAndPosting() async throws {
        var trace: [String] = []

        try await TextCommitEventSequence.run(
            chunks: ["first", "second"],
            prepare: { chunk in
                trace.append("prepare:\(chunk)")
                return chunk
            },
            checkCancellation: {
                trace.append("check")
            },
            post: { chunk in
                trace.append("post:\(chunk)")
            }
        )

        #expect(trace == ["prepare:first", "prepare:second", "check", "post:first", "post:second"])
    }

    @Test @MainActor func eventSequencePreparationFailurePostsNothing() async {
        var posted: [String] = []

        await #expect(throws: SequenceError.self) {
            try await TextCommitEventSequence.run(
                chunks: ["first", "second"],
                prepare: { chunk in
                    if chunk == "second" {
                        throw SequenceError.preparation
                    }
                    return chunk
                },
                checkCancellation: {},
                post: { chunk in
                    posted.append(chunk)
                }
            )
        }

        #expect(posted.isEmpty)
    }

    @Test @MainActor func eventSequenceCancellationAfterPreparationPostsNothing() async {
        var prepared: [String] = []
        var posted: [String] = []

        await #expect(throws: SequenceError.self) {
            try await TextCommitEventSequence.run(
                chunks: ["first", "second"],
                prepare: { chunk in
                    prepared.append(chunk)
                    return chunk
                },
                checkCancellation: {
                    throw SequenceError.cancellation
                },
                post: { chunk in
                    posted.append(chunk)
                }
            )
        }

        #expect(prepared == ["first", "second"])
        #expect(posted.isEmpty)
    }
}

private enum SequenceError: Error {
    case preparation
    case cancellation
}
