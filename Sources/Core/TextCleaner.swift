import Foundation

public enum TextCleaner {
    private struct Rule {
        let regex: NSRegularExpression
        let replacement: String

        init(pattern: String, replacement: String, options: NSRegularExpression.Options) {
            // Patterns are literals: a compile failure is a programming error.
            regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.replacement = replacement
        }
    }

    /// Compiled once; NSRegularExpression is safe to share across threads.
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

    /// Known Whisper hallucinations on silence — typical training-data subtitle
    /// boilerplate. Matched against the whole utterance only, so the same words
    /// inside real speech ("спасибо за внимание, коллеги") are kept.
    private static let hallucinations: Set<String> = [
        "продолжение следует",
        "спасибо за просмотр",
        "спасибо за внимание",
        "спасибо",
        "спасибо большое",
        "thanks for watching",
        "thank you for watching",
        "thank you",
        "thank you very much",
        "thank you so much",
        "you",
        "bye",
        "please subscribe",
        "subscribe to the channel",
        "like and subscribe",
    ]

    /// Subtitle-credit lines ("Субтитры сделал DimaTorzok") end with a varying
    /// name, so they're matched by how the utterance starts.
    private static let hallucinationPrefixes: [String] = [
        "субтитры делал",
        "субтитры сделал",
        "субтитры создавал",
        "субтитры подготовил",
        "субтитры by",
        "редактор субтитров",
        "dimatorzok",
    ]

    private static func isHallucination(_ s: String) -> Bool {
        let normalized = s.lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return hallucinations.contains(normalized)
            || hallucinationPrefixes.contains { normalized.hasPrefix($0) }
    }

    public static func clean(
        _ input: String,
        terminology: [TerminologyEntry] = [],
        autoPunctuation: Bool = true,
        autoCapitalize: Bool = true,
        dropHallucinations: Bool = true,
        fillers: [String] = []
    ) -> String {
        var s = removeFillers(input, fillers: fillers)
        for rule in rules {
            let range = NSRange(s.startIndex..., in: s)
            s = rule.regex.stringByReplacingMatches(in: s, range: range, withTemplate: rule.replacement)
        }
        s = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:")))
        guard !s.isEmpty else { return "" }
        if s.rangeOfCharacter(from: .alphanumerics) == nil { return "" }
        // Drop the utterance entirely if its normalized form is a known Whisper hallucination.
        // Off for Gemini: it doesn't invent these on silence, so "Спасибо" is real speech.
        if dropHallucinations, isHallucination(s) { return "" }
        s = canonicalize(s, terminology: terminology)
        if autoCapitalize {
            s = s.prefix(1).uppercased() + s.dropFirst()
        } else {
            s = s.prefix(1).lowercased() + s.dropFirst()
        }
        if autoPunctuation {
            if let last = s.last, !".?!".contains(last) { s += "." }
        } else {
            while let last = s.last, ".?!,;:".contains(last) { s.removeLast() }
        }
        return s
    }

    // MARK: - Filler words

    /// Prefilled list for Whisper. Leaves out words that often carry meaning
    /// («объект типа Promise», «вот файл», "I like it").
    public static let defaultFillers = "э, эм, мм, ну, короче, как бы, это самое, в общем-то, uh, um, er, you know, I mean"

    /// Splits the user's list on commas and newlines.
    public static func parseFillers(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Drops whole-word fillers with the comma or period right after them. A
    /// capitalized filler hands its capital to the next word, so "Ну, давай"
    /// becomes "Давай".
    static func removeFillers(_ input: String, fillers: [String]) -> String {
        let alternatives = fillers
            .map { $0.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) } }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .map { $0.joined(separator: #"\s+"#) }
        guard !alternatives.isEmpty else { return input }
        let pattern = #"(?<![\p{L}\p{N}])(?:"# + alternatives.joined(separator: "|") + #")(?![\p{L}\p{N}])[,;.…]?\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return input }

        let out = NSMutableString(string: input)
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: out.length))
        guard !matches.isEmpty else { return input }
        for match in matches.reversed() {
            let capitalized = out.substring(with: match.range).first?.isUppercase == true
            out.replaceCharacters(in: match.range, with: "")
            if capitalized, match.range.location < out.length {
                let next = out.rangeOfComposedCharacterSequence(at: match.range.location)
                out.replaceCharacters(in: next, with: out.substring(with: next).uppercased())
            }
        }
        var s = out as String
        for (pattern, template) in fillerPunctuationFixes {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s
    }

    /// Commas a removed filler leaves behind: ", ." → ".", trailing ",", " ,".
    private static let fillerPunctuationFixes: [(String, String)] = [
        (#"[,;]\s*([.!?…]|$)"#, "$1"),
        (#"[,;]\s*[,;]"#, ","),
        (#"\s+([,;.!?…])"#, "$1"),
    ]

    private static func canonicalize(_ input: String, terminology: [TerminologyEntry]) -> String {
        var s = input
        for entry in terminology {
            for variant in entry.variants where !variant.isEmpty {
                guard let regex = variantRegex(variant, caseSensitive: entry.caseSensitive) else { continue }
                let range = NSRange(s.startIndex..., in: s)
                let replacement = NSRegularExpression.escapedTemplate(for: entry.canonical)
                s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: replacement)
            }
        }
        return s
    }

    /// Terminology regexes keyed by variant + case sensitivity. A variant's regex
    /// depends only on those two, so edits to the terminology never invalidate it.
    private static var variantRegexCache: [String: NSRegularExpression] = [:]
    private static let variantRegexLock = NSLock()

    private static func variantRegex(_ variant: String, caseSensitive: Bool) -> NSRegularExpression? {
        let key = (caseSensitive ? "1" : "0") + variant
        variantRegexLock.lock()
        defer { variantRegexLock.unlock() }
        if let cached = variantRegexCache[key] { return cached }
        let escaped = NSRegularExpression.escapedPattern(for: variant)
        let pattern = #"(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        variantRegexCache[key] = regex
        return regex
    }
}
