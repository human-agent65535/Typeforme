import CryptoKit
import Foundation

enum ModelDownloadIntegrityError: LocalizedError {
    case checksumMismatch(label: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let label, let expected, let actual):
            return "\(label) checksum mismatch. Expected \(expected), got \(actual)."
        }
    }
}

enum ModelDownloadIntegrity {
    private static let readChunkSize = 1024 * 1024

    private static let expectedSHA256ByCanonicalURL: [String: String] = [
        "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/main/Qwen3-ASR-0.6B-Q8_0.gguf": "bca259818b50ca7c4c05e9bdb35a5dc04fa039653a6d6f3f0f331f96f6aa1971",
        "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/main/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf": "41a342b5e4c514e968cb756de6cd1b7be39eff43c44c57a2ef5fc6522e36603d",
        "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/main/Qwen3-ASR-0.6B-bf16.gguf": "12b2894d9a7c98cd8f26670f5a47ab738f42bcc98df21e109be493870c71ba50",
        "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/main/mmproj-Qwen3-ASR-0.6B-bf16.gguf": "dae36c855f9a82a8916bea2238b24bda69a39d8da8b2f46dee7c103775656039",
        "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/main/Qwen3-ASR-1.7B-Q8_0.gguf": "58e22d0532d4eacaf034cfac17a6fed159f37c41390c710186783be439d1fc57",
        "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/main/mmproj-Qwen3-ASR-1.7B-Q8_0.gguf": "46c1d533af3f354ceb37ce855dbceff7da7fa7cf1e6a523df3b13440bd164c0d",
        "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/main/Qwen3-ASR-1.7B-bf16.gguf": "1af18763dfafde2bbf071ef8a0952f7bee66f140c3565e5ccc5afb07dc1f9227",
        "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/main/mmproj-Qwen3-ASR-1.7B-bf16.gguf": "8882e9ddab3186f9aa71b1417c847177913e1466655ac944cf86e9b846735d62",
        "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf": "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
        "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf": "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
        "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf": "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8",
    ]

    static func expectedSHA256(for url: URL) -> String? {
        expectedSHA256ByCanonicalURL[canonicalURLString(url)]
    }

    static func validateFile(at url: URL, expectedSHA256: String, label: String) throws {
        let actual = try sha256Hex(of: url)
        guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw ModelDownloadIntegrityError.checksumMismatch(
                label: label,
                expected: expectedSHA256,
                actual: actual
            )
        }
    }

    static func sha256Hex(of url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }

        var hasher = SHA256()
        while true {
            let chunk = try input.read(upToCount: readChunkSize) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func canonicalURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? url.absoluteString
    }
}
