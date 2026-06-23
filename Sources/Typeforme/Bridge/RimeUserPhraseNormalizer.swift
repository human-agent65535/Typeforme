import CryptoKit
import Foundation

enum RimeUserPhraseNormalizer {
    static func normalized(_ phrases: [String], sortsOutput: Bool = true) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for phrase in phrases {
            let cleaned = phrase
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let key = cleaned.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            guard seen.insert(key).inserted else { continue }
            output.append(cleaned)
        }
        return sortsOutput ? output.sorted() : output
    }

    static func revision(forNormalized phrases: [String]) -> String {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: phrases, options: [.sortedKeys])
        } catch {
            preconditionFailure("Could not encode Rime user phrases revision: \(error)")
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func revision(for phrases: [String]) -> String {
        revision(forNormalized: normalized(phrases))
    }
}
