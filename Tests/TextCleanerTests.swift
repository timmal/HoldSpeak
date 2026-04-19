import XCTest
@testable import PushToTalkCore

final class TextCleanerTests: XCTestCase {
    func test_removesRussianFillers() {
        XCTAssertEqual(TextCleaner.clean("ну эээ я пошел"), "Я пошел.")
    }
    func test_removesEnglishFillers() {
        XCTAssertEqual(TextCleaner.clean("uhm I think uh we should go"), "I think we should go.")
    }
    func test_collapsesStutter() {
        XCTAssertEqual(TextCleaner.clean("я я я думаю"), "Я думаю.")
    }
    func test_preservesMixedEnglishTokens() {
        let out = TextCleaner.clean("у нас созвон в zoom с product manager")
        XCTAssertTrue(out.contains("zoom"))
        XCTAssertTrue(out.contains("product manager"))
    }
    func test_normalizesWhitespaceAndPunctuation() {
        XCTAssertEqual(TextCleaner.clean("   привет    мир"), "Привет мир.")
    }
    func test_preservesExistingPunctuation() {
        XCTAssertEqual(TextCleaner.clean("это вопрос?"), "Это вопрос?")
    }
    func test_returnsEmptyForWhitespaceOnly() {
        XCTAssertEqual(TextCleaner.clean("   "), "")
    }
    func test_removesLikeFiller() {
        // "like" as filler — rule is aggressive; accept removal for v1
        XCTAssertEqual(TextCleaner.clean("I like pizza"), "I pizza.")
    }

    // MARK: - Terminology canonicalization

    private var dict: [TerminologyEntry] {
        [
            TerminologyEntry(canonical: "pull request",
                             variants: ["пулл реквест", "пул-реквест", "пулреквест"]),
            TerminologyEntry(canonical: "code review",
                             variants: ["код ревью"]),
            TerminologyEntry(canonical: "Swift",
                             variants: ["свифт"],
                             caseSensitive: false),
        ]
    }

    func test_terminologyReplacesVariant() {
        let out = TextCleaner.clean("запушь пулл реквест в main", terminology: dict)
        XCTAssertEqual(out, "Запушь pull request в main.")
    }

    func test_terminologyReplacesHyphenatedVariant() {
        let out = TextCleaner.clean("сделай пул-реквест", terminology: dict)
        XCTAssertEqual(out, "Сделай pull request.")
    }

    func test_terminologyWordBoundary_shouldNotMatchInsideWord() {
        // Variant "пулреквест" should not match inside "пулреквестер"
        let out = TextCleaner.clean("позови пулреквестера", terminology: dict)
        XCTAssertFalse(out.lowercased().contains("pull request"))
    }

    func test_terminologyCaseInsensitiveByDefault() {
        let out = TextCleaner.clean("пиши на Свифт", terminology: dict)
        XCTAssertTrue(out.contains("Swift"))
    }

    func test_hallucinationBlacklist_stillWorks() {
        XCTAssertEqual(TextCleaner.clean("спасибо за просмотр"), "")
    }
}
