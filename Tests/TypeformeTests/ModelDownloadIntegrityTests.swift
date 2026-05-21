import Foundation
import Testing
@testable import Typeforme

@Suite("ModelDownloadIntegrity")
struct ModelDownloadIntegrityTests {
    @Test func canonicalHuggingFaceURLIgnoresDownloadQuery() throws {
        let url = try #require(URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf?download=true"))
        #expect(ModelDownloadIntegrity.expectedSHA256(for: url) == "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223")
    }

    @Test func validatesSHA256WithoutLoadingWholeFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeforme-integrity-\(UUID().uuidString).txt")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try ModelDownloadIntegrity.validateFile(
            at: url,
            expectedSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            label: "fixture"
        )
        #expect(throws: ModelDownloadIntegrityError.self) {
            try ModelDownloadIntegrity.validateFile(
                at: url,
                expectedSHA256: String(repeating: "0", count: 64),
                label: "fixture"
            )
        }
    }
}
