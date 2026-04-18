import AppKit
import SwiftUI

@MainActor
final class OverlayWindow {
    private let panel: NSPanel
    private let hosting: NSHostingView<AnyView>
    private let prefs: PreferencesStore

    init(prefs: PreferencesStore = .shared, content: AnyView) {
        self.prefs = prefs
        panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 420, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        hosting = NSHostingView(rootView: content)
        hosting.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = hosting
    }

    func update(_ content: AnyView) { hosting.rootView = content }

    func show(anchor menuBarIconFrame: CGRect?) {
        reposition(anchor: menuBarIconFrame)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }

    private func reposition(anchor: CGRect?) {
        guard let screen = NSScreen.main else { return }
        let frame = panel.frame
        switch prefs.hudPosition {
        case .underMenuBarIcon:
            if let anchor {
                let x = anchor.midX - frame.width / 2
                let y = anchor.minY - frame.height - 6
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            } else {
                let vf = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: vf.maxX - frame.width - 16,
                                             y: vf.maxY - frame.height - 6))
            }
        case .bottomCenter:
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.midX - frame.width / 2,
                                         y: vf.minY + 80))
        }
    }
}
