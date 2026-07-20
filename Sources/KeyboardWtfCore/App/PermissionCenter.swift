import AppKit
import Combine
import AVFoundation
import CoreGraphics
import Foundation

public struct PermissionRecord: Identifiable, Equatable, Sendable {
    public let kind: PermissionKind
    public let status: PermissionStatus
    public let detail: String
    public let checkedAt: Date
    public var id: String { kind.rawValue }
}

@MainActor
public final class PermissionCenter: ObservableObject {
    @Published public private(set) var records = [PermissionRecord]()
    public init() { refresh() }
    public func refresh() {
        let microphone: PermissionStatus
        switch AVCaptureDevice.authorizationStatus(for: .audio) { case .authorized: microphone = .authorized; case .denied: microphone = .denied; case .restricted: microphone = .restricted; case .notDetermined: microphone = .notDetermined; @unknown default: microphone = .unknown }
        let accessibility: PermissionStatus = AXIsProcessTrusted() ? .authorized : .denied
        let camera: PermissionStatus
        switch AVCaptureDevice.authorizationStatus(for: .video) { case .authorized: camera = .authorized; case .denied: camera = .denied; case .restricted: camera = .restricted; case .notDetermined: camera = .notDetermined; @unknown default: camera = .unknown }
        let now = Date()
        let screenRecording: PermissionStatus = CGPreflightScreenCaptureAccess() ? .authorized : .denied
        records = [
            PermissionRecord(kind: .microphone, status: microphone, detail: "Voice input for all three modes.", checkedAt: now),
            PermissionRecord(kind: .accessibility, status: accessibility, detail: "Selected-text capture, insertion, and window control.", checkedAt: now),
            PermissionRecord(kind: .screenRecording, status: screenRecording, detail: "Explicit screenshots and screen guidance only.", checkedAt: now),
            PermissionRecord(kind: .camera, status: camera, detail: "A single photo only when requested.", checkedAt: now),
            PermissionRecord(kind: .automation, status: .unknown, detail: "Limited approved automation actions.", checkedAt: now),
            PermissionRecord(kind: .filesAndFolders, status: .unknown, detail: "User-approved file search roots.", checkedAt: now),
            PermissionRecord(kind: .notifications, status: .unknown, detail: "Optional status notifications.", checkedAt: now)
        ]
    }
    public func openAccessibilitySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    public func openScreenRecordingSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
}
