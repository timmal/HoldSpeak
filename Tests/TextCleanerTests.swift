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

    // MARK: - Repeat rules must stop at a word boundary (HS-30)

    /// What every engine gets: the cleaner with the Whisper-only filter off.
    private func cleaned(_ text: String) -> String {
        TextCleaner.clean(text, dropHallucinations: false)
    }

    func test_repeat_keepsWordTheNextWordStartsWith_russian() {
        XCTAssertEqual(cleaned("Напиши ему по поводу релиза"), "Напиши ему по поводу релиза.")
        XCTAssertEqual(cleaned("я не негодую"), "Я не негодую.")
        XCTAssertEqual(cleaned("на наш сервер"), "На наш сервер.")
        XCTAssertEqual(cleaned("Возьми с собой ноутбук"), "Возьми с собой ноутбук.")
        XCTAssertEqual(cleaned("и идем дальше"), "И идем дальше.")
    }
    func test_repeat_keepsWordTheNextWordStartsWith_english() {
        XCTAssertEqual(cleaned("We need to go to Google today"), "We need to go to Google today.")
        XCTAssertEqual(cleaned("I am so sorry, we were late"), "I am so sorry, we were late.")
    }
    func test_repeat_keepsWordBeforeHyphenatedWordStartingWithIt() {
        XCTAssertEqual(cleaned("я знал, что что-то не так"), "Я знал, что что-то не так.")
        XCTAssertEqual(cleaned("мы все все-таки пришли"), "Мы все все-таки пришли.")
        // Engines also emit the typographic hyphens.
        let nonBreakingHyphen = String(UnicodeScalar(0x2011)!)
        XCTAssertEqual(cleaned("что что\(nonBreakingHyphen)то не так"), "Что что\(nonBreakingHyphen)то не так.")
    }
    func test_repeat_multiWordPhraseStopsAtWordBoundary() {
        XCTAssertEqual(cleaned("это на это направлено"), "Это на это направлено.")
    }
    func test_repeat_tripleWordRuleStopsAtWordBoundary() {
        // Three real "я" collapse, the "я" that opens "явно" is not a fourth one.
        XCTAssertEqual(cleaned("я я я явно вижу"), "Я явно вижу.")
        XCTAssertEqual(cleaned("что что что что-то не так"), "Что что-то не так.")
    }
    func test_repeat_keepsDigitOnlyRepeats() {
        XCTAssertEqual(cleaned("Позвони на 8 800 555 35 35"), "Позвони на 8 800 555 35 35.")
        XCTAssertEqual(cleaned("12 12 34"), "12 12 34.")
        XCTAssertEqual(cleaned("код 5 5 5"), "Код 5 5 5.")
        XCTAssertEqual(cleaned("12 34 12 34"), "12 34 12 34.")
        XCTAssertEqual(cleaned("35. 35."), "35. 35.")
    }
    func test_repeat_stillCollapsesRealStutter() {
        XCTAssertEqual(cleaned("тест тест проверка"), "Тест проверка.")
        XCTAssertEqual(cleaned("тест тест тест проверка"), "Тест проверка.")
        XCTAssertEqual(cleaned("я думаю я думаю что да"), "Я думаю что да.")
        XCTAssertEqual(cleaned("Привет. Привет. Как дела?"), "Привет. Как дела?")
        XCTAssertEqual(cleaned("the the cat"), "The cat.")
        // A phrase with a number in it is still a phrase.
        XCTAssertEqual(cleaned("версия 2 версия 2 готова"), "Версия 2 готова.")
        XCTAssertEqual(cleaned("35 раз 35 раз подряд"), "35 раз подряд.")
    }
    func test_repeat_legitimateDoubleWordStillCollapsed() {
        // Known limitation, kept on purpose: a separate product decision.
        XCTAssertEqual(cleaned("that that is true"), "That is true.")
    }

    // MARK: - Bracketed annotations: inline ones are stripped only for Whisper (HS-48)

    /// Whisper: what every call gets by default.
    private func whisper(_ text: String) -> String {
        TextCleaner.clean(text, dropHallucinations: true, stripInlineAnnotations: true)
    }
    /// Parakeet, Gemini, OpenAI.
    private func otherEngine(_ text: String) -> String {
        TextCleaner.clean(text, dropHallucinations: false, stripInlineAnnotations: false)
    }

    func test_annotations_defaultStripsInline() {
        XCTAssertEqual(TextCleaner.clean("Привет [музыка] как дела"), "Привет как дела.")
    }
    func test_annotations_dictatedParenthetical() {
        XCTAssertEqual(whisper("Вызови foo (опционально) и верни результат"), "Вызови foo и верни результат.")
        XCTAssertEqual(otherEngine("Вызови foo (опционально) и верни результат"),
                       "Вызови foo (опционально) и верни результат.")
    }
    func test_annotations_subscripts() {
        XCTAssertEqual(whisper("array[0] и dict[key]"), "Array и dict.")
        XCTAssertEqual(otherEngine("array[0] и dict[key]"), "Array[0] и dict[key].")
    }
    func test_annotations_aloneDroppedOnEveryEngine() {
        for text in ["[музыка]", "(applause) (laughter)", "  [music].  ", "[музыка] [аплодисменты]", "(silence)"] {
            XCTAssertEqual(whisper(text), "", text)
            XCTAssertEqual(otherEngine(text), "", text)
        }
    }
    func test_annotations_inlineSoundEvent() {
        XCTAssertEqual(whisper("Привет [музыка] как дела"), "Привет как дела.")
        XCTAssertEqual(otherEngine("Привет [музыка] как дела"), "Привет [музыка] как дела.")
    }
    func test_annotations_unclosedBracketKept() {
        XCTAssertEqual(whisper("Вызови foo (опционально и верни"), "Вызови foo (опционально и верни.")
        XCTAssertEqual(otherEngine("Вызови foo (опционально и верни"), "Вызови foo (опционально и верни.")
        XCTAssertEqual(whisper("array[0"), "Array[0.")
        XCTAssertEqual(otherEngine("array[0"), "Array[0.")
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
