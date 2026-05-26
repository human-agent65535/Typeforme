import AppKit
import AVFoundation
import Foundation
import Speech

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

enum SpeechRecognitionPermissionStatus: Equatable {
    case granted
    case notDetermined
    case denied
    case restricted
    case unknown

    static var current: SpeechRecognitionPermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
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

    static var speechRecognitionStatus: SpeechRecognitionPermissionStatus {
        SpeechRecognitionPermissionStatus.current
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

    static func requestSpeechRecognition() async -> SpeechRecognitionPermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized, .denied, .restricted:
            return SpeechRecognitionPermissionStatus.current
        case .notDetermined:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume()
                }
            }
            return SpeechRecognitionPermissionStatus.current
        @unknown default:
            return SpeechRecognitionPermissionStatus.current
        }
    }

    static func openMicrophoneSettings() {
        openPrivacySettings(anchor: "Privacy_Microphone")
    }

    static func openSpeechRecognitionSettings() {
        openPrivacySettings(anchor: "Privacy_SpeechRecognition")
    }

    private static func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
