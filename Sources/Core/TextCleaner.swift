import Foundation

public enum TextCleaner {
    private struct Rule {
        let pattern: String
        let replacement: String
        let options: NSRegularExpression.Options
    }

    private static let rules: [Rule] = [
        // Whisper "sound event" annotations: [музыка], [music], (applause), etc.
        Rule(pattern: #"[\[\(][^\]\)]{1,40}[\]\)]"#,
             replacement: "", options: []),
        // Only drop extended hesitation sounds (эээ, эмммм, ummm, uhhh)
        Rule(pattern: #"\b(э{3,}|м{3,}|эм{2,}|um{2,}|uh{2,}|uhm+)\b"#,
             replacement: "", options: [.caseInsensitive]),
        // Consecutive identical word repeated 3+ times (Whisper stutter)
        Rule(pattern: #"\b(\w+)(\s+\1){2,}\b"#,
             replacement: "$1", options: [.caseInsensitive]),
        // Consecutive identical short phrase (up to 5 words) repeated 2+ times.
        Rule(pattern: #"(\b[\p{L}\p{N}]+(?:\s+[\p{L}\p{N}]+){0,4}[.!?]?)(\s+\1){1,}"#,
             replacement: "$1", options: [.caseInsensitive]),
        // Collapse whitespace
        Rule(pattern: #"\s+"#, replacement: " ", options: []),
    ]

    /// Known Whisper hallucinations — typical training-data subtitle boilerplate.
    private static let hallucinations: [String] = [
        "продолжение следует",
        "спасибо за просмотр",
        "спасибо за внимание",
        "субтитры делал",
        "субтитры сделал",
        "субтитры подготовил",
        "субтитры by",
        "dimatorzok",
        "редактор субтитров",
        "thanks for watching",
        "thank you for watching",
        "please subscribe",
        "subscribe to",
        "like and subscribe",
    ]

    public static func clean(_ input: String) -> String {
        var s = input
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: rule.replacement)
        }
        s = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:")))
        guard !s.isEmpty else { return "" }
        if s.rangeOfCharacter(from: .alphanumerics) == nil { return "" }
        // Drop the utterance entirely if its normalized form matches a known Whisper hallucination.
        let lower = s.lowercased()
        for h in hallucinations where lower.contains(h) {
            return ""
        }
        // Capitalize first character (Unicode-safe)
        s = s.prefix(1).uppercased() + s.dropFirst()
        if let last = s.last, !".?!".contains(last) { s += "." }
        return s
    }
}
