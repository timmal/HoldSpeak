import AppKit
import SwiftUI

@MainActor
final class MenuBarController {
    let statusItem: NSStatusItem
    private let popover: NSPopover
    private let viewModel: PopoverViewModel

    init(viewModel: PopoverViewModel) {
        self.viewModel = viewModel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(vm: viewModel))

        if let btn = statusItem.button {
            let img: NSImage?
            if let url = Bundle.main.url(forResource: "radio", withExtension: "svg"),
               let svg = NSImage(contentsOf: url) {
                svg.size = NSSize(width: 18, height: 18)
                svg.isTemplate = true
                img = svg
            } else {
                img = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                              accessibilityDescription: "Push-to-Talk")
            }
            btn.image = img
            btn.target = self
            btn.action = #selector(togglePopover(_:))
        }
    }

    var statusItemFrame: CGRect? {
        guard let win = statusItem.button?.window, let btn = statusItem.button else { return nil }
        return win.convertToScreen(btn.convert(btn.bounds, to: nil))
    }

    func setRecording(_ active: Bool) {
        statusItem.button?.contentTintColor = active ? .systemRed : nil
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            viewModel.refresh()
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
