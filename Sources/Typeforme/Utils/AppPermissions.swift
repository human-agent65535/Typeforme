import AppKit
import AVFoundation
import Foundation

enum MicrophonePermissionStatus: Equatable {
    case granted
    case notDetermined
    case denied
    case restricted
    case unknown

    static var current: MicrophonePermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    }
}

enum AppPermissions {
    static var microphoneStatus: MicrophonePermissionStatus {
        MicrophonePermissionStatus.current
    }

    static func requestMicrophone() async -> MicrophonePermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            return MicrophonePermissionStatus.current
        default:
            return MicrophonePermissionStatus.current
        }
    }

    static func openMicrophoneSettings() {
        openPrivacySettings(anchor: "Privacy_Microphone")
    }

    private static func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
