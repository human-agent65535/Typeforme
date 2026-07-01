import AVKit
import OSLog
import SwiftUI
import UIKit

private let pipLog = Logger(subsystem: TypeformeBundleConfiguration.hostBundleIdentifier, category: "pip")

private enum PiPDictationLayout {
    static let preferredContentSize = CGSize(width: 70, height: 70)
}

struct PiPDictationPresentation: Equatable {
    var title: String
    var detail: String
    var stateLabel: String
    var isRecording: Bool
    var recordingStartedAt: Date?

    static let ready = PiPDictationPresentation(
        title: "Typeforme",
        detail: "Ready for dictation",
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
        guard let sourceView = await waitForSourceView() else {
            pipLog.notice("start rejected: source view missing")
            lastErrorMessage = NSLocalizedString(
                "Picture in Picture is still preparing.",
                comment: "PiP source view missing status"
            )
            statusMessage = lastErrorMessage ?? ""
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
        await waitUntilPictureInPictureIsPossible(controller)
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

        controller.startPictureInPicture()
        pipLog.notice("start requested")
        refreshCapability()
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

    private func waitForSourceView() async -> UIView? {
        if let sourceView, isReadySourceView(sourceView) {
            return sourceView
        }

        let deadline = Date().addingTimeInterval(Self.startupSourceViewTimeout)
        while Date() < deadline {
            if let sourceView, isReadySourceView(sourceView) {
                return sourceView
            }
            try? await Task.sleep(nanoseconds: Self.startupReadinessPollInterval)
        }
        return sourceView.flatMap { isReadySourceView($0) ? $0 : nil }
    }

    private func isReadySourceView(_ view: UIView) -> Bool {
        view.window != nil
            && view.bounds.width >= 1
            && view.bounds.height >= 1
    }

    private func waitUntilPictureInPictureIsPossible(_ controller: AVPictureInPictureController) async {
        let deadline = Date().addingTimeInterval(Self.startupReadinessTimeout)
        while !controller.isPictureInPicturePossible, Date() < deadline {
            updateContentView()
            refreshCapability()
            try? await Task.sleep(nanoseconds: Self.startupReadinessPollInterval)
        }
        updateContentView()
        refreshCapability()
    }

    private func ensureController(for sourceView: UIView) -> AVPictureInPictureController {
        if let pictureInPictureController {
            return pictureInPictureController
        }

        let contentViewController = ensureContentViewController()
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
        viewController.preferredContentSize = PiPDictationLayout.preferredContentSize
        viewController.view.bounds = CGRect(origin: .zero, size: PiPDictationLayout.preferredContentSize)
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
                try? await Task.sleep(nanoseconds: Self.contentUpdateInterval)
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
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_: AVPictureInPictureController) {
        Task { @MainActor in
            pipLog.notice("delegate didStart")
            self.isActive = true
            self.statusMessage = NSLocalizedString("Picture in Picture is active.", comment: "PiP active status")
            self.startContentUpdates()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
        Task { @MainActor in
            pipLog.notice("delegate didStop")
            self.isActive = false
            self.statusMessage = NSLocalizedString("Picture in Picture stopped.", comment: "PiP stopped status")
            self.stopContentUpdatesIfIdle()
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
        let detailParagraph = NSMutableParagraphStyle()
        detailParagraph.alignment = .center
        detailParagraph.lineBreakMode = .byTruncatingTail

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 20 * scale, weight: .bold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: titleParagraph,
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10.5 * scale, weight: .medium),
            .foregroundColor: UIColor(white: 0.74, alpha: 1),
            .paragraphStyle: detailParagraph,
        ]
        let stateAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 13.5 * scale, weight: .semibold),
            .foregroundColor: UIColor(red: 0.18, green: 0.72, blue: 1, alpha: 1),
            .paragraphStyle: detailParagraph,
        ]
        let tapAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(8, 9.5 * scale), weight: .medium),
            .foregroundColor: UIColor(white: 0.58, alpha: 1),
            .paragraphStyle: detailParagraph,
        ]

        (presentation.title as NSString).draw(
            in: CGRect(x: panelRect.minX + 10 * scale, y: panelRect.minY + 53 * scale, width: panelRect.width - 20 * scale, height: 24 * scale),
            withAttributes: titleAttributes
        )
        (presentation.detail as NSString).draw(
            in: CGRect(x: panelRect.minX + 14 * scale, y: panelRect.minY + 77 * scale, width: panelRect.width - 28 * scale, height: 19 * scale),
            withAttributes: detailAttributes
        )
        (currentStateText() as NSString).draw(
            in: CGRect(x: panelRect.minX + 12 * scale, y: panelRect.minY + 98 * scale, width: panelRect.width - 24 * scale, height: 18 * scale),
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
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
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
    @Environment(AppState.self) private var state

    func makeUIView(context _: Context) -> PiPSourceUIView {
        let view = PiPSourceUIView()
        state.attachPiPSourceView(view)
        return view
    }

    func updateUIView(_ uiView: PiPSourceUIView, context _: Context) {
        state.attachPiPSourceView(uiView)
    }
}
