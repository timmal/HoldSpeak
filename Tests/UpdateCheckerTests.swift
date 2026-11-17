import XCTest
@testable import HoldSpeakCore

final class UpdateCheckerTests: XCTestCase {
    private func newer(_ remote: String, _ local: String) -> Bool {
        UpdateChecker.isNewer(remote, than: local)
    }

    // MARK: - isNewer: plain versions

    func test_equalVersions_areNotNewer() {
        XCTAssertFalse(newer("0.5.6", "0.5.6"))
        XCTAssertFalse(newer("1.0.0", "1.0.0"))
    }

    func test_patchMinorMajor_ahead() {
        XCTAssertTrue(newer("0.5.7", "0.5.6"))
        XCTAssertTrue(newer("0.6.0", "0.5.6"))
        XCTAssertTrue(newer("1.0.0", "0.5.6"))
    }

    func test_patchMinorMajor_behind() {
        XCTAssertFalse(newer("0.5.5", "0.5.6"))
        XCTAssertFalse(newer("0.4.9", "0.5.6"))
        XCTAssertFalse(newer("0.9.9", "1.0.0"))
    }

    func test_multiDigitComponents_compareNumerically() {
        XCTAssertTrue(newer("0.10.0", "0.9.9"))
        XCTAssertFalse(newer("0.9.9", "0.10.0"))
        XCTAssertTrue(newer("0.5.10", "0.5.9"))
        XCTAssertTrue(newer("10.0.0", "9.99.99"))
    }

    func test_missingComponents_countAsZero() {
        XCTAssertFalse(newer("0.5", "0.5.0"))
        XCTAssertFalse(newer("0.5.0", "0.5"))
        XCTAssertTrue(newer("0.5.6.1", "0.5.6"))
        XCTAssertFalse(newer("0.5.6", "0.5.6.1"))
        XCTAssertFalse(newer("0.5.6.0", "0.5.6"))
        XCTAssertTrue(newer("1", "0.9.9"))
    }

    // MARK: - isNewer: tags and suffixes

    func test_leadingV_isIgnored() {
        // latest() strips "v" from the tag, but isNewer is public and must not
        // misread a raw tag: "v0" used to drop out and shift every component left.
        XCTAssertFalse(newer("v0.5.6", "0.5.6"))
        XCTAssertFalse(newer("v0.5.5", "0.5.6"))
        XCTAssertTrue(newer("v0.5.7", "0.5.6"))
        XCTAssertTrue(newer("V0.6.0", "0.5.6"))
        XCTAssertFalse(newer("0.5.6", "v0.5.6"))
    }

    func test_preReleaseSuffix_comparesByItsCoreVersion() {
        // A pre-release of a later version is ahead of the current release…
        XCTAssertTrue(newer("0.6.0-beta", "0.5.6"))
        XCTAssertTrue(newer("0.5.10-hotfix.1", "0.5.6"))
        // …but never ahead of the release it precedes.
        XCTAssertFalse(newer("0.6.0-beta", "0.6.0"))
        XCTAssertFalse(newer("0.6.0-beta.2", "0.6.0"))
        XCTAssertFalse(newer("0.6.0+build.7", "0.6.0"))
    }

    /// Unspecified, pinned: pre-release identifiers are not ordered. GitHub's
    /// /releases/latest never returns a pre-release, and CFBundleShortVersionString
    /// is numeric, so neither side carries one in practice.
    func test_preReleaseIdentifiers_areNotOrdered() {
        XCTAssertFalse(newer("0.6.0-beta.2", "0.6.0-beta.1"))
        XCTAssertFalse(newer("0.6.0", "0.6.0-beta"))
    }

    func test_surroundingWhitespace_isIgnored() {
        XCTAssertTrue(newer("0.5.7\n", "0.5.6"))
        XCTAssertFalse(newer(" 0.5.6 ", "0.5.6"))
    }

    // MARK: - isNewer: garbage

    func test_garbageOrEmptyRemote_isNeverNewer() {
        XCTAssertFalse(newer("", "0.5.6"))
        XCTAssertFalse(newer("garbage", "0.5.6"))
        XCTAssertFalse(newer("latest", "0.0.0"))
        XCTAssertFalse(newer("...", "0.5.6"))
    }

    /// Unspecified, pinned: parsing stops at the first non-numeric component, so
    /// nothing after it can shift into a higher position.
    func test_nonNumericComponent_endsTheVersion() {
        XCTAssertFalse(newer("0.x.9", "0.5.6"))
        XCTAssertFalse(newer("1.x.3", "1.0.0"))
        XCTAssertTrue(newer("2.x", "1.9.9"))
    }

    /// Unspecified, pinned: a local version that can't be read counts as 0, so any
    /// real release is offered. currentVersion itself falls back to "0.0.0".
    func test_garbageOrEmptyLocal_anyReleaseIsNewer() {
        XCTAssertTrue(newer("0.5.6", ""))
        XCTAssertTrue(newer("0.5.6", "unknown"))
        XCTAssertFalse(newer("", ""))
    }

    // MARK: - release(from:)

    private func fixture(tag: Any? = "v0.5.7",
                         url: Any? = "https://github.com/timmal/HoldSpeak/releases/tag/v0.5.7") -> Data {
        var json: [String: Any] = ["name": "HoldSpeak", "draft": false, "prerelease": false]
        if let tag { json["tag_name"] = tag }
        if let url { json["html_url"] = url }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func test_release_parsesVersionAndPage() throws {
        let info = try XCTUnwrap(UpdateChecker.release(from: fixture()))
        XCTAssertEqual(info.version, "0.5.7")
        XCTAssertEqual(info.url.absoluteString, "https://github.com/timmal/HoldSpeak/releases/tag/v0.5.7")
    }

    func test_release_keepsTagWithoutV() throws {
        let info = try XCTUnwrap(UpdateChecker.release(from: fixture(tag: "0.5.7")))
        XCTAssertEqual(info.version, "0.5.7")
    }

    func test_release_rejectsNonHTTPSPage() {
        XCTAssertNil(UpdateChecker.release(from: fixture(url: "javascript:alert(1)")))
        XCTAssertNil(UpdateChecker.release(from: fixture(url: "http://github.com/timmal/HoldSpeak/releases/tag/v0.5.7")))
        XCTAssertNil(UpdateChecker.release(from: fixture(url: "file:///Applications/Calculator.app")))
        XCTAssertNil(UpdateChecker.release(from: fixture(url: "x-apple.systempreferences:com.apple.preference.security")))
    }

    func test_release_rejectsOtherHosts() {
        XCTAssertNil(UpdateChecker.release(from: fixture(url: "https://evil.example/HoldSpeak.dmg")))
        XCTAssertNil(UpdateChecker.release(from: fixture(url: "https://github.com.evil.example/releases")))
        XCTAssertNil(UpdateChecker.release(from: fixture(url: "https://github.com@evil.example/releases")))
        XCTAssertNil(UpdateChecker.release(from: fixture(url: "https://api.github.com/repos/timmal/HoldSpeak")))
    }

    func test_release_acceptsHostAndSchemeInAnyCase() {
        XCTAssertNotNil(UpdateChecker.release(from: fixture(url: "HTTPS://GitHub.com/timmal/HoldSpeak/releases/latest")))
    }

    func test_release_rejectsMalformedResponses() {
        XCTAssertNil(UpdateChecker.release(from: Data()))
        XCTAssertNil(UpdateChecker.release(from: Data("not json".utf8)))
        XCTAssertNil(UpdateChecker.release(from: Data("[]".utf8)))
        XCTAssertNil(UpdateChecker.release(from: Data(#"{"message":"API rate limit exceeded"}"#.utf8)))
        XCTAssertNil(UpdateChecker.release(from: fixture(tag: nil)))
        XCTAssertNil(UpdateChecker.release(from: fixture(url: nil)))
        XCTAssertNil(UpdateChecker.release(from: fixture(tag: 57)))
        XCTAssertNil(UpdateChecker.release(from: fixture(url: "")))
    }
}
