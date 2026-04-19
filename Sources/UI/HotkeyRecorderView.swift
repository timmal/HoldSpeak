import SwiftUI
import AppKit
import Carbon.HIToolbox

struct HotkeyRecorderView: View {
    @ObservedObject var prefs = PreferencesStore.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var previousDeviceBits: UInt64 = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(recording ? "Press a key…" : prefs.hotkey.label)
                .frame(minWidth: 160, alignment: .center)
                .padding(.vertical, 4).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(recording ? 0.2 : 0.1)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(recording ? 0.8 : 0), lineWidth: 1))
            Button(recording ? "Cancel" : "Change") { toggle() }
        }
        .onDisappear { stop() }
    }

    private func toggle() {
        if recording { stop() } else { start() }
    }

    private func start() {
        recording = true
        previousDeviceBits = UInt64(NSEvent.modifierFlags.rawValue) & 0xFFFF
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if let b = bindingFrom(event) {
                prefs.hotkey = b
                stop()
                return nil
            }
            // Swallow keys while recording so they don't reach other controls.
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
    }

    private func bindingFrom(_ event: NSEvent) -> HotkeyBinding? {
        guard let cg = event.cgEvent else { return nil }
        let flags = cg.flags.rawValue
        if event.type == .keyDown {
            // Escape alone cancels.
            if Int(event.keyCode) == kVK_Escape && (flags & HotkeyBinding.allGeneralMods) == 0 {
                stop()
                return nil
            }
            let mods = flags & HotkeyBinding.allGeneralMods
            return .key(keyCode: event.keyCode, mods: mods)
        } else {
            let current = flags & 0xFFFF
            let newBits = current & ~previousDeviceBits
            previousDeviceBits = current
            guard newBits != 0 else { return nil }
            // Pick lowest single bit.
            let bit = newBits & (~newBits + 1)
            return HotkeyBinding.modifier(deviceBit: bit)
        }
    }
}
