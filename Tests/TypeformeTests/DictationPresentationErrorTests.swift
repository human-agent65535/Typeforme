import Foundation
import Testing
@testable import Typeforme

@Suite("Dictation presentation errors")
struct DictationPresentationErrorTests {
    @Test @MainActor func recoveryActionComesFromTheReporter() {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-presentation-error-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let coordinator = DictationCoordinator(
            dictionary: UserDictionaryStore(url: dictionaryURL)
        )

        coordinator.reportError("Accessibility backend unavailable", recovery: .dismiss)
        #expect(coordinator.presentationError?.recovery == .dismiss)

        coordinator.reportError("Temporary failure", recovery: .openSettings)
        #expect(coordinator.lastError == "Temporary failure")
        #expect(coordinator.presentationError?.recovery == .openSettings)

        coordinator.reset()
        #expect(coordinator.presentationError == nil)
        #expect(coordinator.lastError == nil)
        coordinator.prepareForApplicationShutdown()
    }
}
