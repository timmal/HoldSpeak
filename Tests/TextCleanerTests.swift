import XCTest
@testable import HoldSpeakCore

final class TextCleanerTests: XCTestCase {
    func test_removesExtendedRussianHesitations_keepsShortFillers() {
        // Only extended hesitations (эээ, эммм) are dropped; "ну" is legitimate speech.
        XCTAssertEqual(TextCleaner.clean("ну эээ я пошел"), "Ну я пошел.")
    }
    func test_removesExtendedEnglishHesitations_keepsShortFillers() {
        // "uhm" matches the uhm+ rule; bare "uh" is kept (uh{2,} requires uhh…).
        XCTAssertEqual(TextCleaner.clean("uhm I think uh we should go"), "I think uh we should go.")
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
    func test_keepsLikeAsRegularWord() {
        XCTAssertEqual(TextCleaner.clean("I like pizza"), "I like pizza.")
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

    func test_hallucination_dropsWholeUtteranceIgnoringCaseAndPunctuation() {
        XCTAssertEqual(TextCleaner.clean("Спасибо за просмотр!"), "")
        XCTAssertEqual(TextCleaner.clean("  Thank you for watching...  "), "")
        XCTAssertEqual(TextCleaner.clean("Продолжение следует..."), "")
    }

    func test_hallucination_dropsBareYouFromNoise() {
        XCTAssertEqual(TextCleaner.clean("you", terminology: [], autoPunctuation: true, autoCapitalize: true), "")
        XCTAssertEqual(TextCleaner.clean("You.", terminology: [], autoPunctuation: true, autoCapitalize: true), "")
        XCTAssertNotEqual(TextCleaner.clean("you know", terminology: [], autoPunctuation: true, autoCapitalize: true), "")
    }

    func test_hallucination_dropsBareThanksFromSilence() {
        XCTAssertEqual(TextCleaner.clean("Thank you."), "")
        XCTAssertEqual(TextCleaner.clean("thank you"), "")
        XCTAssertEqual(TextCleaner.clean("Спасибо."), "")
    }

    func test_hallucination_dropsSubtitleCredits() {
        XCTAssertEqual(TextCleaner.clean("Субтитры сделал DimaTorzok"), "")
        XCTAssertEqual(TextCleaner.clean("Редактор субтитров А.Семкин"), "")
    }

    func test_hallucination_keepsPhraseInsideRealSpeech() {
        XCTAssertEqual(TextCleaner.clean("спасибо за внимание, коллеги"), "Спасибо за внимание, коллеги.")
        XCTAssertEqual(TextCleaner.clean("I want to subscribe to the newsletter"),
                       "I want to subscribe to the newsletter.")
        XCTAssertEqual(TextCleaner.clean("thank you for the review"), "Thank you for the review.")
        XCTAssertEqual(TextCleaner.clean("скажи ему спасибо"), "Скажи ему спасибо.")
    }

    func test_hallucinationFilterCanBeDisabled() {
        XCTAssertEqual(TextCleaner.clean("Спасибо."), "")
        XCTAssertEqual(TextCleaner.clean("Спасибо.", dropHallucinations: false), "Спасибо.")
    }
    func test_geminiPunctuationNotDoubled() {
        XCTAssertEqual(TextCleaner.clean("Готово.", dropHallucinations: false), "Готово.")
        XCTAssertEqual(TextCleaner.clean("Готово.", autoPunctuation: false, dropHallucinations: false), "Готово")
    }

    // MARK: Filler words

    func test_fillers_offByDefault() {
        XCTAssertEqual(TextCleaner.clean("ну, короче, давай"), "Ну, короче, давай.")
    }
    func test_fillers_removedAtStart_nextWordCapitalized() {
        XCTAssertEqual(TextCleaner.clean("Ну, короче, давай созвонимся", fillers: ["ну", "короче"]),
                       "Давай созвонимся.")
    }
    func test_fillers_removedMidSentence_keepsGrammarComma() {
        XCTAssertEqual(TextCleaner.clean("я думаю, ну, что это хорошо", fillers: ["ну"]),
                       "Я думаю, что это хорошо.")
    }
    func test_fillers_afterSentenceEnd_capitalizesNextSentence() {
        XCTAssertEqual(TextCleaner.clean("Сделал. Ну, потом пошёл", fillers: ["ну"]),
                       "Сделал. Потом пошёл.")
    }
    func test_fillers_atEnd_leaveNoDanglingComma() {
        XCTAssertEqual(TextCleaner.clean("Давай завтра, короче.", fillers: ["короче"]), "Давай завтра.")
        XCTAssertEqual(TextCleaner.clean("Давай завтра, короче", autoPunctuation: false, fillers: ["короче"]),
                       "Давай завтра")
    }
    func test_fillers_multiWordAndCaseInsensitive() {
        XCTAssertEqual(TextCleaner.clean("Это  самое, I MEAN we ship it", fillers: ["это самое", "i mean"]),
                       "We ship it.")
    }
    func test_fillers_matchWholeWordsOnly() {
        XCTAssertEqual(TextCleaner.clean("нужно ну и всё", fillers: ["ну"]), "Нужно и всё.")
        XCTAssertEqual(TextCleaner.clean("в общем-то готово", fillers: ["в общем-то"]), "Готово.")
    }
    func test_fillers_onlyFillersYieldsEmpty() {
        XCTAssertEqual(TextCleaner.clean("Ну, короче.", fillers: ["ну", "короче"]), "")
    }
    func test_parseFillers_splitsOnCommasAndNewlines() {
        XCTAssertEqual(TextCleaner.parseFillers(" ну, короче ,,\nкак бы\n "), ["ну", "короче", "как бы"])
    }
    func test_defaultFillers_parse() {
        let list = TextCleaner.parseFillers(TextCleaner.defaultFillers)
        XCTAssertTrue(list.contains("ну"))
        XCTAssertFalse(list.contains("типа"), "ambiguous: «объект типа Promise»")
    }

    // MARK: - Implausible length (engine invented text on silence)

    func test_implausiblyLong_flagsParagraphFromSubSecondClip() {
        let invented = "Так, в общем, задача звучит следующим образом. Есть задача разработать телеграм-бота для категоризации входящих сообщений."
        XCTAssertTrue(TextCleaner.isImplausiblyLong(invented, durationMs: 780))
        XCTAssertTrue(TextCleaner.isImplausiblyLong("Мы создали Pull request, и сейчас надо сделать code review", durationMs: 1290))
    }

    func test_implausiblyLong_keepsFastRealSpeech() {
        // Fastest real dictations in history run ~18 chars/s.
        XCTAssertFalse(TextCleaner.isImplausiblyLong("Проверь, чтобы переиспользовалось.", durationMs: 1890))
        XCTAssertFalse(TextCleaner.isImplausiblyLong("Да.", durationMs: 300))
        XCTAssertFalse(TextCleaner.isImplausiblyLong(String(repeating: "а", count: 180), durationMs: 9000))
    }
}
