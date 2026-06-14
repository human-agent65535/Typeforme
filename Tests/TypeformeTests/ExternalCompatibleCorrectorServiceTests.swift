import Foundation
import Testing
@testable import Typeforme

@Suite("ExternalCompatibleCorrectorService")
struct ExternalCompatibleCorrectorServiceTests {
    @Test func buildsOpenAIChatCompletionsEndpointFromRootOrV1Base() throws {
        #expect(try ExternalCompatibleCorrectorService.completionsEndpoint(baseURL: "http://localhost:1234", apiKind: .openAI).absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(try ExternalCompatibleCorrectorService.completionsEndpoint(baseURL: "http://localhost:1234/v1", apiKind: .openAI).absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(try ExternalCompatibleCorrectorService.completionsEndpoint(baseURL: "http://localhost:1234/v1/chat/completions", apiKind: .openAI).absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(try ExternalCompatibleCorrectorService.completionsEndpoint(baseURL: "http://localhost:1234/v1/models", apiKind: .openAI).absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(try ExternalCompatibleCorrectorService.completionsEndpoint(baseURL: "http://192.0.2.10:1234/v1", apiKind: .openAI).absoluteString == "http://192.0.2.10:1234/v1/chat/completions")
        #expect(try ExternalCompatibleCorrectorService.completionsEndpoint(baseURL: "https://openai.example.com/v1", apiKind: .openAI).absoluteString == "https://openai.example.com/v1/chat/completions")
    }

    @Test func buildsAnthropicMessagesEndpointFromRootOrV1Base() throws {
        #expect(try ExternalCompatibleCorrectorService.completionsEndpoint(baseURL: "http://localhost:1234", apiKind: .anthropic).absoluteString == "http://localhost:1234/v1/messages")
        #expect(try ExternalCompatibleCorrectorService.completionsEndpoint(baseURL: "http://localhost:1234/v1", apiKind: .anthropic).absoluteString == "http://localhost:1234/v1/messages")
        #expect(try ExternalCompatibleCorrectorService.completionsEndpoint(baseURL: "http://localhost:1234/v1/messages", apiKind: .anthropic).absoluteString == "http://localhost:1234/v1/messages")
        #expect(try ExternalCompatibleCorrectorService.completionsEndpoint(baseURL: "http://localhost:1234/v1/models", apiKind: .anthropic).absoluteString == "http://localhost:1234/v1/messages")
        #expect(try ExternalCompatibleCorrectorService.completionsEndpoint(baseURL: "https://anthropic.example.com/v1", apiKind: .anthropic).absoluteString == "https://anthropic.example.com/v1/messages")
    }

    @Test func buildsModelsEndpointFromCompletionEndpoint() throws {
        #expect(try ExternalCompatibleCorrectorService.modelsEndpoint(baseURL: "http://localhost:1234", apiKind: .openAI).absoluteString == "http://localhost:1234/v1/models")
        #expect(try ExternalCompatibleCorrectorService.modelsEndpoint(baseURL: "http://localhost:1234/v1/chat/completions", apiKind: .openAI).absoluteString == "http://localhost:1234/v1/models")
        #expect(try ExternalCompatibleCorrectorService.modelsEndpoint(baseURL: "http://localhost:1234/v1/messages", apiKind: .anthropic).absoluteString == "http://localhost:1234/v1/models")
        #expect(try ExternalCompatibleCorrectorService.modelsEndpoint(baseURL: "https://anthropic.example.com", apiKind: .anthropic).absoluteString == "https://anthropic.example.com/v1/models")
    }

    @Test func rejectsNonHTTPBaseURL() {
        #expect(throws: (any Error).self) {
            _ = try ExternalCompatibleCorrectorService.completionsEndpoint(baseURL: "file:///tmp/external", apiKind: .openAI)
        }
    }

    @Test func mapsBackendsToAPIKinds() throws {
        #expect(try ExternalCompatibleCorrectorService.apiKind(for: .externalOpenAICompatible) == .openAI)
        #expect(try ExternalCompatibleCorrectorService.apiKind(for: .externalAnthropicCompatible) == .anthropic)
        #expect(throws: (any Error).self) {
            _ = try ExternalCompatibleCorrectorService.apiKind(for: .qwen35_2B)
        }
    }

    @Test func parsesModelIDsFromModelsResponse() throws {
        let data = #"{"data":[{"id":"qwen/qwen3-35b-a3b"},{"id":"  "},{"id":"claude-sonnet-4-5"}]}"#
            .data(using: .utf8)!
        #expect(ExternalCompatibleCorrectorService.modelIDs(data: data, apiKind: .openAI) == [
            "qwen/qwen3-35b-a3b",
            "claude-sonnet-4-5",
        ])
        #expect(ExternalCompatibleCorrectorService.modelIDs(data: data, apiKind: .anthropic) == [
            "qwen/qwen3-35b-a3b",
            "claude-sonnet-4-5",
        ])
    }

    @Test func parsesAnthropicMessagesTextBlocks() throws {
        let data = #"{"content":[{"type":"text","text":"{\"action\":\"replace\","},{"type":"text","text":"\"text\":\"fixed\",\"risk\":\"low\"}"}]}"#
            .data(using: .utf8)!
        #expect(try AnthropicCompatibleClient.messageContent(from: data) == #"{"action":"replace","text":"fixed","risk":"low"}"#)
    }

    @Test func encodesAnthropicCompatibleSnakeCaseKeys() throws {
        let body = AnthropicMessagesRequest(
            model: "claude-sonnet-4-5",
            maxTokens: 128,
            system: "system",
            messages: [AnthropicMessage(role: "user", content: "user")]
        )
        let data = try JSONEncoder().encode(body)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["model"] as? String == "claude-sonnet-4-5")
        #expect(object["max_tokens"] as? Int == 128)
        #expect(object["system"] as? String == "system")
        #expect(object["thinking"] == nil)
        #expect(object["output_config"] == nil)
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["content"] as? String == "user")
    }

    @Test func enforcesExternalMinimumTimeout() {
        #expect(ExternalCompatibleCorrectorService.effectiveTimeoutMs(50) == ExternalCompatibleCorrectorService.minimumRequestTimeoutMs)
        #expect(ExternalCompatibleCorrectorService.effectiveTimeoutMs(1500) == 1500)
        #expect(ExternalCompatibleCorrectorService.effectiveTimeoutMs(45_000) == 45_000)
    }

    @Test func selectsFirstAvailableModelWhenCurrentDisappears() {
        #expect(ExternalCompatibleCorrectorService.modelSelectionAfterRefresh(
            current: "qwen3.5-old",
            available: ["qwen3.6-27b", "qwen3.5-9b"],
            selectFirstModel: false
        ) == "qwen3.6-27b")
    }

    @Test func preservesAvailableModelAfterRefresh() {
        #expect(ExternalCompatibleCorrectorService.modelSelectionAfterRefresh(
            current: " qwen3.5-9b ",
            available: ["qwen3.6-27b", "qwen3.5-9b"],
            selectFirstModel: false
        ) == "qwen3.5-9b")
    }

    @Test func onlySelectsFirstForEmptyModelWhenRequested() {
        #expect(ExternalCompatibleCorrectorService.modelSelectionAfterRefresh(
            current: "",
            available: ["qwen3.6-27b"],
            selectFirstModel: false
        ) == "")
        #expect(ExternalCompatibleCorrectorService.modelSelectionAfterRefresh(
            current: "",
            available: ["qwen3.6-27b"],
            selectFirstModel: true
        ) == "qwen3.6-27b")
    }

    @Test func reportsNoListedModelsAsUnavailable() {
        let report = ExternalCompatibleCorrectorService.availabilityReport(
            modelIDs: [],
            selectedModel: "qwen3.6-27b",
            apiKind: .openAI
        )
        #expect(report.ok == false)
        #expect(report.status == "Failed")
        #expect(report.detail.contains("no models are listed"))
    }

    @Test func reportsMissingSelectedModelAsReadyForRefreshFallback() {
        let report = ExternalCompatibleCorrectorService.availabilityReport(
            modelIDs: ["qwen3.6-35b"],
            selectedModel: "qwen3.6-27b",
            apiKind: .openAI
        )
        #expect(report.ok)
        #expect(report.status == "Ready")
        #expect(report.detail.contains("Selected model qwen3.6-27b is not listed"))
        #expect(report.detail.contains("Using qwen3.6-35b"))
    }

    @Test func reportsListedSelectedModelAsReady() {
        let report = ExternalCompatibleCorrectorService.availabilityReport(
            modelIDs: ["claude-sonnet-4-5"],
            selectedModel: "claude-sonnet-4-5",
            apiKind: .anthropic
        )
        #expect(report.ok)
        #expect(report.status == "Ready")
    }

    @Test func verifiesProvidedAPIKeyByRejectingInvalidProbe() async {
        let recorder = APIKeyRecorder()
        let report = await ExternalCompatibleCorrectorService.checkConfiguration(
            apiKind: .anthropic,
            baseURL: "http://localhost:1234/v1",
            apiKey: "real-token",
            selectedModel: "claude-sonnet-4-5"
        ) { apiKind, _, apiKey, _ in
            await recorder.record(apiKind: apiKind, apiKey: apiKey)
            if apiKey == "real-token" {
                return ["claude-sonnet-4-5"]
            }
            if apiKey?.hasPrefix("typeforme-invalid-external-llm-token-") == true {
                throw OpenAICompatibleClientError.httpStatus(401, "")
            }
            return []
        }

        let calls = await recorder.snapshot()
        #expect(report.ok)
        #expect(report.detail.contains("API key verified."))
        #expect(calls.count == 2)
        #expect(calls.first?.apiKind == .anthropic)
        #expect(calls.first?.apiKey == "real-token")
        #expect(calls.last?.apiKey?.hasPrefix("typeforme-invalid-external-llm-token-") == true)
    }

    @Test func reportsAPIKeyUnverifiedWhenInvalidProbeIsAccepted() async {
        let report = await ExternalCompatibleCorrectorService.checkConfiguration(
            apiKind: .openAI,
            baseURL: "http://localhost:1234/v1",
            apiKey: "real-token",
            selectedModel: "qwen3.6-27b"
        ) { _, _, _, _ in
            ["qwen3.6-27b"]
        }

        #expect(report.ok == false)
        #expect(report.status == "Failed")
        #expect(report.detail.contains("accepted a deliberately invalid API key"))
        #expect(report.modelIDs == ["qwen3.6-27b"])
    }

    @Test func reportsRejectedConfiguredAPIKey() async {
        let report = await ExternalCompatibleCorrectorService.checkConfiguration(
            apiKind: .anthropic,
            baseURL: "http://localhost:1234/v1",
            apiKey: "bad-token",
            selectedModel: "claude-sonnet-4-5"
        ) { _, _, _, _ in
            throw OpenAICompatibleClientError.httpStatus(401, "")
        }

        #expect(report.ok == false)
        #expect(report.status == "Failed")
        #expect(report.detail.contains("rejected the API key"))
    }

    @Test func doesNotProbeInvalidAPIKeyWhenKeyIsEmpty() async {
        let recorder = APIKeyRecorder()
        let report = await ExternalCompatibleCorrectorService.checkConfiguration(
            apiKind: .openAI,
            baseURL: "http://localhost:1234/v1",
            apiKey: " ",
            selectedModel: "qwen3.6-27b"
        ) { apiKind, _, apiKey, _ in
            await recorder.record(apiKind: apiKind, apiKey: apiKey)
            return ["qwen3.6-27b"]
        }

        let calls = await recorder.snapshot()
        #expect(report.ok)
        #expect(calls.map(\.apiKey) == [nil])
    }
}

private actor APIKeyRecorder {
    private var calls: [(apiKind: ExternalLLMAPIKind, apiKey: String?)] = []

    func record(apiKind: ExternalLLMAPIKind, apiKey: String?) {
        calls.append((apiKind, apiKey))
    }

    func snapshot() -> [(apiKind: ExternalLLMAPIKind, apiKey: String?)] {
        calls
    }
}
