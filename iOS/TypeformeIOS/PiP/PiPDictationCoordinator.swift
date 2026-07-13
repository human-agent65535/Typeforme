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
    private var presentation = PiPDictationPresentation.ready

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
        guard pictureInPictureController?.isPictureInPictureActive != true else {
            refreshCapability()
            return
        }

        PiPDictationLayout.applyPreferredSize(to: view)
        sourceView = view
        resetInactiveController()
        updateContentView()
        refreshCapability()
    }

    func updatePresentation(_ next: PiPDictationPresentation) {
        guard presentation != next else { return }
        presentation = next
        updateContentView()
    }

    func refreshContentAfterInterruption() {
        updateContentView()
        contentView?.setNeedsDisplay()
        contentView?.layoutIfNeeded()
        refreshCapability()
        if isActive {
            startContentUpdates()
        }
    }

    @discardableResult
    func start() async -> Bool {
        guard isSupported else {
            pipLog.notice("start rejected: PiP unsupported")
            lastErrorMessage = NSLocalizedString(
                "Picture in Picture is not supported on this device.",
                comment: "PiP unsupported status"
            )
            statusMessage = lastErrorMessage ?? ""
            return false
        }
        let sourceView: UIView
        do {
            guard let readySourceView = try await waitForSourceView() else {
                pipLog.notice("start rejected: source view missing")
                lastErrorMessage = NSLocalizedString(
                    "Picture in Picture is still preparing.",
                    comment: "PiP source view missing status"
                )
                statusMessage = lastErrorMessage ?? ""
                return false
            }
            sourceView = readySourceView
        } catch is CancellationError {
            pipLog.debug("start cancelled while waiting for source view")
            return false
        } catch {
            pipLog.notice("start rejected: source view missing")
            return false
        }

        if let activeController = pictureInPictureController,
           activeController.isPictureInPictureActive {
            isActive = true
            statusMessage = NSLocalizedString("Picture in Picture is active.", comment: "PiP active status")
            startContentUpdates()
            return true
        }

        let controller = ensureController(for: sourceView)
        startContentUpdates()
        do {
            try await waitUntilPictureInPictureIsPossible(controller)
        } catch {
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
            stopContentUpdatesIfIdle()
            return false
        }

        guard !Task.isCancelled else {
            stopContentUpdatesIfIdle()
            return false
        }
        controller.startPictureInPicture()
        pipLog.notice("start requested")
        do {
            try await waitUntilPictureInPictureIsActive(controller)
        } catch {
            // Cancellation after the start request owns one matching stop so a
            // delayed AVKit activation cannot resurrect the cancelled attempt.
            controller.stopPictureInPicture()
            stopContentUpdatesIfIdle()
            refreshCapability()
            return false
        }
        refreshCapability()
        guard controller.isPictureInPictureActive else {
            pipLog.notice("start rejected: PiP did not become active")
            lastErrorMessage = NSLocalizedString(
                "Picture in Picture is still starting.",
                comment: "PiP activation timeout status"
            )
            statusMessage = lastErrorMessage ?? ""
            stopContentUpdatesIfIdle()
            return false
        }
        return true
    }

    func stop() {
        pictureInPictureController?.stopPictureInPicture()
        stopContentUpdatesIfIdle()
        refreshCapability()
    }

    func refreshCapability() {
        isSupported = AVPictureInPictureController.isPictureInPictureSupported()
        isPossible = pictureInPictureController?.isPictureInPicturePossible ?? false
        isActive = pictureInPictureController?.isPictureInPictureActive ?? false
        if isActive {
            statusMessage = NSLocalizedString("Picture in Picture is active.", comment: "PiP active status")
        } else if isPossible {
            statusMessage = NSLocalizedString("Picture in Picture is ready.", comment: "PiP ready status")
        } else if isSupported {
            statusMessage = NSLocalizedString("Picture in Picture is preparing.", comment: "PiP preparing status")
        } else {
            statusMessage = NSLocalizedString("Picture in Picture is not supported on this device.", comment: "PiP unsupported status")
        }
    }

    private func waitForSourceView() async throws -> UIView? {
        try Task.checkCancellation()
        if let sourceView, isReadySourceView(sourceView) {
            return sourceView
        }

        let deadline = Date().addingTimeInterval(Self.startupSourceViewTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let sourceView, isReadySourceView(sourceView) {
                return sourceView
            }
            try await Task.sleep(nanoseconds: Self.startupReadinessPollInterval)
        }
        try Task.checkCancellation()
        return sourceView.flatMap { isReadySourceView($0) ? $0 : nil }
    }

    private func isReadySourceView(_ view: UIView) -> Bool {
        view.window != nil
            && view.bounds.width >= 1
            && view.bounds.height >= 1
    }

    private func waitUntilPictureInPictureIsPossible(_ controller: AVPictureInPictureController) async throws {
        let deadline = Date().addingTimeInterval(Self.startupReadinessTimeout)
        while !controller.isPictureInPicturePossible, Date() < deadline {
            try Task.checkCancellation()
            updateContentView()
            refreshCapability()
            try await Task.sleep(nanoseconds: Self.startupReadinessPollInterval)
        }
        try Task.checkCancellation()
        updateContentView()
        refreshCapability()
    }

    private func waitUntilPictureInPictureIsActive(_ controller: AVPictureInPictureController) async throws {
        let deadline = Date().addingTimeInterval(Self.startupActivationTimeout)
        while !controller.isPictureInPictureActive, Date() < deadline {
            try Task.checkCancellation()
            refreshCapability()
            try await Task.sleep(nanoseconds: Self.startupReadinessPollInterval)
        }
        try Task.checkCancellation()
        refreshCapability()
    }

    private func ensureController(for sourceView: UIView) -> AVPictureInPictureController {
        if let pictureInPictureController {
            return pictureInPictureController
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
        return controller
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
        guard pictureInPictureController?.isPictureInPictureActive != true else { return }
        pictureInPictureController = nil
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

    private func recordLifecycle(
        _ event: String,
        fields extraFields: [String: String] = [:]
    ) {
        let controller = pictureInPictureController
        var fields: [String: String] = [
            "active": "\(controller?.isPictureInPictureActive ?? false)",
            "possible": "\(controller?.isPictureInPicturePossible ?? false)",
            "source_attached": "\(sourceView?.window != nil)",
            "content_attached": "\(contentView?.window != nil)",
        ]
        for (key, value) in extraFields {
            fields[key] = value
        }
        KeyboardDiagnosticEventLog.record(source: "host-pip", event: event, fields: fields)
    }
}

extension PiPDictationCoordinator: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_: AVPictureInPictureController) {
        Task { @MainActor in
            pipLog.notice("delegate willStart")
            self.recordLifecycle("pip_will_start")
            self.refreshContentAfterInterruption()
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_: AVPictureInPictureController) {
        Task { @MainActor in
            pipLog.notice("delegate didStart")
            self.isActive = true
            self.statusMessage = NSLocalizedString("Picture in Picture is active.", comment: "PiP active status")
            self.startContentUpdates()
            self.recordLifecycle("pip_did_start")
        }
    }

    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_: AVPictureInPictureController) {
        Task { @MainActor in
            pipLog.notice("delegate willStop")
            self.recordLifecycle("pip_will_stop")
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
        Task { @MainActor in
            pipLog.notice("delegate didStop")
            self.isActive = false
            self.statusMessage = NSLocalizedString("Picture in Picture stopped.", comment: "PiP stopped status")
            self.stopContentUpdatesIfIdle()
            self.recordLifecycle("pip_did_stop")
            self.onDidStop?()
        }
    }

    nonisolated func pictureInPictureController(
        _: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            pipLog.error("delegate failedToStart: \(error.localizedDescription, privacy: .public)")
            self.lastErrorMessage = error.localizedDescription
            self.statusMessage = error.localizedDescription
            self.stopContentUpdatesIfIdle()
            self.refreshCapability()
            self.recordLifecycle(
                "pip_failed_to_start",
                fields: ["error": error.localizedDescription]
            )
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
