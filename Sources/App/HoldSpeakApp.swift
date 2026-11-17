import SwiftUI

@main
struct HoldSpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        // `App` needs a scene, and this one never shows: the app menu's Settings item
        // (⌘, while a HoldSpeak window is key) opens the real Preferences window
        // instead of an empty Settings one.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Preferences…") {
                        NotificationCenter.default.post(name: .openPreferences, object: nil)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
