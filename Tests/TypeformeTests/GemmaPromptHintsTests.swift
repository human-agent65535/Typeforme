import Foundation
import Testing
@testable import Typeforme

@Suite("GemmaPromptHints")
struct GemmaPromptHintsTests {
    @Test func gemma4GetsNoThinkAssistantPrefill() {
        #expect(GemmaPromptHints.prefersNoThink(model: "google/gemma-4-31b-qat"))
        #expect(GemmaPromptHints.prefersNoThink(model: "gemma4-31b"))
        #expect(!GemmaPromptHints.prefersNoThink(model: "google/gemma-3-27b-it"))

        let messages = GemmaPromptHints.openAIChatMessages(
            system: "system",
            user: "user",
            model: "google/gemma-4-31b-qat"
        )

        #expect(messages.count == 3)
        #expect(messages[0]["role"] == "system")
        #expect(messages[1]["role"] == "user")
        #expect(messages[2]["role"] == "assistant")
        #expect(messages[2]["content"] == GemmaPromptHints.noThinkAssistantPrefill)
    }
}
