import SwiftUI

struct OnboardingView: View {
    @State private var perms = PermissionsManager.shared.current()
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Push-to-Talk needs three permissions")
                .font(.title2).bold()
            row("Microphone", ok: perms.microphone) {
                Task {
                    _ = await PermissionsManager.shared.requestMicrophone()
                    refresh()
                }
            }
            row("Accessibility (global hotkey and text insertion)", ok: perms.accessibility) {
                PermissionsManager.shared.openAccessibilitySettings()
            }
            row("Input Monitoring", ok: perms.inputMonitoring) {
                PermissionsManager.shared.openInputMonitoringSettings()
            }
            Spacer()
            HStack {
                Button("Re-check") { refresh() }
                Spacer()
                Button("Done") { onDone() }
                    .disabled(!perms.allGranted)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 300)
    }

    private func row(_ title: String, ok: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundColor(ok ? .green : .secondary)
            Text(title)
            Spacer()
            if !ok { Button("Open…", action: action) }
        }
    }

    private func refresh() {
        perms = PermissionsManager.shared.current()
    }
}
