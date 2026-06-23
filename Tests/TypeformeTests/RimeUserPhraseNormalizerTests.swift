import Testing
@testable import Typeforme

@Suite("RimeUserPhraseNormalizer")
struct RimeUserPhraseNormalizerTests {
    @Test func normalizesSortedRimeUserPhrases() {
        let phrases = RimeUserPhraseNormalizer.normalized([
            "  Typeforme  ",
            "Hello   World",
            "hello world",
            "",
            "Ｔｙｐｅｆｏｒｍｅ",
        ])

        #expect(phrases == ["Hello World", "Typeforme"])
    }

    @Test func canPreserveInputOrderForDictionaryGeneration() {
        let phrases = RimeUserPhraseNormalizer.normalized(
            ["Bravo", " alpha ", "bravo", "Charlie"],
            sortsOutput: false
        )

        #expect(phrases == ["Bravo", "alpha", "Charlie"])
    }

    @Test func revisionUsesNormalizedPhrasePayload() {
        let normalized = RimeUserPhraseNormalizer.normalized([" hello  world "])

        #expect(
            RimeUserPhraseNormalizer.revision(for: ["hello world"]) ==
                RimeUserPhraseNormalizer.revision(forNormalized: normalized)
        )
    }
}
