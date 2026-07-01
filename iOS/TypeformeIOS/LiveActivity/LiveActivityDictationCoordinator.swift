import ActivityKit
import Combine
import Foundation
import OSLog

private let liveActivityLog = Logger(
    subsystem: TypeformeBundleConfiguration.hostBundleIdentifier,
    category: "live-activity"
)

@MainActor
final class LiveActivityDictationCoordinator: ObservableObject {
    @Published private(set) var isEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    @Published private(set) var isActive = false
    @Published private(set) var statusMessage = NSLocalizedString(
        "Live Activity is ready.",
        comment: "Live Activity ready status"
    )
    @Published private(set) var lastErrorMessage: String?

    private var currentActivity: Activity<TypeformeDictationActivityAttributes>?
    private var stateObserverTask: Task<Void, Never>?
    private var lastState = TypeformeDictationActivityAttributes.ContentState(
        phase: .ready,
        detail: NSLocalizedString("Ready for dictation", comment: "Live Activity ready detail"),
        startedAt: nil,
        updatedAt: Date()
    )

    isolated deinit {
        stateObserverTask?.cancel()
    }

    func refreshAuthorization() {
        isEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        refreshActiveActivity()
    }

    @discardableResult
    func start() async -> Bool {
        refreshAuthorization()
        guard isEnabled else {
            lastErrorMessage = NSLocalizedString(
                "Live Activities are disabled for Typeforme.",
                comment: "Live Activity disabled status"
            )
            statusMessage = lastErrorMessage ?? statusMessage
            return false
        }

        if let activity = activeActivity() {
            currentActivity = activity
            observeState(of: activity)
            isActive = true
            statusMessage = NSLocalizedString("Live Activity is active.", comment: "Live Activity active status")
            await updateActivity(with: lastState)
            return true
        }

        do {
            let activity = try Activity<TypeformeDictationActivityAttributes>.request(
                attributes: TypeformeDictationActivityAttributes(sessionID: UUID().uuidString),
                content: ActivityContent(state: lastState, staleDate: nil, relevanceScore: 1.0),
                pushType: nil
            )
            currentActivity = activity
            observeState(of: activity)
            isActive = true
            lastErrorMessage = nil
            statusMessage = NSLocalizedString("Live Activity is active.", comment: "Live Activity active status")
            liveActivityLog.notice("started live activity id=\(activity.id, privacy: .public)")
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            statusMessage = error.localizedDescription
            isActive = false
            liveActivityLog.error("start failed \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func update(_ state: TypeformeDictationActivityAttributes.ContentState) {
        lastState = state
        guard isActive || activeActivity() != nil else { return }
        Task { [weak self] in
            await self?.updateActivity(with: state)
        }
    }

    func stop() {
        let state = TypeformeDictationActivityAttributes.ContentState(
            phase: .ready,
            detail: NSLocalizedString("Ready for dictation", comment: "Live Activity ready detail"),
            startedAt: nil,
            updatedAt: Date()
        )
        lastState = state
        let activityIDs = Activity<TypeformeDictationActivityAttributes>.activities.map(\.id)
        currentActivity = nil
        stateObserverTask?.cancel()
        stateObserverTask = nil
        isActive = false
        statusMessage = NSLocalizedString("Live Activity stopped.", comment: "Live Activity stopped status")
        Task.detached {
            await Self.endActivities(ids: activityIDs, state: state)
        }
    }

    private func updateActivity(with state: TypeformeDictationActivityAttributes.ContentState) async {
        guard let activity = activeActivity() else {
            currentActivity = nil
            isActive = false
            return
        }
        currentActivity = activity
        isActive = true
        let activityID = activity.id
        if !(await Self.updateActivity(id: activityID, state: state)) {
            if currentActivity?.id == activityID {
                currentActivity = nil
            }
            isActive = false
        }
    }

    private func refreshActiveActivity() {
        currentActivity = activeActivity()
        isActive = currentActivity != nil
        if let currentActivity {
            observeState(of: currentActivity)
            statusMessage = NSLocalizedString("Live Activity is active.", comment: "Live Activity active status")
        } else if isEnabled {
            statusMessage = NSLocalizedString("Live Activity is ready.", comment: "Live Activity ready status")
        }
    }

    private func activeActivity() -> Activity<TypeformeDictationActivityAttributes>? {
        Activity<TypeformeDictationActivityAttributes>.activities.first { activity in
            switch activity.activityState {
            case .active:
                return true
            default:
                return false
            }
        }
    }

    private func observeState(of activity: Activity<TypeformeDictationActivityAttributes>) {
        let activityID = activity.id
        guard currentActivity?.id != activityID || stateObserverTask == nil else { return }
        stateObserverTask?.cancel()
        stateObserverTask = Task.detached { [weak self, activityID] in
            guard let activity = Self.activity(with: activityID) else { return }
            for await state in activity.activityStateUpdates {
                await MainActor.run {
                    guard let self else { return }
                    switch state {
                    case .active:
                        self.isActive = true
                        self.statusMessage = NSLocalizedString(
                            "Live Activity is active.",
                            comment: "Live Activity active status"
                        )
                    default:
                        if self.currentActivity?.id == activityID {
                            self.currentActivity = nil
                        }
                        self.isActive = false
                        self.statusMessage = NSLocalizedString(
                            "Live Activity stopped.",
                            comment: "Live Activity stopped status"
                        )
                    }
                }
            }
        }
    }

    private nonisolated static func updateActivity(
        id activityID: String,
        state: TypeformeDictationActivityAttributes.ContentState
    ) async -> Bool {
        guard let activity = activity(with: activityID) else { return false }
        await activity.update(ActivityContent(state: state, staleDate: nil, relevanceScore: 1.0))
        return true
    }

    private nonisolated static func endActivities(
        ids activityIDs: [String],
        state: TypeformeDictationActivityAttributes.ContentState
    ) async {
        for activityID in activityIDs {
            guard let activity = activity(with: activityID) else { continue }
            await activity.end(
                ActivityContent(state: state, staleDate: nil, relevanceScore: 0),
                dismissalPolicy: .immediate
            )
        }
    }

    private nonisolated static func activity(
        with activityID: String
    ) -> Activity<TypeformeDictationActivityAttributes>? {
        Activity<TypeformeDictationActivityAttributes>.activities.first { activity in
            activity.id == activityID
        }
    }
}
