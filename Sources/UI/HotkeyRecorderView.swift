import SwiftUI
import AppKit
import Carbon.HIToolbox

struct HotkeyRecorderView: View {
    @ObservedObject var prefs = PreferencesStore.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var pressedBits: UInt64 = 0
    private static let deviceMask: UInt64 = 0x207F

    var body: some View {
        HStack(spacing: 8) {
            Text(recording ? "Press a key…" : prefs.hotkey.label)
                .frame(minWidth: 160, alignment: .center)
                .padding(.vertical, 4).padding(.horizontal, 10)
                .pttSurface(glass: Capsule(), fallback: RoundedRectangle(cornerRadius: 6),
                            fill: Color.secondary.opacity(recording ? 0.2 : 0.1),
                            border: recording ? Color.accentColor.opacity(0.8) : nil,
                            tint: recording ? Color.accentColor.opacity(0.3) : nil)
            Button(recording ? "Cancel" : "Change") { toggle() }
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if recording { stop() }
        }
    }

    private func toggle() {
        if recording { stop() } else { start() }
    }

    private func start() {
        recording = true
        HotkeyMonitor.isPaused = true
        pressedBits = 0
        // Some chords (e.g. Ctrl+`) never reach the app as NSEvents but are visible to the
        // event tap, so keyDown is also fed from there.
        HotkeyMonitor.recorderKeyDown = { keyCode, flags in
            // Cmd+Tab must reach the app switcher; cancel now, or the Cmd release
            // (still delivered to us before the switch) would record Left Command.
            if Int(keyCode) == kVK_Tab && flags & 0x00100000 != 0 {
                stop()
                return false
            }
            commit(bindingFrom(keyCode: keyCode, flags: flags, isKeyDown: true))
            return true
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if let cg = event.cgEvent {
                commit(bindingFrom(keyCode: event.keyCode, flags: cg.flags.rawValue, isKeyDown: event.type == .keyDown))
            }
            // Swallow keys while recording so they don't reach other controls.
            return nil
        }
    }

    private func commit(_ binding: HotkeyBinding?) {
        guard recording, let binding else { return }
        prefs.hotkey = binding
        stop()
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        HotkeyMonitor.isPaused = false
        HotkeyMonitor.recorderKeyDown = nil
    }

    private func bindingFrom(keyCode: UInt16, flags: UInt64, isKeyDown: Bool) -> HotkeyBinding? {
        if isKeyDown {
            // Escape alone cancels.
            if Int(keyCode) == kVK_Escape && (flags & HotkeyBinding.allGeneralMods) == 0 {
                stop()
                return nil
            }
            return .key(keyCode: keyCode, mods: flags & HotkeyBinding.allGeneralMods)
        } else {
            // Collect every modifier pressed; commit once all are released.
            let current = flags & Self.deviceMask
            pressedBits |= current
            guard current == 0, pressedBits != 0 else { return nil }
            return HotkeyBinding.modifier(deviceBits: pressedBits)
        }
    }
}
