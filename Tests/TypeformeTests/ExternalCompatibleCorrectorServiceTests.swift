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
        #expect(try ExternalCompatibleCorrectorService.modelIDs(data: data, apiKind: .openAI) == [
            "qwen/qwen3-35b-a3b",
            "claude-sonnet-4-5",
        ])
        #expect(try ExternalCompatibleCorrectorService.modelIDs(data: data, apiKind: .anthropic) == [
            "qwen/qwen3-35b-a3b",
            "claude-sonnet-4-5",
        ])
    }

    @Test func rejectsUnexpectedModelsResponseShape() throws {
        let data = #"{"models":[{"id":"qwen"}]}"#.data(using: .utf8)!

        expectInvalidModelsResponse(data: data, apiKind: .openAI)
        expectInvalidModelsResponse(data: data, apiKind: .anthropic)
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

    @Test func completionUsesConfigurationCapturedWhenServiceWasCreated() async throws {
        let recorder = ExternalOpenAICompletionRecorder()
        var currentConfiguration = ExternalCompatibleCorrectorConfiguration(
            kind: .externalOpenAICompatible,
            baseURL: "https://first.example.com/custom",
            model: "model-a",
            apiKey: "key-a",
            maxTokens: 321
        )
        let service = ExternalCompatibleCorrectorService(
            configuration: currentConfiguration,
            openAICompletion: { endpoint, request, apiKey, timeoutMs in
                await recorder.record(
                    endpoint: endpoint,
                    request: request,
                    apiKey: apiKey,
                    timeoutMs: timeoutMs
                )
                return "captured"
            }
        )

        currentConfiguration = ExternalCompatibleCorrectorConfiguration(
            kind: .externalOpenAICompatible,
            baseURL: "https://second.example.com/v1",
            model: "model-b",
            apiKey: "key-b",
            maxTokens: 999
        )

        let output = try await service.complete(
            system: "system",
            messages: [.user("user")],
            timeoutMs: 777
        )
        let call = try #require(await recorder.snapshot())

        #expect(currentConfiguration.model == "model-b")
        #expect(output == "captured")
        #expect(call.endpoint.absoluteString == "https://first.example.com/custom/v1/chat/completions")
        #expect(call.request.model == "model-a")
        #expect(call.request.maxTokens == 321)
        #expect(call.apiKey == "key-a")
        #expect(call.timeoutMs == 777)
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

    @Test func reportsMissingSelectedModelWithoutClaimingImplicitUse() {
        let report = ExternalCompatibleCorrectorService.availabilityReport(
            modelIDs: ["qwen3.6-35b"],
            selectedModel: "qwen3.6-27b",
            apiKind: .openAI
        )
        #expect(report.ok == false)
        #expect(report.status == "Failed")
        #expect(report.detail.contains("Selected model qwen3.6-27b is not listed"))
        #expect(report.detail.contains("Using qwen3.6-35b") == false)
        #expect(report.detail.contains("Select a listed model"))
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

    @Test func openAIClientPropagatesParentTaskCancellation() async throws {
        let endpoint = try #require(URL(string: "https://typeforme.invalid/parent-cancellation"))
        let eventID = endpoint.absoluteString
        HangingOpenAIURLProtocol.events.reset(eventID)
        let session = hangingOpenAISession()
        defer { session.invalidateAndCancel() }

        let requestTask = Task {
            try await OpenAICompatibleClient.responseData(
                for: URLRequest(url: endpoint),
                timeoutMs: 2_000,
                onTimeout: nil,
                session: session
            )
        }
        try await waitForProtocolEvent("request to start") {
            HangingOpenAIURLProtocol.events.didStart(eventID)
        }

        requestTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await requestTask.value
        }
        try await waitForProtocolEvent("cancelled request to stop") {
            HangingOpenAIURLProtocol.events.didStop(eventID)
        }
        #expect(HangingOpenAIURLProtocol.events.didStop(eventID))
    }

    @Test func openAIClientMapsDeadlineCancellationToTimeout() async throws {
        let endpoint = try #require(URL(string: "https://typeforme.invalid/request-timeout"))
        let eventID = endpoint.absoluteString
        HangingOpenAIURLProtocol.events.reset(eventID)
        let session = hangingOpenAISession()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await OpenAICompatibleClient.responseData(
                for: URLRequest(url: endpoint),
                timeoutMs: 250,
                onTimeout: nil,
                session: session
            )
            Issue.record("Expected the hanging request to time out")
        } catch let error as OpenAICompatibleClientError {
            #expect(error == .timeout)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(HangingOpenAIURLProtocol.events.didStart(eventID))
        try await waitForProtocolEvent("timed-out request to stop") {
            HangingOpenAIURLProtocol.events.didStop(eventID)
        }
        #expect(HangingOpenAIURLProtocol.events.didStop(eventID))
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

    private func expectInvalidModelsResponse(data: Data, apiKind: ExternalLLMAPIKind) {
        do {
            _ = try ExternalCompatibleCorrectorService.modelIDs(data: data, apiKind: apiKind)
            Issue.record("Expected /v1/models invalid response error")
        } catch let error as OpenAICompatibleClientError {
            #expect(error == .invalidResponse("unexpected /v1/models response shape"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func hangingOpenAISession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingOpenAIURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func waitForProtocolEvent(
        _ description: String,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("Timed out waiting for \(description)")
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

private actor ExternalOpenAICompletionRecorder {
    struct Call: Sendable {
        let endpoint: URL
        let request: OpenAIChatCompletionRequest
        let apiKey: String
        let timeoutMs: Int
    }

    private var call: Call?

    func record(
        endpoint: URL,
        request: OpenAIChatCompletionRequest,
        apiKey: String,
        timeoutMs: Int
    ) {
        call = Call(
            endpoint: endpoint,
            request: request,
            apiKey: apiKey,
            timeoutMs: timeoutMs
        )
    }

    func snapshot() -> Call? {
        call
    }
}

private final class HangingOpenAIURLProtocol: URLProtocol, @unchecked Sendable {
    static let events = HangingOpenAIURLProtocolEvents()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let eventID = request.url?.absoluteString else { return }
        Self.events.recordStart(eventID)
    }

    override func stopLoading() {
        guard let eventID = request.url?.absoluteString else { return }
        Self.events.recordStop(eventID)
    }
}

private final class HangingOpenAIURLProtocolEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var started: Set<String> = []
    private var stopped: Set<String> = []

    func reset(_ eventID: String) {
        lock.lock()
        defer { lock.unlock() }
        started.remove(eventID)
        stopped.remove(eventID)
    }

    func recordStart(_ eventID: String) {
        lock.lock()
        defer { lock.unlock() }
        started.insert(eventID)
    }

    func recordStop(_ eventID: String) {
        lock.lock()
        defer { lock.unlock() }
        stopped.insert(eventID)
    }

    func didStart(_ eventID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return started.contains(eventID)
    }

    func didStop(_ eventID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped.contains(eventID)
    }
}
