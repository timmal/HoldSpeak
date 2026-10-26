import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

public enum InsertionResult { case inserted, pasted, skippedSecureField, noFocus }

public enum TextInserter {
    /// How long the target app gets to read the pasteboard before the user's contents are restored.
    static let pasteRestoreDelay: TimeInterval = 0.25

    public static func insert(_ text: String) -> InsertionResult {
        guard !text.isEmpty else { return .noFocus }

        let systemElement = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let status = AXUIElementCopyAttributeValue(systemElement, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let focusedObj = focused else {
            // Electron apps (VS Code, Slack, ...) often don't report a focused element to AX,
            // so we can't inspect the field. Secure input is the system-wide password-field signal.
            if IsSecureEventInputEnabled() { return .skippedSecureField }
            paste(text)
            return .pasted
        }
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

    /// Puts `text` on the pasteboard, sends Cmd+V, then restores what was there before.
    private static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // nspasteboard.org convention: clipboard managers skip transient items.
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
        let ourChangeCount = pasteboard.changeCount

        let source = CGEventSource(stateID: .hidSystemState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteRestoreDelay) {
            // If something else wrote to the pasteboard meanwhile (the user copied), leave it alone.
            guard pasteboard.changeCount == ourChangeCount else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    /// Deep-copies the pasteboard's items; the originals are invalidated by `clearContents()`.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }
}
