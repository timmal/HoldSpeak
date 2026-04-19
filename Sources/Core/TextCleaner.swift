import Foundation

public enum TextCleaner {
    private struct Rule {
        let pattern: String
        let replacement: String
        let options: NSRegularExpression.Options
    }

    private static let rules: [Rule] = [
        // Only drop extended hesitation sounds (эээ, эмммм, ummm, uhhh)
        Rule(pattern: #"\b(э{3,}|м{3,}|эм{2,}|um{2,}|uh{2,}|uhm+)\b"#,
             replacement: "", options: [.caseInsensitive]),
        // Consecutive identical word repeated 3+ times (Whisper stutter)
        Rule(pattern: #"\b(\w+)(\s+\1){2,}\b"#,
             replacement: "$1", options: [.caseInsensitive]),
        // Collapse whitespace
        Rule(pattern: #"\s+"#, replacement: " ", options: []),
    ]

    public static func clean(_ input: String) -> String {
        var s = input
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: rule.replacement)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        // Capitalize first character (Unicode-safe)
        s = s.prefix(1).uppercased() + s.dropFirst()
        if let last = s.last, !".?!".contains(last) { s += "." }
        return s
    }
}
