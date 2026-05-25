import Foundation

actor BridgeJobStatusCenter {
    static let shared = BridgeJobStatusCenter()

    private static let maxEventsPerJob = 32
    private static let maxJobAge: TimeInterval = 10 * 60

    private struct JobEvents {
        var events: [BridgeJobStatusEvent] = []
        var updatedAt = Date()
    }

    private var eventsByJobID: [String: JobEvents] = [:]
    private var subscribersByJobID: [String: [UUID: AsyncStream<BridgeJobStatusEvent>.Continuation]] = [:]

    func publish(_ event: BridgeJobStatusEvent) {
        pruneExpiredJobs()

        var jobEvents = eventsByJobID[event.jobID] ?? JobEvents()
        jobEvents.events.append(event)
        if jobEvents.events.count > Self.maxEventsPerJob {
            jobEvents.events.removeFirst(jobEvents.events.count - Self.maxEventsPerJob)
        }
        jobEvents.updatedAt = Date()
        eventsByJobID[event.jobID] = jobEvents

        let continuations = subscribersByJobID[event.jobID] ?? [:]
        for continuation in continuations.values {
            continuation.yield(event)
        }
        if event.stage.isTerminal {
            for continuation in continuations.values {
                continuation.finish()
            }
            subscribersByJobID[event.jobID] = nil
        }
    }

    func subscribe(jobID: String) -> AsyncStream<BridgeJobStatusEvent> {
        pruneExpiredJobs()
        let subscriberID = UUID()
        var continuation: AsyncStream<BridgeJobStatusEvent>.Continuation!
        let stream = AsyncStream<BridgeJobStatusEvent>(bufferingPolicy: .bufferingNewest(64)) {
            continuation = $0
        }

        subscribersByJobID[jobID, default: [:]][subscriberID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.unsubscribe(jobID: jobID, subscriberID: subscriberID)
            }
        }

        let replayEvents = eventsByJobID[jobID]?.events ?? []
        for event in replayEvents {
            continuation.yield(event)
        }
        if replayEvents.last?.stage.isTerminal == true {
            continuation.finish()
            subscribersByJobID[jobID]?[subscriberID] = nil
        }
        return stream
    }

    private func unsubscribe(jobID: String, subscriberID: UUID) {
        subscribersByJobID[jobID]?[subscriberID] = nil
        if subscribersByJobID[jobID]?.isEmpty == true {
            subscribersByJobID[jobID] = nil
        }
    }

    private func pruneExpiredJobs() {
        let cutoff = Date().addingTimeInterval(-Self.maxJobAge)
        eventsByJobID = eventsByJobID.filter { _, value in
            value.updatedAt >= cutoff
        }
    }
}
