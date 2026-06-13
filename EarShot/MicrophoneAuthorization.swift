//
//  MicrophoneAuthorization.swift
//  EarShot
//

import AVFoundation

enum MicrophoneAuthorization {
    enum State {
        case unknown
        case granted
        case denied
    }

    static var currentState: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    /// Prompts the user for mic access. Returns granted/denied based on the response.
    /// If already determined, returns the existing state synchronously.
    static func request() async -> State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? .granted : .denied
        @unknown default:
            return .denied
        }
    }
}
