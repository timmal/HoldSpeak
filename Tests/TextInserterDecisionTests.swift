import ApplicationServices
import XCTest
@testable import HoldSpeakCore

final class TextInserterDecisionTests: XCTestCase {
    private let native = InsertionFacts.App(bundleID: "com.apple.Terminal", isRegular: true, isElectron: false, isSelf: false)
    private let electron = InsertionFacts.App(bundleID: "com.microsoft.VSCode", isRegular: true, isElectron: true, isSelf: false)

    private func facts(trusted: Bool = true, focus: InsertionFacts.Focus, app: InsertionFacts.App?,
                       tried: Bool = false, secureInput: Bool = false) -> InsertionFacts {
        InsertionFacts(trusted: trusted, focus: focus, app: app, manualAccessibilityTried: tried, secureInput: secureInput)
    }

    private func action(_ f: InsertionFacts) -> InsertionAction { InsertionPolicy.action(for: f) }

    func test_focusedElement_typesIntoIt() {
        XCTAssertEqual(action(facts(focus: .element(role: "AXTextArea", subrole: nil), app: native)), .typeIntoFocused)
        // A panel outside the frontmost app (Spotlight, Raycast) still counts.
        XCTAssertEqual(action(facts(focus: .element(role: "AXTextField", subrole: nil), app: nil)), .typeIntoFocused)
    }

    func test_secureField_byRoleOrSubrole_isSkipped() {
        XCTAssertEqual(action(facts(focus: .element(role: "AXSecureTextField", subrole: nil), app: native)), .skipSecureField)
        XCTAssertEqual(action(facts(focus: .element(role: "AXTextField", subrole: "AXSecureTextField"), app: electron)),
                       .skipSecureField)
    }

    func test_notTrusted_isNoFocus_evenWithAnApp() {
        XCTAssertEqual(action(facts(trusted: false, focus: .failed(.apiDisabled), app: native)), .noFocus)
        XCTAssertEqual(action(facts(trusted: false, focus: .failed(.apiDisabled), app: electron)), .noFocus)
        XCTAssertEqual(action(facts(focus: .failed(.apiDisabled), app: native)), .noFocus)
    }

    func test_electronWithoutFocus_enablesManualAccessibilityOnce() {
        XCTAssertEqual(action(facts(focus: .failed(.noValue), app: electron)), .enableManualAccessibility)
        XCTAssertEqual(action(facts(focus: .failed(.noValue), app: electron, tried: true)), .typeBlind)
    }

    func test_nativeAppWithoutFocus_typesBlind_noManualAccessibility() {
        XCTAssertEqual(action(facts(focus: .failed(.noValue), app: native)), .typeBlind)
        XCTAssertEqual(action(facts(focus: .failed(.cannotComplete), app: native)), .typeBlind)
    }

    func test_blind_withSecureInput_isSkipped() {
        XCTAssertEqual(action(facts(focus: .failed(.noValue), app: native, secureInput: true)), .skipSecureField)
        XCTAssertEqual(action(facts(focus: .failed(.noValue), app: electron, tried: true, secureInput: true)),
                       .skipSecureField)
    }

    func test_noSuitableFrontmostApp_isNoFocus() {
        XCTAssertEqual(action(facts(focus: .failed(.noValue), app: nil)), .noFocus)
        // Desktop: Finder frontmost with nothing focused.
        let finder = InsertionFacts.App(bundleID: "com.apple.finder", isRegular: true, isElectron: false, isSelf: false)
        XCTAssertEqual(action(facts(focus: .failed(.noValue), app: finder)), .noFocus)
        let agent = InsertionFacts.App(bundleID: "com.example.menubar", isRegular: false, isElectron: false, isSelf: false)
        XCTAssertEqual(action(facts(focus: .failed(.noValue), app: agent)), .noFocus)
        let holdSpeak = InsertionFacts.App(bundleID: "com.timmal.holdspeak", isRegular: true, isElectron: false, isSelf: true)
        XCTAssertEqual(action(facts(focus: .failed(.noValue), app: holdSpeak)), .noFocus)
    }

    func test_axErrorNames() {
        XCTAssertEqual(axErrorName(.apiDisabled), "apiDisabled")
        XCTAssertEqual(axErrorName(.noValue), "noValue")
        XCTAssertEqual(axErrorName(.cannotComplete), "cannotComplete")
    }
}
