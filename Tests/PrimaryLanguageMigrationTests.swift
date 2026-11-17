import XCTest
@testable import HoldSpeakCore

/// HS-37: new installs recognise in auto-detect; existing installs keep Russian.
final class PrimaryLanguageMigrationTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "HoldSpeakTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func migrate(hasHistory: Bool = false) -> Bool {
        PreferencesStore.migratePrimaryLanguageDefault(defaults, hasExistingHistory: hasHistory)
    }

    private var effective: PrimaryLanguage { PreferencesStore.effectivePrimaryLanguage(defaults) }

    func test_newInstallsDefaultToAuto() {
        XCTAssertEqual(PreferencesStore.defaultPrimaryLanguage, .auto)
    }

    func test_freshInstall_languageNotWritten_auto() {
        XCTAssertFalse(migrate())
        XCTAssertNil(defaults.object(forKey: "primaryLanguage"))
        XCTAssertEqual(effective, .auto)
    }

    func test_freshInstall_staysAutoOnLaterLaunches() {
        XCTAssertFalse(migrate())
        // First launch: onboarding picks an engine, history.sqlite is created.
        defaults.set("openai", forKey: "transcriptionEngine")
        XCTAssertFalse(migrate(hasHistory: true))
        XCTAssertNil(defaults.object(forKey: "primaryLanguage"))
        XCTAssertEqual(effective, .auto)
    }

    func test_existingInstall_engineChosen_keepsRussian() {
        defaults.set("whisper", forKey: "transcriptionEngine")
        XCTAssertTrue(migrate(hasHistory: true))
        XCTAssertEqual(defaults.string(forKey: "primaryLanguage"), "ru")
        XCTAssertEqual(effective, .ru)
    }

    func test_existingInstall_engineChosenWithoutHistory_keepsRussian() {
        defaults.set("gemini", forKey: "transcriptionEngine")
        XCTAssertTrue(migrate())
        XCTAssertEqual(defaults.string(forKey: "primaryLanguage"), "ru")
    }

    /// From before the engine choice, settings never touched: only the history DB
    /// (created on every launch since the first version) shows the app ran.
    func test_existingInstall_beforeEngineChoice_untouchedSettings_keepsRussian() {
        XCTAssertTrue(migrate(hasHistory: true))
        XCTAssertEqual(defaults.string(forKey: "primaryLanguage"), "ru")
    }

    func test_existingInstall_anyOwnSettingStored_keepsRussian() {
        for key in ["hotkey", "hotkeyBindingJSON", "modelID", "holdThresholdMs", "hudPosition",
                    "appTheme", "launchAtLogin", "autoPunctuation", "removeFillers", "localEngine"] {
            let name = "HoldSpeakTests.\(UUID().uuidString)"
            let d = UserDefaults(suiteName: name)!
            defer { d.removePersistentDomain(forName: name) }
            d.set("x", forKey: key)
            XCTAssertTrue(PreferencesStore.migratePrimaryLanguageDefault(d, hasExistingHistory: false), key)
            XCTAssertEqual(d.string(forKey: "primaryLanguage"), "ru", key)
        }
    }

    func test_existingInstall_storedValueUntouched() {
        for stored in ["auto", "en", "ru", "uk"] {
            let name = "HoldSpeakTests.\(UUID().uuidString)"
            let d = UserDefaults(suiteName: name)!
            defer { d.removePersistentDomain(forName: name) }
            d.set(stored, forKey: "primaryLanguage")
            d.set("whisper", forKey: "transcriptionEngine")
            XCTAssertFalse(PreferencesStore.migratePrimaryLanguageDefault(d, hasExistingHistory: true), stored)
            XCTAssertEqual(d.string(forKey: "primaryLanguage"), stored)
            XCTAssertEqual(PreferencesStore.effectivePrimaryLanguage(d).rawValue, stored)
        }
    }

    func test_runningTwiceIsANoOp() {
        defaults.set("whisper", forKey: "transcriptionEngine")
        XCTAssertTrue(migrate(hasHistory: true))
        let afterFirst = defaults.persistentDomain(forName: suiteName) as NSDictionary?
        XCTAssertFalse(migrate(hasHistory: true))
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName) as NSDictionary?, afterFirst)
        XCTAssertEqual(defaults.string(forKey: "primaryLanguage"), "ru")

        // Fresh install: the second run doesn't write anything either.
        let name = "HoldSpeakTests.\(UUID().uuidString)"
        let fresh = UserDefaults(suiteName: name)!
        defer { fresh.removePersistentDomain(forName: name) }
        XCTAssertFalse(PreferencesStore.migratePrimaryLanguageDefault(fresh, hasExistingHistory: false))
        let freshAfterFirst = fresh.persistentDomain(forName: name) as NSDictionary?
        XCTAssertFalse(PreferencesStore.migratePrimaryLanguageDefault(fresh, hasExistingHistory: false))
        XCTAssertEqual(fresh.persistentDomain(forName: name) as NSDictionary?, freshAfterFirst)

        // The user switches to auto later: the next launch leaves it.
        defaults.set("auto", forKey: "primaryLanguage")
        XCTAssertFalse(migrate(hasHistory: true))
        XCTAssertEqual(defaults.string(forKey: "primaryLanguage"), "auto")
    }

    func test_userResetsToDefault_laterLaunchDoesNotForceRussian() {
        defaults.set("whisper", forKey: "transcriptionEngine")
        XCTAssertTrue(migrate(hasHistory: true))
        // Removing the value (e.g. `defaults delete`) means "use the default" from now on.
        defaults.removeObject(forKey: "primaryLanguage")
        XCTAssertFalse(migrate(hasHistory: true))
        XCTAssertNil(defaults.object(forKey: "primaryLanguage"))
    }
}
