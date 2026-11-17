import CoreGraphics

/// Keyboard events HoldSpeak posts itself (typed dictation text, replayed hotkey taps)
/// carry this marker in `.eventSourceUserData`, so the hotkey tap passes them through
/// untouched: our own typing must never start, end or cancel a hold.
public enum SyntheticEvent {
    public static let marker: Int64 = 0x4853_5250_4C59 // "HSRPLY"

    public static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    public static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}
