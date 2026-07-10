import Foundation
import Testing
@testable import Typeforme

@Suite("AsyncDeadline")
struct AsyncDeadlineTests {
    @Test func reportsCompletedOperation() async {
        let completed = await AsyncDeadline.run(timeoutNanoseconds: 500_000_000) {}

        #expect(completed)
    }

    @Test func deadlineDoesNotAwaitNonCooperativeOperation() async {
        let started = Date()
        let completed = await AsyncDeadline.run(timeoutNanoseconds: 10_000_000) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                    continuation.resume()
                }
            }
        }

        #expect(!completed)
        // Leave enough scheduler headroom for a loaded parallel test run while
        // still proving that the deadline did not await the 2-second loser.
        #expect(Date().timeIntervalSince(started) < 1.0)
    }
}
