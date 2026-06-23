import Foundation

/// A speech vocabulary term. Unlike text-expansion dictionaries, these entries
/// are candidates for the correction model, not unconditional replacements.
struct DictionaryEntry: Codable, Hashable, Sendable, Identifiable {
    static let suggestedTypes = [
        "person",
        "organization",
        "product",
        "project",
        "place",
        "technical_term",
        "acronym",
        "phrase",
        "other",
    ]

    var id: UUID
    var type: String
    var surface: String

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case surface
    }

    init(
        id: UUID = UUID(),
        type: String = "other",
        surface: String
    ) {
        self.id = id
        self.type = DictionaryEntry.normalizedType(type)
        self.surface = DictionaryEntry.cleanedSurface(surface)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            type: try container.decode(String.self, forKey: .type),
            surface: try container.decode(String.self, forKey: .surface)
        )
    }

    var isValid: Bool {
        !surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayType: String {
        Self.displayType(for: type)
    }

    var searchTerms: [String] {
        DictionaryEntry.cleanedList([surface])
    }

    static func cleanedSurface(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedType(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "other" }
        return trimmed
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }

    static func displayType(for type: String) -> String {
        type.replacingOccurrences(of: "_", with: " ")
    }

    static func cleanedList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            let trimmed = cleanedSurface(value)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            output.append(trimmed)
        }
        return output
    }

    static func normalizedEntries(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        var seenIDs = Set<UUID>()
        return entries.compactMap { incoming in
            let entry = DictionaryEntry(
                id: incoming.id,
                type: incoming.type,
                surface: incoming.surface
            )
            guard entry.isValid else { return nil }
            guard seenIDs.insert(entry.id).inserted else { return nil }
            return entry
        }
        .sorted {
            if $0.type != $1.type { return $0.type < $1.type }
            if $0.surface != $1.surface { return $0.surface < $1.surface }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
