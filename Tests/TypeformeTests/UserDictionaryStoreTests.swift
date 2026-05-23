import Foundation
import Testing
@testable import Typeforme

@MainActor
@Suite("UserDictionaryStore")
struct UserDictionaryStoreTests {
    @Test func replaceEntriesPreservesTypesAndNormalizesInput() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-user-dictionary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = UserDictionaryStore(url: url)
        let personID = UUID()
        let projectID = UUID()

        store.replaceEntries([
            DictionaryEntry(id: personID, type: "person", surface: " 样例用户 "),
            DictionaryEntry(id: projectID, type: "Project Name", surface: "新 项目"),
            DictionaryEntry(id: UUID(), type: "phrase", surface: " "),
            DictionaryEntry(id: projectID, type: "other", surface: "duplicate id"),
        ])

        #expect(store.entries.count == 2)
        let existing = try #require(store.entries.first { $0.surface == "样例用户" })
        #expect(existing.id == personID)
        #expect(existing.type == "person")

        let added = try #require(store.entries.first { $0.surface == "新 项目" })
        #expect(added.id == projectID)
        #expect(added.type == "project_name")
    }
}
