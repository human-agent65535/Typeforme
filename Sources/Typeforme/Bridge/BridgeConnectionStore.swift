import Combine
import Foundation

enum BridgeRequestEndpoint: String, CaseIterable, Hashable, Sendable {
    case health
    case pairing
    case settingsRead
    case settingsWrite
    case dictate
    case jobEvents
    case restyle
    case editText

    var displayName: String {
        switch self {
        case .health: return "Health"
        case .pairing: return "Pairing"
        case .settingsRead: return "Settings"
        case .settingsWrite: return "Settings update"
        case .dictate: return "Dictate"
        case .jobEvents: return "Job events"
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
        case .jobEvents: return "GET /v1/jobs/:jobID/events"
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
    let clientIdentityID: String
    let clientDisplayName: String?
    let clientPlatform: String?
    let clientBundleID: String?
    let forwardedClientIP: String?
    let cloudflareRayID: String?
    let statusCode: Int
    let occurredAt: Date
    let latencyMs: Int
    let appName: String?
    let bundleID: String?

    init(
        endpoint: BridgeRequestEndpoint,
        clientHost: String,
        clientPort: Int?,
        userAgent: String?,
        clientIdentityID: String,
        statusCode: Int,
        occurredAt: Date,
        latencyMs: Int,
        appName: String?,
        bundleID: String?,
        clientDisplayName: String? = nil,
        clientPlatform: String? = nil,
        clientBundleID: String? = nil,
        forwardedClientIP: String? = nil,
        cloudflareRayID: String? = nil
    ) {
        self.endpoint = endpoint
        self.clientHost = clientHost
        self.clientPort = clientPort
        self.userAgent = userAgent
        self.clientIdentityID = clientIdentityID
        self.statusCode = statusCode
        self.occurredAt = occurredAt
        self.latencyMs = latencyMs
        self.appName = appName
        self.bundleID = bundleID
        self.clientDisplayName = clientDisplayName
        self.clientPlatform = clientPlatform
        self.clientBundleID = clientBundleID
        self.forwardedClientIP = forwardedClientIP
        self.cloudflareRayID = cloudflareRayID
    }

    var clientID: String {
        Self.clean(clientIdentityID) ?? "invalid"
    }

    var succeeded: Bool {
        (200..<300).contains(statusCode)
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct BridgeClientActivityRecord: Identifiable, Equatable, Sendable {
    let id: String
    var host: String
    var lastPort: Int?
    var userAgent: String?
    var clientIdentityID: String
    var clientDisplayName: String?
    var clientPlatform: String?
    var clientBundleID: String?
    var forwardedClientIP: String?
    var cloudflareRayID: String?
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
        self.host = Self.clean(activity.clientHost) ?? "unknown"
        self.lastPort = activity.clientPort
        self.userAgent = Self.clean(activity.userAgent)
        self.clientIdentityID = activity.clientID
        self.clientDisplayName = Self.clean(activity.clientDisplayName)
        self.clientPlatform = Self.clean(activity.clientPlatform)
        self.clientBundleID = Self.clean(activity.clientBundleID)
        self.forwardedClientIP = Self.clean(activity.forwardedClientIP)
        self.cloudflareRayID = Self.clean(activity.cloudflareRayID)
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
        host = Self.clean(activity.clientHost) ?? host
        lastPort = activity.clientPort ?? lastPort
        if let userAgent = Self.clean(activity.userAgent) {
            self.userAgent = userAgent
        }
        clientIdentityID = activity.clientID
        if let clientDisplayName = Self.clean(activity.clientDisplayName) {
            self.clientDisplayName = clientDisplayName
        }
        if let clientPlatform = Self.clean(activity.clientPlatform) {
            self.clientPlatform = clientPlatform
        }
        if let clientBundleID = Self.clean(activity.clientBundleID) {
            self.clientBundleID = clientBundleID
        }
        if let forwardedClientIP = Self.clean(activity.forwardedClientIP) {
            self.forwardedClientIP = forwardedClientIP
        }
        if let cloudflareRayID = Self.clean(activity.cloudflareRayID) {
            self.cloudflareRayID = cloudflareRayID
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

    var usesCloudflare: Bool {
        cloudflareRayID != nil
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
                    return ($0.clientDisplayName ?? $0.host) < ($1.clientDisplayName ?? $1.host)
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
    private var pendingSnapshot: BridgeConnectionSnapshot?
    private var pendingActivity: BridgeClientRequestActivity?
    private var publishWorkItem: DispatchWorkItem?
    private static let publishDebounce: TimeInterval = 0.15

    func record(_ activity: BridgeClientRequestActivity) {
        let shouldSchedule: Bool
        lock.lock()
        let nextSnapshot = accumulator.record(activity)
        pendingSnapshot = nextSnapshot
        pendingActivity = activity
        shouldSchedule = publishWorkItem == nil
        lock.unlock()

        if shouldSchedule {
            schedulePublish()
        }
    }

    func reset() {
        let workItem: DispatchWorkItem?
        lock.lock()
        let nextSnapshot = accumulator.reset()
        pendingSnapshot = nil
        pendingActivity = nil
        workItem = publishWorkItem
        publishWorkItem = nil
        lock.unlock()

        workItem?.cancel()
        DispatchQueue.main.async { [weak self] in
            self?.snapshot = nextSnapshot
        }
    }

    private func schedulePublish() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingPublish()
        }
        lock.lock()
        publishWorkItem = workItem
        lock.unlock()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.publishDebounce,
            execute: workItem
        )
    }

    private func flushPendingPublish() {
        lock.lock()
        let nextSnapshot = pendingSnapshot
        let activity = pendingActivity
        pendingSnapshot = nil
        pendingActivity = nil
        publishWorkItem = nil
        lock.unlock()

        if let nextSnapshot {
            snapshot = nextSnapshot
        }
        if let activity {
            NotificationCenter.default.post(name: Self.clientRequestNotification, object: activity)
        }
    }
}
