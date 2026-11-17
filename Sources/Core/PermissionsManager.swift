import AVFoundation
import AppKit
import ApplicationServices
import IOKit.hid

public struct Permissions: Equatable {
    public let microphone: Bool
    public let accessibility: Bool
    public let inputMonitoring: Bool
    public let documentsAccess: Bool
    public var allGranted: Bool { microphone && accessibility && inputMonitoring }
    public init(microphone: Bool, accessibility: Bool, inputMonitoring: Bool, documentsAccess: Bool) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
        self.documentsAccess = documentsAccess
    }
}

/// Why a transcript was not typed, in the HUD's two short lines. Each case keeps
/// the transcript in history.
public enum NotTypedReason: Equatable {
    case secureField
    case noFocusedInput
    /// Accessibility was revoked: the inserter can't see any focused field.
    case accessibilityOff

    /// The inserter's "no focus". Without Accessibility every insertion ends there, so
    /// the HUD names that instead of the focused app.
    public static func noFocus(accessibilityTrusted: Bool) -> NotTypedReason {
        accessibilityTrusted ? .noFocusedInput : .accessibilityOff
    }

    public var title: String {
        switch self {
        case .secureField:      return "Skipped password field"
        case .noFocusedInput:   return "No focused input"
        case .accessibilityOff: return "Accessibility is off"
        }
    }

    /// "Saved to history" doesn't fit next to the instruction for Accessibility.
    public var detail: String {
        switch self {
        case .secureField, .noFocusedInput: return "Transcript saved to history"
        case .accessibilityOff:             return "Turn HoldSpeak on in Privacy & Security → Accessibility"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .secureField:      return "lock.fill"
        case .noFocusedInput:   return "text.cursor"
        case .accessibilityOff: return "exclamationmark.triangle.fill"
        }
    }
}

public final class PermissionsManager {
    public static let shared = PermissionsManager()
    private init() {}

    public func current() -> Permissions {
        Permissions(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
            documentsAccess: checkDocumentsAccessPassively()
        )
    }

    public func requestMicrophone() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
    }

    /// What the onboarding Microphone row does when clicked.
    public enum MicrophoneAction: Equatable { case prompt, openSettings }

    /// macOS shows its prompt only while the choice is undecided; once denied (or
    /// restricted), `requestAccess` answers false without a prompt, so the row has to
    /// send the user to System Settings instead.
    public static func microphoneAction(for status: AVAuthorizationStatus) -> MicrophoneAction {
        status == .notDetermined ? .prompt : .openSettings
    }

    public var microphoneAction: MicrophoneAction {
        Self.microphoneAction(for: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    public func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    public func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    public func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    /// Triggers the macOS TCC prompt for `~/Documents` (only on first call).
    /// If already decided, returns the current status without prompting.
    /// Returns `true` when the directory is readable.
    @discardableResult
    public func requestDocumentsAccess() -> Bool {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fd = open(docs.path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    public func openDocumentsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    /// Best-effort passive check — avoids triggering the TCC prompt. We rely
    /// on `access()` which returns EPERM if TCC has blocked the directory.
    private func checkDocumentsAccessPassively() -> Bool {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return access(docs.path, R_OK) == 0
    }
}
