import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

public enum InsertionResult {
    case inserted
    /// No focused element could be read, so the text was typed into the frontmost app
    /// unconfirmed: nothing tells us a text field received it.
    case typedBlind
    case skippedSecureField
    case noFocus
}

/// What the inserter knows at one decision point. Plain data, so the policy is testable.
public struct InsertionFacts: Equatable {
    public enum Focus: Equatable {
        case element(role: String?, subrole: String?)
        case failed(AXError)
    }

    public struct App: Equatable {
        public var bundleID: String?
        /// `NSApplication.ActivationPolicy.regular`: a Dock app with windows, not an agent or a panel.
        public var isRegular: Bool
        public var isElectron: Bool
        public var isSelf: Bool

        public init(bundleID: String?, isRegular: Bool, isElectron: Bool, isSelf: Bool) {
            self.bundleID = bundleID; self.isRegular = isRegular; self.isElectron = isElectron; self.isSelf = isSelf
        }
    }

    public var trusted: Bool
    public var focus: Focus
    /// The frontmost application; nil when there is none.
    public var app: App?
    /// AXManualAccessibility was already set on `app`, on this insertion or an earlier one.
    public var manualAccessibilityTried: Bool
    public var secureInput: Bool

    public init(trusted: Bool, focus: Focus, app: App?, manualAccessibilityTried: Bool, secureInput: Bool) {
        self.trusted = trusted; self.focus = focus; self.app = app
        self.manualAccessibilityTried = manualAccessibilityTried; self.secureInput = secureInput
    }
}

public enum InsertionAction: Equatable {
    case typeIntoFocused
    case skipSecureField
    /// Electron builds its AX tree only when asked; ask, then query focus again.
    case enableManualAccessibility
    case typeBlind
    case noFocus
}

public enum InsertionPolicy {
    static let secureRole = "AXSecureTextField"
    static let finderBundleID = "com.apple.finder"

    public static func action(for f: InsertionFacts) -> InsertionAction {
        guard f.trusted else { return .noFocus }
        switch f.focus {
        case .element(let role, let subrole):
            // Cocoa and Chromium password fields are AXTextField with this subrole.
            return role == secureRole || subrole == secureRole ? .skipSecureField : .typeIntoFocused
        case .failed(.apiDisabled):
            return .noFocus
        case .failed:
            break
        }
        guard let app = f.app else { return .noFocus }
        if app.isElectron && !f.manualAccessibilityTried { return .enableManualAccessibility }
        // Typing blind needs a real app window to land in; Finder frontmost with nothing
        // focused is the desktop.
        guard app.isRegular, !app.isSelf, app.bundleID != finderBundleID else { return .noFocus }
        // Secure input on means some password field has the keyboard, even if AX can't see it.
        return f.secureInput ? .skipSecureField : .typeBlind
    }
}

@MainActor
public enum TextInserter {
    /// A hung app must not stall the pipeline on an AX round trip.
    static let appMessagingTimeout: Float = 0.25
    /// After AXManualAccessibility: up to 3 polls, 50 ms apart.
    static let manualAccessibilityPolls = 3
    static let manualAccessibilityPollNs: UInt64 = 50_000_000

    private struct AppKey: Hashable { let pid: pid_t; let launchDate: Date? }
    /// Apps AXManualAccessibility was set on. Once set the tree stays built, so a later miss
    /// in the same app is a real miss and doesn't pay the retry again.
    private static var manualAccessibilityApps = Set<AppKey>()

    public static func insert(_ text: String) async -> InsertionResult {
        guard !text.isEmpty else { return .noFocus }

        let running = NSWorkspace.shared.frontmostApplication
        let appElement = running.map { AXUIElementCreateApplication($0.processIdentifier) }
        if let appElement { AXUIElementSetMessagingTimeout(appElement, appMessagingTimeout) }
        let appKey = running.map { AppKey(pid: $0.processIdentifier, launchDate: $0.launchDate) }

        // System-wide first: it also sees non-activating panels (Spotlight, Raycast) that
        // aren't the frontmost app.
        var via = "system-wide"
        var (element, focus) = queryFocus(AXUIElementCreateSystemWide())
        var axErrors = [focus.errorName].compactMap { $0 }.map { "system-wide:\($0)" }
        if element == nil, let appElement {
            via = "app"
            (element, focus) = queryFocus(appElement)
            if let name = focus.errorName { axErrors.append("app:\(name)") }
        }

        var facts = InsertionFacts(
            trusted: AXIsProcessTrusted(),
            focus: focus,
            app: running.map {
                .init(bundleID: $0.bundleIdentifier,
                      isRegular: $0.activationPolicy == .regular,
                      isElectron: isElectron($0),
                      isSelf: $0.processIdentifier == getpid())
            },
            manualAccessibilityTried: appKey.map { manualAccessibilityApps.contains($0) } ?? false,
            secureInput: IsSecureEventInputEnabled()
        )
        let bundle = running?.bundleIdentifier ?? "none"

        while true {
            let action = InsertionPolicy.action(for: facts)
            switch action {
            case .enableManualAccessibility:
                guard let appElement, let appKey else { return .noFocus } // app non-nil implies both
                let setStatus = AXUIElementSetAttributeValue(
                    appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                manualAccessibilityApps.insert(appKey)
                facts.manualAccessibilityTried = true
                pttLog("insert: AXManualAccessibility on \(bundle) -> \(axErrorName(setStatus))")
                for _ in 0..<manualAccessibilityPolls {
                    // Task.sleep suspends; the main thread keeps running meanwhile.
                    try? await Task.sleep(nanoseconds: manualAccessibilityPollNs)
                    (element, facts.focus) = queryFocus(appElement)
                    if element != nil { via = "app after AXManualAccessibility"; break }
                }
                if let name = facts.focus.errorName { axErrors.append("manual:\(name)") }
                continue
            case .typeIntoFocused:
                pttLog("insert: focused via \(via) app=\(bundle)")
                type(text)
                return .inserted
            case .typeBlind:
                pttLog("insert: blind app=\(bundle) ax=\(axErrors.joined(separator: ","))")
                type(text)
                return .typedBlind
            case .skipSecureField:
                pttLog("insert: secure field app=\(bundle) via=\(element == nil ? "secure input" : via)")
                return .skippedSecureField
            case .noFocus:
                pttLog("insert: noFocus app=\(bundle) ax=\(axErrors.joined(separator: ",")) "
                       + "trusted=\(facts.trusted) regular=\(facts.app?.isRegular ?? false) "
                       + "electron=\(facts.app?.isElectron ?? false)")
                return .noFocus
            }
        }
    }

    private static func queryFocus(_ root: AXUIElement) -> (AXUIElement?, InsertionFacts.Focus) {
        var focused: AnyObject?
        let status = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let focusedObj = focused else {
            return (nil, .failed(status == .success ? .noValue : status))
        }
        let element = focusedObj as! AXUIElement
        var role: AnyObject?, subrole: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return (element, .element(role: role as? String, subrole: subrole as? String))
    }

    private static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        let framework = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    private static func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { buf in
            down?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

extension InsertionFacts.Focus {
    var errorName: String? {
        if case .failed(let error) = self { return axErrorName(error) }
        return nil
    }
}

/// Imported C enums print without their case name, so the log spells them out.
func axErrorName(_ error: AXError) -> String {
    switch error {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    @unknown default: return "AXError(\(error.rawValue))"
    }
}
