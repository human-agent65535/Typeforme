import AVFoundation
import SwiftUI
import UIKit

/// AVFoundation-backed QR scanner shown as a sheet from PairingView. Emits
/// the first decoded string back via `onFound`; the parent decides whether
/// to feed it into the pairing JSON parser.
///
/// The camera permission prompt is governed by NSCameraUsageDescription in
/// the host's Info.plist. If permission is denied we surface a fallback
/// message — the user can still paste the pairing JSON manually.
struct PairingQRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onFound: (String) -> Void

    @State private var permissionState: PermissionState = .checking
    @State private var lastScannedPayload: String?

    enum PermissionState {
        case checking
        case authorized
        case denied
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch permissionState {
                case .checking:
                    ProgressView()
                        .tint(.white)
                case .denied:
                    deniedOverlay
                case .authorized:
                    QRScannerRepresentable { payload in
                        guard payload != lastScannedPayload else { return }
                        lastScannedPayload = payload
                        onFound(payload)
                        dismiss()
                    }
                    .ignoresSafeArea()

                    cornerReticle
                }
            }
            .navigationTitle("Scan pairing QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(.white)
                }
            }
            .task {
                await refreshPermission()
            }
        }
    }

    private var cornerReticle: some View {
        // Four L-shaped corners centered on screen, ~240x240. Visual hint to
        // the user where to point the QR. Pure SwiftUI — no overlay layout
        // gymnastics needed since the camera fills the whole view.
        let size: CGFloat = 240
        return ZStack {
            ForEach(0..<4, id: \.self) { idx in
                ReticleCorner()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(Double(idx) * 90))
                    .offset(
                        x: idx == 0 || idx == 3 ? -size / 2 + 12 : size / 2 - 12,
                        y: idx == 0 || idx == 1 ? -size / 2 + 12 : size / 2 - 12
                    )
            }
        }
    }

    @ViewBuilder
    private var deniedOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.8))
            Text("Camera access denied")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Enable camera in iOS Settings to scan a pairing QR, or paste the pairing JSON manually instead.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Settings", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
        }
        .padding(.horizontal, 24)
    }

    @MainActor
    private func refreshPermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            permissionState = .authorized
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permissionState = granted ? .authorized : .denied
        case .denied, .restricted:
            permissionState = .denied
        @unknown default:
            permissionState = .denied
        }
    }
}

private struct ReticleCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// Bridge AVCaptureSession into SwiftUI. The view controller owns the
/// session lifecycle — starting it during `viewWillAppear` and tearing it
/// down on disappear so the camera light doesn't linger after dismiss.
private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(payloadHandler: QRPayloadHandler(onFound: onFound))
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.coordinator = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    @MainActor
    final class QRPayloadHandler {
        let onFound: (String) -> Void

        init(onFound: @escaping (String) -> Void) {
            self.onFound = onFound
        }

        func found(_ payload: String) {
            onFound(payload)
        }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let payloadHandler: QRPayloadHandler

        init(payloadHandler: QRPayloadHandler) {
            self.payloadHandler = payloadHandler
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard
                let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                let payload = object.stringValue,
                !payload.isEmpty
            else { return }
            Task { @MainActor [payloadHandler] in
                payloadHandler.found(payload)
            }
        }
    }

    private final class ScannerSessionController: @unchecked Sendable {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "\(TypeformeBundleConfiguration.hostBundleIdentifier).qr-scanner", qos: .userInitiated)

        func configure(coordinator: Coordinator?) -> AVCaptureDevice? {
            if session.isMultitaskingCameraAccessSupported {
                // iPad windows are resizable and may share the display with
                // another app. Opt in before the session starts so QR pairing
                // remains available in supported multitasking layouts.
                session.isMultitaskingCameraAccessEnabled = true
            }
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            guard
                let device = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else { return nil }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return nil }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(coordinator, queue: .main)
            // Adding the type AFTER addOutput, otherwise availableMetadataObjectTypes
            // is empty and the assignment is a no-op (a classic gotcha).
            output.metadataObjectTypes = [.qr]
            return device
        }

        func startIfNeeded() {
            queue.async { [weak self] in
                self?.startIfNeededOnQueue()
            }
        }

        func stop() {
            queue.async { [weak self] in
                self?.stopOnQueue()
            }
        }

        private func startIfNeededOnQueue() {
            if !session.isRunning {
                session.startRunning()
            }
        }

        private func stopOnQueue() {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    final class ScannerViewController: UIViewController {
        weak var coordinator: Coordinator?

        private let scannerSession = ScannerSessionController()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private let interruptionLabel = UILabel()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configureSession()
            configureInterruptionOverlay()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sessionWasInterrupted),
                name: AVCaptureSession.wasInterruptedNotification,
                object: scannerSession.session
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sessionInterruptionEnded),
                name: AVCaptureSession.interruptionEndedNotification,
                object: scannerSession.session
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            scannerSession.startIfNeeded()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            scannerSession.stop()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.layer.bounds
            updatePreviewRotation()
        }

        private func configureSession() {
            let device = scannerSession.configure(coordinator: coordinator)
            let preview = AVCaptureVideoPreviewLayer(session: scannerSession.session)
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            previewLayer = preview
            if let device {
                rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                    device: device,
                    previewLayer: preview
                )
            }
        }

        private func configureInterruptionOverlay() {
            interruptionLabel.translatesAutoresizingMaskIntoConstraints = false
            interruptionLabel.text = NSLocalizedString(
                "Camera is temporarily unavailable. Resize the Typeforme window or paste the pairing JSON instead.",
                comment: "QR scanner camera interruption message"
            )
            interruptionLabel.textColor = .white
            interruptionLabel.backgroundColor = UIColor.black.withAlphaComponent(0.72)
            interruptionLabel.font = .preferredFont(forTextStyle: .footnote)
            interruptionLabel.textAlignment = .center
            interruptionLabel.numberOfLines = 0
            interruptionLabel.layer.cornerRadius = 14
            interruptionLabel.layer.cornerCurve = .continuous
            interruptionLabel.clipsToBounds = true
            interruptionLabel.isHidden = true
            view.addSubview(interruptionLabel)
            NSLayoutConstraint.activate([
                interruptionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                interruptionLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                interruptionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
                interruptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
                interruptionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
                interruptionLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            ])
        }

        private func updatePreviewRotation() {
            guard
                let connection = previewLayer?.connection,
                let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview,
                connection.isVideoRotationAngleSupported(angle)
            else { return }
            connection.videoRotationAngle = angle
        }

        @objc private func sessionWasInterrupted(_ notification: Notification) {
            interruptionLabel.isHidden = false
        }

        @objc private func sessionInterruptionEnded(_ notification: Notification) {
            interruptionLabel.isHidden = true
            scannerSession.startIfNeeded()
        }
    }
}
