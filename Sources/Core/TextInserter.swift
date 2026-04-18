import ApplicationServices
import CoreGraphics

public enum InsertionResult { case inserted, skippedSecureField, noFocus }

public enum TextInserter {
    public static func insert(_ text: String) -> InsertionResult {
        guard !text.isEmpty else { return .noFocus }

        let systemElement = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let status = AXUIElementCopyAttributeValue(systemElement, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let focusedObj = focused else { return .noFocus }
        let focusedElement = focusedObj as! AXUIElement

        var role: AnyObject?
        AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &role)
        if let roleStr = role as? String, roleStr == "AXSecureTextField" {
            return .skippedSecureField
        }

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
        return .inserted
    }
}
