//
//  MicPermission.swift
//  Grok-macOS
//
//  Asks macOS for microphone access once. After the user clicks Allow,
//  TCC remembers it for this app (same bundle ID + signature).
//

import AppKit
import AVFoundation
import Speech

enum MicPermission {
    static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var label: String {
        switch status {
        case .authorized: return "Allowed"
        case .denied, .restricted: return "Denied"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    /// No prompt if already decided. Shows the system sheet only once.
    static func request() {
        guard status == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    static func request() async -> Bool {
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    static func openSystemSettings() {
        openPrivacyPane("Privacy_Microphone")
    }
}

enum SpeechPermission {
    static var status: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    static var label: String {
        switch status {
        case .authorized: return "Allowed"
        case .denied, .restricted: return "Denied"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    static func request() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = status
        if current != .notDetermined { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    static func openSystemSettings() {
        openPrivacyPane("Privacy_SpeechRecognition")
    }
}

private func openPrivacyPane(_ anchor: String) {
    let urls = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
        "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
    ]
    for raw in urls {
        if let url = URL(string: raw) {
            NSWorkspace.shared.open(url)
            return
        }
    }
}
