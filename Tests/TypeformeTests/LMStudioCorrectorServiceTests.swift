import Foundation
import Testing
@testable import Typeforme

@Suite("LMStudioCorrectorService")
struct LMStudioCorrectorServiceTests {
    @Test func buildsChatCompletionsEndpointFromRootOrV1Base() throws {
        #expect(try LMStudioCorrectorService.chatCompletionsEndpoint(baseURL: "http://localhost:1234").absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(try LMStudioCorrectorService.chatCompletionsEndpoint(baseURL: "http://localhost:1234/v1").absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(try LMStudioCorrectorService.chatCompletionsEndpoint(baseURL: "http://localhost:1234/v1/chat/completions").absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(try LMStudioCorrectorService.chatCompletionsEndpoint(baseURL: "http://localhost:1234/v1/models").absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(try LMStudioCorrectorService.chatCompletionsEndpoint(baseURL: "http://192.0.2.10:1234/v1").absoluteString == "http://192.0.2.10:1234/v1/chat/completions")
        #expect(try LMStudioCorrectorService.chatCompletionsEndpoint(baseURL: "https://lmstudio.example.com/v1").absoluteString == "https://lmstudio.example.com/v1/chat/completions")
    }

    @Test func buildsModelsEndpointFromChatEndpoint() throws {
        #expect(try LMStudioCorrectorService.modelsEndpoint(baseURL: "http://localhost:1234").absoluteString == "http://localhost:1234/v1/models")
        #expect(try LMStudioCorrectorService.modelsEndpoint(baseURL: "http://localhost:1234/v1/chat/completions").absoluteString == "http://localhost:1234/v1/models")
        #expect(try LMStudioCorrectorService.modelsEndpoint(baseURL: "http://localhost:1234/v1/models").absoluteString == "http://localhost:1234/v1/models")
        #expect(try LMStudioCorrectorService.modelsEndpoint(baseURL: "http://192.0.2.10:1234/v1/chat/completions").absoluteString == "http://192.0.2.10:1234/v1/models")
        #expect(try LMStudioCorrectorService.modelsEndpoint(baseURL: "https://lmstudio.example.com").absoluteString == "https://lmstudio.example.com/v1/models")
    }

    @Test func rejectsNonHTTPBaseURL() {
        #expect(throws: (any Error).self) {
            _ = try LMStudioCorrectorService.chatCompletionsEndpoint(baseURL: "file:///tmp/lmstudio")
        }
    }

    @Test func parsesModelIDsFromModelsResponse() throws {
        let data = #"{"data":[{"id":"qwen/qwen3-35b-a3b"},{"id":"  "},{"id":"mlx-community/Qwen3-4B"}]}"#
            .data(using: .utf8)!
        #expect(LMStudioCorrectorService.modelIDs(data: data) == [
            "qwen/qwen3-35b-a3b",
            "mlx-community/Qwen3-4B",
        ])
    }

    @Test func enforcesLMStudioMinimumTimeout() {
        #expect(LMStudioCorrectorService.effectiveTimeoutMs(50) == LMStudioCorrectorService.minimumRequestTimeoutMs)
        #expect(LMStudioCorrectorService.effectiveTimeoutMs(1500) == 1500)
        #expect(LMStudioCorrectorService.effectiveTimeoutMs(45_000) == 45_000)
    }

    @Test func selectsFirstAvailableModelWhenCurrentDisappears() {
        #expect(LMStudioCorrectorService.modelSelectionAfterRefresh(
            current: "qwen3.5-old",
            available: ["qwen3.6-27b", "qwen3.5-9b"],
            selectFirstModel: false
        ) == "qwen3.6-27b")
    }

    @Test func preservesAvailableModelAfterRefresh() {
        #expect(LMStudioCorrectorService.modelSelectionAfterRefresh(
            current: " qwen3.5-9b ",
            available: ["qwen3.6-27b", "qwen3.5-9b"],
            selectFirstModel: false
        ) == "qwen3.5-9b")
    }

    @Test func onlySelectsFirstForEmptyModelWhenRequested() {
        #expect(LMStudioCorrectorService.modelSelectionAfterRefresh(
            current: "",
            available: ["qwen3.6-27b"],
            selectFirstModel: false
        ) == "")
        #expect(LMStudioCorrectorService.modelSelectionAfterRefresh(
            current: "",
            available: ["qwen3.6-27b"],
            selectFirstModel: true
        ) == "qwen3.6-27b")
    }

    @Test func reportsNoLoadedModelsAsUnavailable() {
        let report = LMStudioCorrectorService.availabilityReport(
            modelIDs: [],
            selectedModel: "qwen3.6-27b"
        )
        #expect(report.ok == false)
        #expect(report.status == "Failed")
        #expect(report.detail.contains("no models are loaded"))
    }

    @Test func reportsMissingSelectedModelAsReadyForRefreshFallback() {
        let report = LMStudioCorrectorService.availabilityReport(
            modelIDs: ["qwen3.6-35b"],
            selectedModel: "qwen3.6-27b"
        )
        #expect(report.ok)
        #expect(report.status == "Ready")
        #expect(report.detail.contains("Selected model qwen3.6-27b is not loaded"))
        #expect(report.detail.contains("Using qwen3.6-35b"))
    }

    @Test func reportsLoadedSelectedModelAsReady() {
        let report = LMStudioCorrectorService.availabilityReport(
            modelIDs: ["qwen3.6-27b"],
            selectedModel: "qwen3.6-27b"
        )
        #expect(report.ok)
        #expect(report.status == "Ready")
    }

    @Test func verifiesProvidedAPIKeyByRejectingInvalidProbe() async {
        let recorder = APIKeyRecorder()
        let report = await LMStudioCorrectorService.checkConfiguration(
            baseURL: "http://localhost:1234/v1",
            apiKey: "real-token",
            selectedModel: "qwen3.6-27b"
        ) { _, apiKey, _ in
            await recorder.record(apiKey)
            if apiKey == "real-token" {
                return ["qwen3.6-27b"]
            }
            if apiKey?.hasPrefix("typeforme-invalid-lmstudio-token-") == true {
                throw OpenAICompatibleClientError.httpStatus(401, "")
            }
            return []
        }

        let apiKeys = await recorder.snapshot()
        #expect(report.ok)
        #expect(report.detail.contains("API key verified."))
        #expect(apiKeys.count == 2)
        #expect(apiKeys.first == "real-token")
        #expect(apiKeys.last??.hasPrefix("typeforme-invalid-lmstudio-token-") == true)
    }

    @Test func reportsAPIKeyUnverifiedWhenInvalidProbeIsAccepted() async {
        let report = await LMStudioCorrectorService.checkConfiguration(
            baseURL: "http://localhost:1234/v1",
            apiKey: "real-token",
            selectedModel: "qwen3.6-27b"
        ) { _, _, _ in
            ["qwen3.6-27b"]
        }

        #expect(report.ok == false)
        #expect(report.status == "Failed")
        #expect(report.detail.contains("accepted a deliberately invalid API key"))
        #expect(report.modelIDs == ["qwen3.6-27b"])
    }

    @Test func reportsRejectedConfiguredAPIKey() async {
        let report = await LMStudioCorrectorService.checkConfiguration(
            baseURL: "http://localhost:1234/v1",
            apiKey: "bad-token",
            selectedModel: "qwen3.6-27b"
        ) { _, _, _ in
            throw OpenAICompatibleClientError.httpStatus(401, "")
        }

        #expect(report.ok == false)
        #expect(report.status == "Failed")
        #expect(report.detail.contains("rejected the API key"))
    }

    @Test func doesNotProbeInvalidAPIKeyWhenKeyIsEmpty() async {
        let recorder = APIKeyRecorder()
        let report = await LMStudioCorrectorService.checkConfiguration(
            baseURL: "http://localhost:1234/v1",
            apiKey: " ",
            selectedModel: "qwen3.6-27b"
        ) { _, apiKey, _ in
            await recorder.record(apiKey)
            return ["qwen3.6-27b"]
        }

        let apiKeys = await recorder.snapshot()
        #expect(report.ok)
        #expect(apiKeys == [nil])
    }
}

private actor APIKeyRecorder {
    private var apiKeys: [String?] = []

    func record(_ apiKey: String?) {
        apiKeys.append(apiKey)
    }

    func snapshot() -> [String?] {
        apiKeys
    }
}
