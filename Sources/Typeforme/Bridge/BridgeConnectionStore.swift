import Combine
import Foundation

enum BridgeRequestEndpoint: String, CaseIterable, Hashable, Sendable {
    case health
    case pairing
    case settingsRead
    case settingsWrite
    case dictate
    case restyle
    case editText

    var displayName: String {
        switch self {
        case .health: return "Health"
        case .pairing: return "Pairing"
        case .settingsRead: return "Settings"
        case .settingsWrite: return "Settings update"
        case .dictate: return "Dictate"
        case .restyle: return "Restyle"
        case .editText: return "Edit text"
        }
    }

    var methodAndPath: String {
        switch self {
        case .health: return "GET /v1/health"
        case .pairing: return "GET /v1/pairing"
        case .settingsRead: return "GET /v1/settings"
        case .settingsWrite: return "POST /v1/settings"
        case .dictate: return "POST /v1/dictate"
        case .restyle: return "POST /v1/restyle"
        case .editText: return "POST /v1/edit-text"
        }
    }
}

struct BridgeClientRequestActivity: Equatable, Sendable {
    let endpoint: BridgeRequestEndpoint
    let clientHost: String
    let clientPort: Int?
    let userAgent: String?
    let statusCode: Int
    let occurredAt: Date
    let latencyMs: Int
    let appName: String?
    let bundleID: String?

    var clientID: String {
        let trimmed = clientHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    var succeeded: Bool {
        (200..<300).contains(statusCode)
    }
}

struct BridgeClientActivityRecord: Identifiable, Equatable, Sendable {
    let id: String
    var host: String
    var lastPort: Int?
    var userAgent: String?
    var appName: String?
    var bundleID: String?
    var firstSeenAt: Date
    var lastSeenAt: Date
    var lastEndpoint: BridgeRequestEndpoint
    var lastStatusCode: Int
    var lastLatencyMs: Int
    var requestCount: Int
    var successCount: Int
    var failureCount: Int
    var endpointCounts: [BridgeRequestEndpoint: Int]

    init(activity: BridgeClientRequestActivity) {
        self.id = activity.clientID
        self.host = activity.clientID
        self.lastPort = activity.clientPort
        self.userAgent = Self.clean(activity.userAgent)
        self.appName = Self.clean(activity.appName)
        self.bundleID = Self.clean(activity.bundleID)
        self.firstSeenAt = activity.occurredAt
        self.lastSeenAt = activity.occurredAt
        self.lastEndpoint = activity.endpoint
        self.lastStatusCode = activity.statusCode
        self.lastLatencyMs = activity.latencyMs
        self.requestCount = 1
        self.successCount = activity.succeeded ? 1 : 0
        self.failureCount = activity.succeeded ? 0 : 1
        self.endpointCounts = [activity.endpoint: 1]
    }

    mutating func record(_ activity: BridgeClientRequestActivity) {
        lastPort = activity.clientPort ?? lastPort
        if let userAgent = Self.clean(activity.userAgent) {
            self.userAgent = userAgent
        }
        if let appName = Self.clean(activity.appName) {
            self.appName = appName
        }
        if let bundleID = Self.clean(activity.bundleID) {
            self.bundleID = bundleID
        }
        lastSeenAt = activity.occurredAt
        lastEndpoint = activity.endpoint
        lastStatusCode = activity.statusCode
        lastLatencyMs = activity.latencyMs
        requestCount += 1
        if activity.succeeded {
            successCount += 1
        } else {
            failureCount += 1
        }
        endpointCounts[activity.endpoint, default: 0] += 1
    }

    func count(for endpoint: BridgeRequestEndpoint) -> Int {
        endpointCounts[endpoint, default: 0]
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct BridgeConnectionSnapshot: Equatable, Sendable {
    var clients: [BridgeClientActivityRecord]
    var totalRequests: Int
    var successfulRequests: Int
    var failedRequests: Int
    var endpointCounts: [BridgeRequestEndpoint: Int]
    var firstRequestAt: Date?
    var lastRequestAt: Date?

    static let empty = BridgeConnectionSnapshot(
        clients: [],
        totalRequests: 0,
        successfulRequests: 0,
        failedRequests: 0,
        endpointCounts: [:],
        firstRequestAt: nil,
        lastRequestAt: nil
    )

    func count(for endpoint: BridgeRequestEndpoint) -> Int {
        endpointCounts[endpoint, default: 0]
    }
}

struct BridgeConnectionAccumulator {
    private var clientsByID: [String: BridgeClientActivityRecord] = [:]
    private var endpointCounts: [BridgeRequestEndpoint: Int] = [:]
    private var totalRequests = 0
    private var successfulRequests = 0
    private var failedRequests = 0
    private var firstRequestAt: Date?
    private var lastRequestAt: Date?

    mutating func record(_ activity: BridgeClientRequestActivity) -> BridgeConnectionSnapshot {
        totalRequests += 1
        if activity.succeeded {
            successfulRequests += 1
        } else {
            failedRequests += 1
        }
        endpointCounts[activity.endpoint, default: 0] += 1
        firstRequestAt = firstRequestAt ?? activity.occurredAt
        lastRequestAt = activity.occurredAt

        if var client = clientsByID[activity.clientID] {
            client.record(activity)
            clientsByID[activity.clientID] = client
        } else {
            clientsByID[activity.clientID] = BridgeClientActivityRecord(activity: activity)
        }

        return snapshot
    }

    mutating func reset() -> BridgeConnectionSnapshot {
        self = BridgeConnectionAccumulator()
        return .empty
    }

    var snapshot: BridgeConnectionSnapshot {
        BridgeConnectionSnapshot(
            clients: clientsByID.values.sorted {
                if $0.lastSeenAt == $1.lastSeenAt {
                    return $0.host < $1.host
                }
                return $0.lastSeenAt > $1.lastSeenAt
            },
            totalRequests: totalRequests,
            successfulRequests: successfulRequests,
            failedRequests: failedRequests,
            endpointCounts: endpointCounts,
            firstRequestAt: firstRequestAt,
            lastRequestAt: lastRequestAt
        )
    }
}

final class BridgeConnectionStore: ObservableObject, @unchecked Sendable {
    static let shared = BridgeConnectionStore()
    static let clientRequestNotification = Notification.Name("typeforme.bridge.clientRequest")

    @Published private(set) var snapshot: BridgeConnectionSnapshot = .empty

    private let lock = NSLock()
    private var accumulator = BridgeConnectionAccumulator()

    func record(_ activity: BridgeClientRequestActivity) {
        lock.lock()
        let nextSnapshot = accumulator.record(activity)
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.snapshot = nextSnapshot
            NotificationCenter.default.post(name: Self.clientRequestNotification, object: activity)
        }
    }

    func reset() {
        lock.lock()
        let nextSnapshot = accumulator.reset()
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.snapshot = nextSnapshot
        }
    }
}
