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
            DictionaryEntry(id: projectID, type: "Project Name", surface: "新\t\t项目\nName"),
            DictionaryEntry(id: UUID(), type: "phrase", surface: " "),
            DictionaryEntry(id: projectID, type: "other", surface: "duplicate id"),
        ])

        #expect(store.entries.count == 2)
        let existing = try #require(store.entries.first { $0.surface == "样例用户" })
        #expect(existing.id == personID)
        #expect(existing.type == "person")

        let added = try #require(store.entries.first { $0.surface == "新 项目 Name" })
        #expect(added.id == projectID)
        #expect(added.type == "project_name")
    }

    @Test func dictionaryEntryDecodesMissingFieldsAndCleansSurface() throws {
        let data = try #require(#"""
        {
          "surface": "  Alpha\t\tBeta\nGamma  "
        }
        """#.data(using: .utf8))

        let entry = try BridgeJSON.decode(DictionaryEntry.self, from: data)

        #expect(entry.type == "other")
        #expect(entry.surface == "Alpha Beta Gamma")
    }

    @Test func normalizedEntriesDropsInvalidAndDuplicateIDsThenSorts() {
        let phraseAID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let personID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let phraseBID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        let normalized = DictionaryEntry.normalizedEntries([
            DictionaryEntry(id: phraseBID, type: "Phrase", surface: "  Two\tWords "),
            DictionaryEntry(id: personID, type: "person", surface: " Alice "),
            DictionaryEntry(id: UUID(), type: "phrase", surface: " \n "),
            DictionaryEntry(id: phraseBID, type: "other", surface: "duplicate id"),
            DictionaryEntry(id: phraseAID, type: "Phrase", surface: " Alpha\nBeta "),
        ])

        #expect(normalized.map(\.id) == [personID, phraseAID, phraseBID])
        #expect(normalized.map(\.type) == ["person", "phrase", "phrase"])
        #expect(normalized.map(\.surface) == ["Alice", "Alpha Beta", "Two Words"])
    }
}
