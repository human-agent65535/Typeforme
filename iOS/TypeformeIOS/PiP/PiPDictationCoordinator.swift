import AVFoundation
import AVKit
import CoreMedia
import SwiftUI
import UIKit

struct PiPDictationPresentation: Equatable {
    var title: String
    var detail: String
    var stateLabel: String
    var isRecording: Bool
    var recordingStartedAt: Date?

    static let ready = PiPDictationPresentation(
        title: "Typeforme",
        detail: "Ready for keyboard dictation",
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

    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var pictureInPictureController: AVPictureInPictureController?
    private var renderTask: Task<Void, Never>?
    private var presentation = PiPDictationPresentation.ready
    private var frameIndex: Int64 = 0

    private static let frameSize = CGSize(width: 640, height: 360)
    private static let frameDuration = CMTime(value: 1, timescale: 2)
    private static let frameInterval: UInt64 = 500_000_000

    func attachDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        guard displayLayer !== layer else {
            refreshCapability()
            return
        }

        displayLayer = layer
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        layer.flushAndRemoveImage()
        renderCurrentFrame()
        refreshCapability()
    }

    func updatePresentation(_ next: PiPDictationPresentation) {
        guard presentation != next else { return }
        presentation = next
        renderCurrentFrame()
    }

    @discardableResult
    func start() async -> Bool {
        guard isSupported else {
            lastErrorMessage = NSLocalizedString(
                "Picture in Picture is not supported on this device.",
                comment: "PiP unsupported status"
            )
            statusMessage = lastErrorMessage ?? ""
            return false
        }
        guard let displayLayer else {
            lastErrorMessage = NSLocalizedString(
                "Picture in Picture is still preparing.",
                comment: "PiP display layer missing status"
            )
            statusMessage = lastErrorMessage ?? ""
            return false
        }

        startRendering()
        renderCurrentFrame()
        let controller = ensureController(for: displayLayer)

        // The display layer needs at least one committed frame before PiP can
        // become possible. Give AVKit one render pass before checking.
        try? await Task.sleep(nanoseconds: 150_000_000)
        refreshCapability()

        guard controller.isPictureInPicturePossible else {
            lastErrorMessage = NSLocalizedString(
                "Picture in Picture is not available right now.",
                comment: "PiP unavailable status"
            )
            statusMessage = lastErrorMessage ?? ""
            stopRenderingIfIdle()
            return false
        }
        guard !controller.isPictureInPictureActive else {
            isActive = true
            statusMessage = NSLocalizedString("Picture in Picture is active.", comment: "PiP active status")
            return true
        }

        controller.startPictureInPicture()
        refreshCapability()
        return true
    }

    func stop() {
        pictureInPictureController?.stopPictureInPicture()
        stopRenderingIfIdle()
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

    private func ensureController(for displayLayer: AVSampleBufferDisplayLayer) -> AVPictureInPictureController {
        if let pictureInPictureController {
            return pictureInPictureController
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        pictureInPictureController = controller
        return controller
    }

    private func startRendering() {
        guard renderTask == nil else { return }
        renderTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.renderCurrentFrame()
                try? await Task.sleep(nanoseconds: Self.frameInterval)
            }
        }
    }

    private func stopRenderingIfIdle() {
        guard pictureInPictureController?.isPictureInPictureActive != true else { return }
        renderTask?.cancel()
        renderTask = nil
    }

    private func renderCurrentFrame() {
        guard let displayLayer,
              displayLayer.status != .failed,
              let sampleBuffer = makeSampleBuffer()
        else { return }

        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        } else {
            displayLayer.flush()
            displayLayer.enqueue(sampleBuffer)
        }
        refreshCapability()
    }

    private func makeSampleBuffer() -> CMSampleBuffer? {
        guard let pixelBuffer = makePixelBuffer() else { return nil }
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }

        let timestamp = CMTimeMultiply(Self.frameDuration, multiplier: Int32(frameIndex))
        frameIndex += 1
        var timing = CMSampleTimingInfo(
            duration: Self.frameDuration,
            presentationTimeStamp: timestamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            return nil
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) as? [NSMutableDictionary], let attachment = attachments.first {
            attachment[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sampleBuffer
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        let width = Int(Self.frameSize.width)
        let height = Int(Self.frameSize.height)
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        UIGraphicsPushContext(context)
        drawFrame(in: CGRect(origin: .zero, size: Self.frameSize))
        UIGraphicsPopContext()
        return pixelBuffer
    }

    private func drawFrame(in rect: CGRect) {
        UIColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1).setFill()
        UIBezierPath(rect: rect).fill()

        let panelRect = rect.insetBy(dx: 48, dy: 42)
        UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1).setFill()
        UIBezierPath(roundedRect: panelRect, cornerRadius: 34).fill()

        let level = max(0, min(1, CGFloat(audioLevelProvider?() ?? 0)))
        drawVoiceMark(in: CGRect(x: panelRect.minX + 34, y: panelRect.minY + 58, width: 96, height: 118), level: level)

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 44, weight: .bold),
            .foregroundColor: UIColor.white,
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 25, weight: .medium),
            .foregroundColor: UIColor(white: 0.74, alpha: 1),
        ]
        let stateAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 26, weight: .semibold),
            .foregroundColor: UIColor(red: 0.18, green: 0.72, blue: 1, alpha: 1),
        ]

        let textX = panelRect.minX + 154
        (presentation.title as NSString).draw(
            in: CGRect(x: textX, y: panelRect.minY + 62, width: panelRect.width - 190, height: 58),
            withAttributes: titleAttributes
        )
        (presentation.detail as NSString).draw(
            in: CGRect(x: textX, y: panelRect.minY + 124, width: panelRect.width - 190, height: 72),
            withAttributes: detailAttributes
        )

        let stateText = currentStateText()
        (stateText as NSString).draw(
            in: CGRect(x: textX, y: panelRect.maxY - 76, width: panelRect.width - 190, height: 42),
            withAttributes: stateAttributes
        )
    }

    private func drawVoiceMark(in rect: CGRect, level: CGFloat) {
        let centerY = rect.midY
        let barCount = 5
        let spacing: CGFloat = 10
        let barWidth: CGFloat = 9
        let maxHeight = rect.height
        let baseHeight: CGFloat = 32
        let startX = rect.midX - CGFloat(barCount - 1) * (barWidth + spacing) / 2
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

extension PiPDictationCoordinator: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = true
            self.statusMessage = NSLocalizedString("Picture in Picture is active.", comment: "PiP active status")
            self.startRendering()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = false
            self.statusMessage = NSLocalizedString("Picture in Picture stopped.", comment: "PiP stopped status")
            self.stopRenderingIfIdle()
            self.onDidStop?()
        }
    }

    nonisolated func pictureInPictureController(
        _: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.lastErrorMessage = error.localizedDescription
            self.statusMessage = error.localizedDescription
            self.stopRenderingIfIdle()
            self.refreshCapability()
        }
    }
}

extension PiPDictationCoordinator: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _: AVPictureInPictureController,
        setPlaying _: Bool
    ) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(value: Int64.max / 2, timescale: 1))
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _: AVPictureInPictureController,
        didTransitionToRenderSize _: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _: AVPictureInPictureController,
        skipByInterval _: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _: AVPictureInPictureController
    ) -> Bool {
        false
    }
}

final class PiPDisplayLayerUIView: UIView {
    override static var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }
}

struct PiPDisplayLayerHost: UIViewRepresentable {
    @Environment(AppState.self) private var state

    func makeUIView(context _: Context) -> PiPDisplayLayerUIView {
        let view = PiPDisplayLayerUIView()
        view.isUserInteractionEnabled = false
        state.attachPiPDisplayLayer(view.sampleBufferDisplayLayer)
        return view
    }

    func updateUIView(_ uiView: PiPDisplayLayerUIView, context _: Context) {
        state.attachPiPDisplayLayer(uiView.sampleBufferDisplayLayer)
    }
}
