import AVKit
import OSLog
import SwiftUI
import UIKit

private let pipLog = Logger(subsystem: TypeformeBundleConfiguration.hostBundleIdentifier, category: "pip")

private enum PiPDictationLayout {
    static let preferredContentSize = CGSize(width: 128, height: 72)

    @MainActor
    static func applyPreferredSize(to view: UIView) {
        let size = preferredContentSize
        if view.bounds.size != size {
            view.bounds = CGRect(origin: .zero, size: size)
        }
        if view.frame.size != size {
            view.frame = CGRect(origin: view.frame.origin, size: size)
        }
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.invalidateIntrinsicContentSize()
    }
}

struct PiPDictationPresentation: Equatable {
    var title: String
    var stateLabel: String
    var isRecording: Bool
    var recordingStartedAt: Date?

    static let ready = PiPDictationPresentation(
        title: "Typeforme",
        stateLabel: "Ready",
        isRecording: false,
        recordingStartedAt: nil
    )
}

/// AVKit's delegate is not actor-isolated. The reference crosses to the main
/// actor without being touched and is retained so an old controller's object
/// identity cannot be recycled before its queued callback is validated.
private struct PiPControllerReference: @unchecked Sendable {
    let controller: AVPictureInPictureController
}

@MainActor
final class PiPDictationCoordinator: NSObject, ObservableObject {
    @Published private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var lastErrorMessage: String?

    var audioLevelProvider: (() -> Float)?
    var onDidStop: (() -> Void)?

    private var sourceView: UIView?
    private var contentViewController: AVPictureInPictureVideoCallViewController?
    private var contentView: PiPVideoCallContentView?
    private var pictureInPictureController: AVPictureInPictureController?
    private var contentUpdateTask: Task<Void, Never>?
    private var operationState: OperationState = .idle
    private var operationGeneration: UInt64 = 0
    private var controllerGeneration: UInt64?
    private var controllerStartRequestedGeneration: UInt64?
    private var stopAcknowledgedGeneration: UInt64?
    private var preserveStopStatusGeneration: UInt64?
    private var startFlight: StartFlight?
    private var stopFlight: StopFlight?
    private var presentation = PiPDictationPresentation.ready

    private enum OperationState: Equatable {
        case idle
        case starting(UInt64)
        case active(UInt64)
        case stopping(UInt64)

        var generation: UInt64? {
            switch self {
            case .idle:
                return nil
            case .starting(let generation), .active(let generation), .stopping(let generation):
                return generation
            }
        }
    }

    private struct StartFlight {
        let generation: UInt64
        let task: Task<Bool, Never>
    }

    private struct StopFlight {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private static let startupSourceViewTimeout: TimeInterval = 1.0
    private static let startupReadinessTimeout: TimeInterval = 1.6
    private static let startupActivationTimeout: TimeInterval = 2.0
    private static let startupReadinessPollInterval: UInt64 = 80_000_000
    private static let contentUpdateInterval: UInt64 = 250_000_000

    func attachSourceView(_ view: UIView) {
        guard sourceView !== view else {
            refreshCapability()
            return
        }

        PiPDictationLayout.applyPreferredSize(to: view)
        sourceView = view
        if operationState == .idle {
            resetInactiveController()
        }
        updateContentView()
        refreshCapability()
    }

    func updatePresentation(_ next: PiPDictationPresentation) {
        guard presentation != next else { return }
        presentation = next
        updateContentView()
    }

    @discardableResult
    func start() async -> Bool {
        while !Task.isCancelled {
            switch operationState {
            case .active(let generation):
                guard let controller = currentController(for: generation),
                      controller.isPictureInPictureActive
                else {
                    beginStopping(
                        generation: generation,
                        controller: currentController(for: generation),
                        terminalAcknowledged: false,
                        preserveStatus: false
                    )
                    continue
                }
                isActive = true
                statusMessage = NSLocalizedString("Picture in Picture is active.", comment: "PiP active status")
                startContentUpdates()
                return true

            case .starting(let generation):
                guard let flight = startFlight, flight.generation == generation else {
                    pipLog.error("start state lost flight generation=\(generation, privacy: .public)")
                    failUnstartedGeneration(generation, controller: currentController(for: generation))
                    continue
                }
                return await awaitStartFlight(flight)

            case .stopping(let generation):
                guard let flight = stopFlight, flight.generation == generation else {
                    pipLog.error("stop state lost flight generation=\(generation, privacy: .public)")
                    completeCoordinatedStop(generation: generation, controller: currentController(for: generation))
                    continue
                }
                await flight.task.value

            case .idle:
                if let flight = stopFlight {
                    await flight.task.value
                    continue
                }
                let generation = nextOperationGeneration()
                operationState = .starting(generation)
                lastErrorMessage = nil
                let task = Task { @MainActor [weak self] in
                    guard let self else { return false }
                    return await self.performStart(generation: generation)
                }
                let flight = StartFlight(generation: generation, task: task)
                startFlight = flight
                return await awaitStartFlight(flight)
            }
        }
        return false
    }

    private func performStart(generation: UInt64) async -> Bool {
        guard isCurrentStartingGeneration(generation), !Task.isCancelled else {
            cancelStart(generation: generation)
            return false
        }
        guard isSupported else {
            pipLog.notice("start rejected: PiP unsupported")
            lastErrorMessage = NSLocalizedString(
                "Picture in Picture is not supported on this device.",
                comment: "PiP unsupported status"
            )
            statusMessage = lastErrorMessage ?? ""
            failUnstartedGeneration(generation, controller: nil)
            return false
        }
        let sourceView: UIView
        do {
            guard let readySourceView = try await waitForSourceView(generation: generation) else {
                pipLog.notice("start rejected: source view missing")
                lastErrorMessage = NSLocalizedString(
                    "Picture in Picture is still preparing.",
                    comment: "PiP source view missing status"
                )
                statusMessage = lastErrorMessage ?? ""
                failUnstartedGeneration(generation, controller: nil)
                return false
            }
            sourceView = readySourceView
        } catch is CancellationError {
            cancelStart(generation: generation)
            pipLog.debug("start cancelled while waiting for source view")
            return false
        } catch {
            pipLog.error("start source view wait failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        guard isCurrentStartingGeneration(generation), !Task.isCancelled else {
            cancelStart(generation: generation)
            return false
        }
        let controller = ensureController(for: sourceView, generation: generation)
        startContentUpdates()
        do {
            try await waitUntilPictureInPictureIsPossible(controller, generation: generation)
        } catch is CancellationError {
            cancelStart(generation: generation)
            pipLog.debug("start cancelled while waiting for PiP readiness")
            return false
        } catch {
            pipLog.error("start readiness wait failed: \(error.localizedDescription, privacy: .public)")
            stopContentUpdatesIfIdle()
            return false
        }
        pipLog.notice(
            "start check: supported=\(self.isSupported, privacy: .public) possible=\(controller.isPictureInPicturePossible, privacy: .public) active=\(controller.isPictureInPictureActive, privacy: .public) sourceWindow=\(sourceView.window != nil, privacy: .public) sourceBounds=\(sourceView.bounds.debugDescription, privacy: .public)"
        )

        guard controller.isPictureInPicturePossible else {
            pipLog.notice("start rejected: PiP not possible")
            lastErrorMessage = NSLocalizedString(
                "Picture in Picture is not available right now.",
                comment: "PiP unavailable status"
            )
            statusMessage = lastErrorMessage ?? ""
            failUnstartedGeneration(generation, controller: controller)
            return false
        }

        guard isCurrentStartingGeneration(generation), !Task.isCancelled else {
            cancelStart(generation: generation)
            return false
        }
        controllerStartRequestedGeneration = generation
        controller.startPictureInPicture()
        pipLog.notice("start requested generation=\(generation, privacy: .public)")
        do {
            try await waitUntilPictureInPictureIsActive(controller, generation: generation)
        } catch is CancellationError {
            cancelStart(generation: generation)
            pipLog.debug("start cancelled while waiting for PiP activation")
            return false
        } catch {
            cancelStart(generation: generation)
            pipLog.error("start activation wait failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard isCurrentController(controller, generation: generation),
              operationState == .starting(generation) || operationState == .active(generation),
              controller.isPictureInPictureActive
        else {
            pipLog.notice("start rejected: PiP did not become active")
            lastErrorMessage = NSLocalizedString(
                "Picture in Picture is still starting.",
                comment: "PiP activation timeout status"
            )
            statusMessage = lastErrorMessage ?? ""
            beginStopping(
                generation: generation,
                controller: controller,
                terminalAcknowledged: false,
                preserveStatus: true
            )
            return false
        }
        operationState = .active(generation)
        refreshCapability()
        return true
    }

    func stop() {
        switch operationState {
        case .starting(let generation), .active(let generation):
            beginStopping(
                generation: generation,
                controller: currentController(for: generation),
                terminalAcknowledged: controllerStartRequestedGeneration != generation,
                preserveStatus: false
            )
        case .stopping(let generation):
            currentController(for: generation)?.stopPictureInPicture()
        case .idle:
            startFlight?.task.cancel()
            if let controller = pictureInPictureController {
                if controller.isPictureInPictureActive {
                    let generation = controllerGeneration ?? nextOperationGeneration()
                    controllerGeneration = generation
                    operationState = .active(generation)
                    beginStopping(
                        generation: generation,
                        controller: controller,
                        terminalAcknowledged: false,
                        preserveStatus: false
                    )
                } else {
                    controller.stopPictureInPicture()
                    retireController(controller, generation: controllerGeneration)
                }
            }
            isActive = false
            stopContentUpdatesIfIdle()
            refreshCapability()
        }
    }

    /// Requests stop and waits only for a bounded caller-facing interval. A
    /// timeout leaves the coordinator in `.stopping` with the original
    /// controller retained, so a new controller can never overlap an AVKit
    /// session that still reports itself active.
    func stopAndWait(timeout: TimeInterval = 4.0) async -> Bool {
        stop()
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while Date() < deadline {
            guard !Task.isCancelled else { return false }
            if operationState == .idle {
                return pictureInPictureController?.isPictureInPictureActive != true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return operationState == .idle
            && pictureInPictureController?.isPictureInPictureActive != true
    }

    func refreshCapability() {
        isSupported = AVPictureInPictureController.isPictureInPictureSupported()
        isPossible = pictureInPictureController?.isPictureInPicturePossible ?? false
        if case .active(let generation) = operationState,
           let controller = currentController(for: generation) {
            isActive = controller.isPictureInPictureActive
        } else {
            isActive = false
        }
        if isActive {
            statusMessage = NSLocalizedString("Picture in Picture is active.", comment: "PiP active status")
        } else if case .stopping(let generation) = operationState {
            if preserveStopStatusGeneration != generation {
                statusMessage = NSLocalizedString("Picture in Picture stopped.", comment: "PiP stopped status")
            }
        } else if isPossible {
            statusMessage = NSLocalizedString("Picture in Picture is ready.", comment: "PiP ready status")
        } else if isSupported {
            statusMessage = NSLocalizedString("Picture in Picture is preparing.", comment: "PiP preparing status")
        } else {
            statusMessage = NSLocalizedString("Picture in Picture is not supported on this device.", comment: "PiP unsupported status")
        }
    }

    private func nextOperationGeneration() -> UInt64 {
        operationGeneration &+= 1
        if operationGeneration == 0 {
            operationGeneration = 1
        }
        return operationGeneration
    }

    private func awaitStartFlight(_ flight: StartFlight) async -> Bool {
        let generation = flight.generation
        let result = await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelStart(generation: generation)
            }
        }
        if startFlight?.generation == generation {
            startFlight = nil
        }
        if operationState == .starting(generation) {
            failUnstartedGeneration(generation, controller: currentController(for: generation))
        }
        return !Task.isCancelled && result
    }

    private func cancelStart(generation: UInt64) {
        guard operationState == .starting(generation) else { return }
        beginStopping(
            generation: generation,
            controller: currentController(for: generation),
            terminalAcknowledged: controllerStartRequestedGeneration != generation,
            preserveStatus: false
        )
    }

    /// Stop owns the pending start task and the controller generation. A new
    /// start cannot allocate another controller until both the task and AVKit's
    /// terminal callback (or the bounded timeout) have settled.
    private func beginStopping(
        generation: UInt64,
        controller: AVPictureInPictureController?,
        terminalAcknowledged: Bool,
        preserveStatus: Bool
    ) {
        guard operationState.generation == generation
            || (operationState == .idle && startFlight?.generation == generation)
        else { return }

        if preserveStatus {
            preserveStopStatusGeneration = generation
        }
        if terminalAcknowledged || controllerStartRequestedGeneration != generation {
            stopAcknowledgedGeneration = generation
        }
        if startFlight?.generation == generation {
            startFlight?.task.cancel()
        }
        controller?.stopPictureInPicture()

        if operationState == .stopping(generation), stopFlight?.generation == generation {
            return
        }
        operationState = .stopping(generation)
        isActive = false
        let pendingStartTask = startFlight?.generation == generation ? startFlight?.task : nil
        let task = Task { @MainActor [weak self] in
            if let pendingStartTask {
                _ = await pendingStartTask.value
            }
            await self?.finishStopWhenSettled(generation: generation, controller: controller)
        }
        stopFlight = StopFlight(generation: generation, task: task)
        pipLog.notice("stop requested generation=\(generation, privacy: .public)")
    }

    private func finishStopWhenSettled(
        generation: UInt64,
        controller: AVPictureInPictureController?
    ) async {
        while operationState == .stopping(generation) {
            let deadline = Date().addingTimeInterval(Self.startupActivationTimeout)
            while stopAcknowledgedGeneration != generation, Date() < deadline {
                // Cleanup may be spawned by an already-cancelled start. Use an
                // independent delay so cancellation cannot turn this into a tight
                // main-actor loop while AVKit settles its asynchronous stop.
                await Task.detached(priority: .utility) {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }.value
            }
            guard operationState == .stopping(generation) else { break }
            if stopAcknowledgedGeneration != generation,
               controller?.isPictureInPictureActive == true {
                // AVKit still owns an active system PiP. Keep the controller
                // and generation in `.stopping`; retiring it here would let a
                // new controller overlap the old session.
                pipLog.notice("stop acknowledgement timed out while controller remains active generation=\(generation, privacy: .public)")
                controller?.stopPictureInPicture()
                continue
            }
            if stopAcknowledgedGeneration != generation {
                pipLog.notice("stop callback timed out after controller became inactive generation=\(generation, privacy: .public)")
            }
            completeCoordinatedStop(generation: generation, controller: controller)
            return
        }
        if stopFlight?.generation == generation {
            stopFlight = nil
        }
    }

    private func completeCoordinatedStop(
        generation: UInt64,
        controller: AVPictureInPictureController?
    ) {
        guard operationState == .stopping(generation) else { return }
        controller?.stopPictureInPicture()
        if let controller {
            retireController(controller, generation: generation)
        } else if controllerGeneration == generation {
            resetControllerStorage()
        }
        if startFlight?.generation == generation {
            startFlight = nil
        }
        if stopFlight?.generation == generation {
            stopFlight = nil
        }
        if controllerStartRequestedGeneration == generation {
            controllerStartRequestedGeneration = nil
        }
        if stopAcknowledgedGeneration == generation {
            stopAcknowledgedGeneration = nil
        }
        let preservesStatus = preserveStopStatusGeneration == generation
        if preservesStatus {
            preserveStopStatusGeneration = nil
        }
        operationState = .idle
        isActive = false
        isPossible = false
        if !preservesStatus {
            statusMessage = NSLocalizedString("Picture in Picture stopped.", comment: "PiP stopped status")
        }
        stopContentUpdatesIfIdle()
    }

    private func failUnstartedGeneration(
        _ generation: UInt64,
        controller: AVPictureInPictureController?
    ) {
        guard operationState == .starting(generation) else { return }
        if let controller {
            retireController(controller, generation: generation)
        }
        operationState = .idle
        isActive = false
        isPossible = false
        stopContentUpdatesIfIdle()
    }

    private func waitForSourceView(generation: UInt64) async throws -> UIView? {
        try Task.checkCancellation()
        guard isCurrentStartingGeneration(generation) else { throw CancellationError() }
        if let sourceView, isReadySourceView(sourceView) {
            return sourceView
        }

        let deadline = Date().addingTimeInterval(Self.startupSourceViewTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            guard isCurrentStartingGeneration(generation) else { throw CancellationError() }
            if let sourceView, isReadySourceView(sourceView) {
                return sourceView
            }
            try await Task.sleep(nanoseconds: Self.startupReadinessPollInterval)
        }
        try Task.checkCancellation()
        guard isCurrentStartingGeneration(generation) else { throw CancellationError() }
        return sourceView.flatMap { isReadySourceView($0) ? $0 : nil }
    }

    private func isReadySourceView(_ view: UIView) -> Bool {
        view.window != nil
            && view.bounds.width >= 1
            && view.bounds.height >= 1
    }

    private func waitUntilPictureInPictureIsPossible(
        _ controller: AVPictureInPictureController,
        generation: UInt64
    ) async throws {
        let deadline = Date().addingTimeInterval(Self.startupReadinessTimeout)
        while !controller.isPictureInPicturePossible, Date() < deadline {
            try Task.checkCancellation()
            guard isCurrentController(controller, generation: generation),
                  operationState == .starting(generation)
            else { throw CancellationError() }
            updateContentView()
            refreshCapability()
            try await Task.sleep(nanoseconds: Self.startupReadinessPollInterval)
        }
        try Task.checkCancellation()
        guard isCurrentController(controller, generation: generation),
              operationState == .starting(generation)
        else { throw CancellationError() }
        updateContentView()
        refreshCapability()
    }

    private func waitUntilPictureInPictureIsActive(
        _ controller: AVPictureInPictureController,
        generation: UInt64
    ) async throws {
        let deadline = Date().addingTimeInterval(Self.startupActivationTimeout)
        while !controller.isPictureInPictureActive, Date() < deadline {
            try Task.checkCancellation()
            guard isCurrentController(controller, generation: generation),
                  operationState == .starting(generation) || operationState == .active(generation)
            else { throw CancellationError() }
            refreshCapability()
            try await Task.sleep(nanoseconds: Self.startupReadinessPollInterval)
        }
        try Task.checkCancellation()
        guard isCurrentController(controller, generation: generation),
              operationState == .starting(generation) || operationState == .active(generation)
        else { throw CancellationError() }
        refreshCapability()
    }

    private func ensureController(
        for sourceView: UIView,
        generation: UInt64
    ) -> AVPictureInPictureController {
        if let pictureInPictureController, controllerGeneration == generation {
            return pictureInPictureController
        }
        if let pictureInPictureController {
            pictureInPictureController.stopPictureInPicture()
            retireController(pictureInPictureController, generation: controllerGeneration)
        }

        let contentViewController = ensureContentViewController()
        PiPDictationLayout.applyPreferredSize(to: sourceView)
        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: contentViewController
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        pictureInPictureController = controller
        controllerGeneration = generation
        return controller
    }

    private func isCurrentStartingGeneration(_ generation: UInt64) -> Bool {
        operationState == .starting(generation)
    }

    private func currentController(for generation: UInt64) -> AVPictureInPictureController? {
        guard controllerGeneration == generation else { return nil }
        return pictureInPictureController
    }

    private func isCurrentController(
        _ controller: AVPictureInPictureController,
        generation: UInt64
    ) -> Bool {
        controllerGeneration == generation && pictureInPictureController === controller
    }

    private func currentControllerGeneration(
        for controller: AVPictureInPictureController
    ) -> UInt64? {
        guard pictureInPictureController === controller else { return nil }
        return controllerGeneration
    }

    private func ensureContentViewController() -> AVPictureInPictureVideoCallViewController {
        if let contentViewController {
            return contentViewController
        }

        let viewController = AVPictureInPictureVideoCallViewController()
        configurePreferredContentSize(for: viewController)
        viewController.view.backgroundColor = .black
        viewController.view.clipsToBounds = true

        let contentView = PiPVideoCallContentView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        viewController.view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: viewController.view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor),
        ])

        self.contentViewController = viewController
        self.contentView = contentView
        updateContentView()
        return viewController
    }

    private func configurePreferredContentSize(for viewController: AVPictureInPictureVideoCallViewController) {
        let size = PiPDictationLayout.preferredContentSize
        viewController.preferredContentSize = size
        viewController.view.bounds = CGRect(origin: .zero, size: size)
        viewController.view.frame = CGRect(origin: .zero, size: size)
    }

    private func resetInactiveController() {
        guard operationState == .idle,
              pictureInPictureController?.isPictureInPictureActive != true
        else { return }
        if let controller = pictureInPictureController {
            controller.delegate = nil
        }
        resetControllerStorage()
    }

    private func retireController(
        _ controller: AVPictureInPictureController,
        generation: UInt64?
    ) {
        guard pictureInPictureController === controller else { return }
        if let generation, controllerGeneration != generation {
            return
        }
        controller.delegate = nil
        resetControllerStorage()
    }

    private func resetControllerStorage() {
        pictureInPictureController = nil
        controllerGeneration = nil
        contentViewController = nil
        contentView = nil
        isPossible = false
        isActive = false
    }

    private func startContentUpdates() {
        guard contentUpdateTask == nil else { return }
        contentUpdateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.updateContentView()
                do {
                    try await Task.sleep(nanoseconds: Self.contentUpdateInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func stopContentUpdatesIfIdle() {
        guard pictureInPictureController?.isPictureInPictureActive != true else { return }
        contentUpdateTask?.cancel()
        contentUpdateTask = nil
    }

    private func updateContentView() {
        contentView?.configure(
            presentation: presentation,
            audioLevel: max(0, min(1, CGFloat(audioLevelProvider?() ?? 0)))
        )
    }
}

extension PiPDictationCoordinator: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        let reference = PiPControllerReference(controller: controller)
        Task { @MainActor [weak self] in
            self?.handleDidStart(controller: reference.controller)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        let reference = PiPControllerReference(controller: controller)
        Task { @MainActor [weak self] in
            self?.handleDidStop(controller: reference.controller)
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        let reference = PiPControllerReference(controller: controller)
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.handleFailedToStart(controller: reference.controller, message: message)
        }
    }

    nonisolated func pictureInPictureController(
        _: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        pipLog.notice("delegate restore requested; declining host restore")
        completionHandler(false)
    }

}

private extension PiPDictationCoordinator {
    func handleDidStart(controller: AVPictureInPictureController) {
        guard let generation = currentControllerGeneration(for: controller) else {
            pipLog.debug("ignored stale delegate didStart")
            return
        }
        switch operationState {
        case .starting(generation):
            pipLog.notice("delegate didStart generation=\(generation, privacy: .public)")
            operationState = .active(generation)
            isActive = true
            statusMessage = NSLocalizedString("Picture in Picture is active.", comment: "PiP active status")
            startContentUpdates()
        case .stopping(generation):
            pipLog.notice("delegate didStart after stop generation=\(generation, privacy: .public)")
            currentController(for: generation)?.stopPictureInPicture()
        default:
            pipLog.debug("ignored out-of-state delegate didStart generation=\(generation, privacy: .public)")
        }
    }

    func handleDidStop(controller: AVPictureInPictureController) {
        guard let generation = currentControllerGeneration(for: controller) else {
            pipLog.debug("ignored stale delegate didStop")
            return
        }
        switch operationState {
        case .stopping(generation):
            pipLog.notice("delegate didStop generation=\(generation, privacy: .public)")
            stopAcknowledgedGeneration = generation
            isActive = false
            if preserveStopStatusGeneration != generation {
                statusMessage = NSLocalizedString("Picture in Picture stopped.", comment: "PiP stopped status")
            }
            stopContentUpdatesIfIdle()

        case .active(generation):
            pipLog.notice("delegate user didStop generation=\(generation, privacy: .public)")
            isActive = false
            statusMessage = NSLocalizedString("Picture in Picture stopped.", comment: "PiP stopped status")
            stopAcknowledgedGeneration = generation
            onDidStop?()
            beginStopping(
                generation: generation,
                controller: currentController(for: generation),
                terminalAcknowledged: true,
                preserveStatus: false
            )

        case .starting(generation):
            pipLog.notice("delegate didStop during start generation=\(generation, privacy: .public)")
            stopAcknowledgedGeneration = generation
            beginStopping(
                generation: generation,
                controller: currentController(for: generation),
                terminalAcknowledged: true,
                preserveStatus: false
            )

        default:
            pipLog.debug("ignored out-of-state delegate didStop generation=\(generation, privacy: .public)")
        }
    }

    func handleFailedToStart(controller: AVPictureInPictureController, message: String) {
        guard let generation = currentControllerGeneration(for: controller) else {
            pipLog.debug("ignored stale delegate failedToStart")
            return
        }
        switch operationState {
        case .starting(generation):
            pipLog.error("delegate failedToStart generation=\(generation, privacy: .public): \(message, privacy: .public)")
            lastErrorMessage = message
            statusMessage = message
            beginStopping(
                generation: generation,
                controller: currentController(for: generation),
                terminalAcknowledged: true,
                preserveStatus: true
            )
        case .stopping(generation):
            stopAcknowledgedGeneration = generation
        default:
            pipLog.debug("ignored out-of-state delegate failedToStart generation=\(generation, privacy: .public)")
        }
    }
}

private final class PiPVideoCallContentView: UIView {
    private var presentation = PiPDictationPresentation.ready
    private var audioLevel: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(presentation: PiPDictationPresentation, audioLevel: CGFloat) {
        self.presentation = presentation
        self.audioLevel = audioLevel
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        if rect.width >= rect.height * 1.25 {
            drawLandscape(in: rect)
            return
        }
        drawSquare(in: rect)
    }

    private func drawLandscape(in rect: CGRect) {
        let width = max(1, rect.width)
        let height = max(1, rect.height)
        let scale = max(0.5, min(width / 128, height / 72))

        UIColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1).setFill()
        UIBezierPath(rect: rect).fill()

        let panelRect = rect.insetBy(dx: 6 * scale, dy: 5 * scale)
        UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1).setFill()
        UIBezierPath(roundedRect: panelRect, cornerRadius: 14 * scale).fill()

        drawVoiceMark(
            in: CGRect(
                x: panelRect.minX + 8 * scale,
                y: panelRect.midY - 19 * scale,
                width: 32 * scale,
                height: 38 * scale
            ),
            level: audioLevel
        )

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 14 * scale, weight: .bold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
        ]
        let stateAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 11 * scale, weight: .semibold),
            .foregroundColor: UIColor(red: 0.18, green: 0.72, blue: 1, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        let tapAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(6.5, 7.5 * scale), weight: .medium),
            .foregroundColor: UIColor(white: 0.58, alpha: 1),
            .paragraphStyle: paragraph,
        ]

        let textX = panelRect.minX + 48 * scale
        let textWidth = max(1, panelRect.maxX - textX - 7 * scale)
        (presentation.title as NSString).draw(
            in: CGRect(x: textX, y: panelRect.minY + 9 * scale, width: textWidth, height: 17 * scale),
            withAttributes: titleAttributes
        )
        (currentStateText() as NSString).draw(
            in: CGRect(x: textX, y: panelRect.minY + 29 * scale, width: textWidth, height: 14 * scale),
            withAttributes: stateAttributes
        )
        (NSLocalizedString("Tap to close", comment: "PiP tap-to-close hint") as NSString).draw(
            in: CGRect(x: textX, y: panelRect.maxY - 16 * scale, width: textWidth, height: 10 * scale),
            withAttributes: tapAttributes
        )
    }

    private func drawSquare(in rect: CGRect) {
        let side = max(1, min(rect.width, rect.height))
        let contentRect = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
        let scale = side / 180

        UIColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1).setFill()
        UIBezierPath(rect: rect).fill()

        let panelInset = 12 * scale
        let panelRect = contentRect.insetBy(dx: panelInset, dy: panelInset)
        UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1).setFill()
        UIBezierPath(roundedRect: panelRect, cornerRadius: 20 * scale).fill()

        drawVoiceMark(
            in: CGRect(
                x: panelRect.midX - 32 * scale,
                y: panelRect.minY + 19 * scale,
                width: 64 * scale,
                height: 42 * scale
            ),
            level: audioLevel
        )

        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.alignment = .center
        titleParagraph.lineBreakMode = .byTruncatingTail
        let statusParagraph = NSMutableParagraphStyle()
        statusParagraph.alignment = .center
        statusParagraph.lineBreakMode = .byTruncatingTail

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 20 * scale, weight: .bold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: titleParagraph,
        ]
        let stateAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 13.5 * scale, weight: .semibold),
            .foregroundColor: UIColor(red: 0.18, green: 0.72, blue: 1, alpha: 1),
            .paragraphStyle: statusParagraph,
        ]
        let tapAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(8, 9.5 * scale), weight: .medium),
            .foregroundColor: UIColor(white: 0.58, alpha: 1),
            .paragraphStyle: statusParagraph,
        ]

        (presentation.title as NSString).draw(
            in: CGRect(x: panelRect.minX + 10 * scale, y: panelRect.minY + 57 * scale, width: panelRect.width - 20 * scale, height: 24 * scale),
            withAttributes: titleAttributes
        )
        (currentStateText() as NSString).draw(
            in: CGRect(x: panelRect.minX + 12 * scale, y: panelRect.minY + 84 * scale, width: panelRect.width - 24 * scale, height: 20 * scale),
            withAttributes: stateAttributes
        )
        (NSLocalizedString("Tap to close", comment: "PiP tap-to-close hint") as NSString).draw(
            in: CGRect(x: panelRect.minX + 12 * scale, y: panelRect.maxY - 23 * scale, width: panelRect.width - 24 * scale, height: 15 * scale),
            withAttributes: tapAttributes
        )
    }

    private func drawVoiceMark(in rect: CGRect, level: CGFloat) {
        let centerY = rect.midY
        let barCount = 5
        let spacing = max(3, rect.width * 0.08)
        let barWidth = max(4, (rect.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
        let maxHeight = rect.height
        let baseHeight = min(16, rect.height * 0.45)
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let startX = rect.minX + (rect.width - totalWidth) / 2
        UIColor(red: 0.05, green: 0.55, blue: 1, alpha: 1).setFill()
        for index in 0..<barCount {
            let phase = CGFloat(index) / CGFloat(barCount - 1)
            let multiplier = 0.45 + 0.55 * sin((phase * .pi) + .pi / 6)
            let height = baseHeight + (maxHeight - baseHeight) * level * multiplier
            let x = startX + CGFloat(index) * (barWidth + spacing)
            let barRect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
            UIBezierPath(roundedRect: barRect, cornerRadius: barWidth / 2).fill()
        }
    }

    private func currentStateText() -> String {
        guard presentation.isRecording, let startedAt = presentation.recordingStartedAt else {
            return presentation.stateLabel
        }
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        return "\(presentation.stateLabel) \(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
    }
}

final class PiPSourceUIView: UIView {
    static var preferredContentSize: CGSize {
        PiPDictationLayout.preferredContentSize
    }

    override init(frame: CGRect) {
        let initialFrame = frame.isEmpty
            ? CGRect(origin: .zero, size: PiPDictationLayout.preferredContentSize)
            : frame
        super.init(frame: initialFrame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        PiPDictationLayout.applyPreferredSize(to: self)
    }

    override var intrinsicContentSize: CGSize {
        PiPDictationLayout.preferredContentSize
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct PiPSourceViewHost: UIViewRepresentable {
    static var preferredContentSize: CGSize {
        PiPSourceUIView.preferredContentSize
    }

    @Environment(AppState.self) private var state

    func makeUIView(context _: Context) -> PiPSourceUIView {
        let view = PiPSourceUIView(frame: CGRect(origin: .zero, size: Self.preferredContentSize))
        state.attachPiPSourceView(view)
        return view
    }

    func updateUIView(_ uiView: PiPSourceUIView, context _: Context) {
        PiPDictationLayout.applyPreferredSize(to: uiView)
        state.attachPiPSourceView(uiView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView _: PiPSourceUIView,
        context _: Context
    ) -> CGSize? {
        Self.preferredContentSize
    }
}
