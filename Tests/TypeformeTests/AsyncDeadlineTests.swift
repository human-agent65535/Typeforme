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
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                    continuation.resume()
                }
            }
        }

        #expect(!completed)
        #expect(Date().timeIntervalSince(started) < 0.25)
    }
}
