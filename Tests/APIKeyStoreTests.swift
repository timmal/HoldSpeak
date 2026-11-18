import XCTest
import Security
@testable import HoldSpeakCore

/// In-memory Keychain: never touches the real `com.timmal.push-to-talk` service.
final class FakeKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [String: String] = [:]
    /// Every read fails with this status (a denied or cancelled password prompt).
    var failAllReads: OSStatus?
    /// Reads of these accounts fail with the given status.
    var readFailures: [String: OSStatus] = [:]
    var failWrites = false
    var failDeletes = false
    private(set) var reads: [String] = []
    private(set) var writes: [String] = []
    private(set) var deletes: [String] = []
    /// One entry per read: whether it ran on the main thread.
    private(set) var readsOnMain: [Bool] = []
    /// When set, every read signals `readStarted` and blocks until `gate` is signalled:
    /// the user hasn't answered the password prompt yet.
    var gate: DispatchSemaphore?
    let readStarted = DispatchSemaphore(value: 0)

    var items: [String: String] {
        get { lock.withLock { _items } }
        set { lock.withLock { _items = newValue } }
    }

    func read(_ account: String) -> KeychainRead {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            readsOnMain.append(Thread.isMainThread)
            return self.gate
        }
        if let gate {
            readStarted.signal()
            gate.wait()
        }
        return lock.withLock {
            reads.append(account)
            if let status = failAllReads ?? readFailures[account] { return .failed(status) }
            return _items[account].map(KeychainRead.found) ?? .notFound
        }
    }

    func set(_ value: String, for account: String) -> Bool {
        lock.withLock {
            writes.append(account)
            guard !failWrites else { return false }
            _items[account] = value
            return true
        }
    }

    func delete(_ account: String) -> Bool {
        lock.withLock {
            deletes.append(account)
            guard !failDeletes else { return false }
            _items[account] = nil
            return true
        }
    }

    /// The merged item, decoded.
    var storedKeys: [String: String]? {
        guard let json = items["api-keys"] else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))
    }

    func storeKeys(_ keys: [String: String]) {
        items["api-keys"] = String(decoding: try! JSONEncoder().encode(keys), as: UTF8.self)
    }
}

final class APIKeyStoreTests: XCTestCase {
    private var keychain: FakeKeychain!
    private var store: APIKeyStore!

    override func setUp() {
        super.setUp()
        keychain = FakeKeychain()
        store = APIKeyStore(keychain: keychain)
    }

    // MARK: Denied read

    func test_deniedRead_isNotCachedAsEmpty() {
        keychain.storeKeys(["gemini": "g-key", "openai": "o-key"])
        keychain.failAllReads = errSecUserCanceled

        XCTAssertNil(store.key(.gemini))
        XCTAssertEqual(store.availability, .unavailable)
        XCTAssertEqual(keychain.reads, ["api-keys"], "the legacy merge must not run after a failed read")

        // Asked on every dictation: no new prompt per call.
        XCTAssertNil(store.key(.openai))
        XCTAssertNil(store.key(.gemini))
        XCTAssertEqual(keychain.reads.count, 1)
        XCTAssertTrue(keychain.writes.isEmpty)
        XCTAssertTrue(keychain.deletes.isEmpty)
    }

    func test_deniedRead_saveRetriesThenWritesNothing() {
        keychain.storeKeys(["gemini": "g-key", "openai": "o-key"])
        keychain.failAllReads = errSecAuthFailed
        XCTAssertNil(store.key(.gemini))

        XCTAssertFalse(store.setKey("new-o-key", for: .openai))
        XCTAssertEqual(keychain.reads.count, 2, "saving retries the read once")
        XCTAssertTrue(keychain.writes.isEmpty)
        XCTAssertTrue(keychain.deletes.isEmpty)
        XCTAssertFalse(store.setKey(nil, for: .gemini), "removing a key is a write too")
        XCTAssertTrue(keychain.writes.isEmpty)
        XCTAssertTrue(keychain.deletes.isEmpty)
        XCTAssertEqual(keychain.storedKeys, ["gemini": "g-key", "openai": "o-key"])
        XCTAssertEqual(store.availability, .unavailable)
    }

    func test_reloadAfterAllow_bothKeysPresent() {
        keychain.storeKeys(["gemini": "g-key", "openai": "o-key"])
        keychain.failAllReads = errSecUserCanceled
        XCTAssertNil(store.key(.gemini))

        keychain.failAllReads = nil
        XCTAssertEqual(store.reload(), .loaded)
        XCTAssertEqual(store.key(.gemini), "g-key")
        XCTAssertEqual(store.key(.openai), "o-key")
    }

    func test_saveAfterAllow_keepsTheOtherKey() {
        keychain.storeKeys(["gemini": "g-key"])
        keychain.failAllReads = errSecUserCanceled
        XCTAssertNil(store.key(.gemini))

        keychain.failAllReads = nil
        XCTAssertTrue(store.setKey("o-key", for: .openai))
        XCTAssertEqual(keychain.storedKeys, ["gemini": "g-key", "openai": "o-key"])
        XCTAssertEqual(store.key(.gemini), "g-key")
        XCTAssertEqual(store.availability, .loaded)
    }

    func test_loadedKeysAreServedFromMemory() {
        keychain.storeKeys(["gemini": "g-key"])
        XCTAssertEqual(store.key(.gemini), "g-key")
        XCTAssertNil(store.key(.openai))
        XCTAssertEqual(store.key(.gemini), "g-key")
        XCTAssertEqual(keychain.reads, ["api-keys"])
    }

    func test_reloadWhenLoaded_doesNotReadAgain() {
        keychain.storeKeys(["gemini": "g-key"])
        XCTAssertEqual(store.key(.gemini), "g-key")
        XCTAssertEqual(store.reload(), .loaded)
        XCTAssertEqual(keychain.reads.count, 1, "a re-read could prompt again")
    }

    // MARK: Saving

    func test_savingOneKeyNeverDropsTheOther() {
        keychain.storeKeys(["gemini": "g-key", "openai": "o-key"])
        XCTAssertTrue(store.setKey("g-key-2", for: .gemini))
        XCTAssertEqual(keychain.storedKeys, ["gemini": "g-key-2", "openai": "o-key"])
        XCTAssertTrue(store.setKey(nil, for: .gemini))
        XCTAssertEqual(keychain.storedKeys, ["openai": "o-key"])
        XCTAssertTrue(store.setKey("", for: .openai), "empty removes the key")
        XCTAssertNil(keychain.items["api-keys"], "no keys left: the item goes")
        XCTAssertNil(store.key(.openai))
    }

    func test_failedSave_reportsFailureAndKeepsTheCache() {
        keychain.storeKeys(["gemini": "g-key"])
        XCTAssertEqual(store.key(.gemini), "g-key")
        keychain.failWrites = true

        XCTAssertFalse(store.setKey("o-key", for: .openai))
        XCTAssertNil(store.key(.openai), "a key that wasn't saved must not look saved")
        XCTAssertFalse(store.setKey("g-key-2", for: .gemini))
        XCTAssertEqual(store.key(.gemini), "g-key")
        XCTAssertEqual(store.availability, .loaded)

        keychain.failWrites = false
        XCTAssertTrue(store.setKey("o-key", for: .openai))
        XCTAssertEqual(keychain.storedKeys, ["gemini": "g-key", "openai": "o-key"])
    }

    func test_failedRemoval_reportsFailureAndKeepsTheKey() {
        keychain.storeKeys(["gemini": "g-key"])
        keychain.failDeletes = true
        XCTAssertFalse(store.setKey(nil, for: .gemini))
        XCTAssertEqual(store.key(.gemini), "g-key")
    }

    func test_freshInstall_nothingStoredNothingWritten() {
        XCTAssertNil(store.key(.gemini))
        XCTAssertEqual(store.availability, .loaded)
        XCTAssertTrue(keychain.writes.isEmpty)
        XCTAssertTrue(keychain.deletes.isEmpty)
        XCTAssertTrue(store.setKey("g-key", for: .gemini))
        XCTAssertEqual(keychain.storedKeys, ["gemini": "g-key"])
    }

    // MARK: Legacy per-provider items

    func test_legacyMerge_movesBothKeysIntoOneItem() {
        keychain.items = ["gemini-api-key": "g-key", "openai-api-key": "o-key"]
        XCTAssertEqual(store.key(.openai), "o-key")
        XCTAssertEqual(store.key(.gemini), "g-key")
        XCTAssertEqual(keychain.storedKeys, ["gemini": "g-key", "openai": "o-key"])
        XCTAssertNil(keychain.items["gemini-api-key"])
        XCTAssertNil(keychain.items["openai-api-key"])
    }

    func test_legacyMerge_failedSaveKeepsLegacyItems() {
        keychain.items = ["gemini-api-key": "g-key", "openai-api-key": "o-key"]
        keychain.failWrites = true
        XCTAssertEqual(store.key(.gemini), "g-key", "the keys were read, so they are still served")
        XCTAssertTrue(keychain.deletes.isEmpty, "legacy items go only after a successful save")
        XCTAssertEqual(keychain.items["gemini-api-key"], "g-key")
        XCTAssertEqual(keychain.items["openai-api-key"], "o-key")
    }

    func test_legacyMerge_finishesOnTheNextSuccessfulSave() {
        keychain.items = ["gemini-api-key": "g-key", "openai-api-key": "o-key"]
        keychain.failWrites = true
        XCTAssertEqual(store.key(.gemini), "g-key")

        keychain.failWrites = false
        XCTAssertTrue(store.setKey("g-key-2", for: .gemini))
        XCTAssertEqual(keychain.storedKeys, ["gemini": "g-key-2", "openai": "o-key"])
        XCTAssertNil(keychain.items["gemini-api-key"])
        XCTAssertNil(keychain.items["openai-api-key"])
    }

    func test_legacyRead_failed_isUnavailable() {
        keychain.items = ["gemini-api-key": "g-key", "openai-api-key": "o-key"]
        keychain.readFailures = ["openai-api-key": errSecUserCanceled]
        XCTAssertNil(store.key(.gemini), "a partial read must not be served")
        XCTAssertEqual(store.availability, .unavailable)
        XCTAssertTrue(keychain.writes.isEmpty)
        XCTAssertTrue(keychain.deletes.isEmpty)

        keychain.readFailures = [:]
        XCTAssertEqual(store.reload(), .loaded)
        XCTAssertEqual(keychain.storedKeys, ["gemini": "g-key", "openai": "o-key"])
        XCTAssertNil(keychain.items["openai-api-key"])
    }

    // MARK: Loading off the main thread

    func test_loadInBackground_readsOffMainAndCompletesOnMain() {
        keychain.storeKeys(["gemini": "g-key", "openai": "o-key"])
        let done = expectation(description: "loaded")
        store.loadInBackground(retry: false) { availability in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(availability, .loaded)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(keychain.readsOnMain, [false])
        XCTAssertEqual(store.key(.gemini), "g-key")
        XCTAssertEqual(store.key(.openai), "o-key")
        XCTAssertEqual(keychain.reads.count, 1, "served from memory afterwards")
    }

    func test_loadInBackground_isLoadingUntilThePromptIsAnswered() {
        keychain.storeKeys(["gemini": "g-key"])
        let gate = DispatchSemaphore(value: 0)
        keychain.gate = gate
        let done = expectation(description: "loaded")
        store.loadInBackground(retry: false) { _ in done.fulfill() }
        XCTAssertEqual(keychain.readStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(store.availability, .loading)

        // A dictation asking meanwhile waits for the same read instead of prompting again.
        let asked = expectation(description: "key served")
        DispatchQueue.global().async {
            XCTAssertEqual(self.store.key(.gemini), "g-key")
            asked.fulfill()
        }
        keychain.gate = nil
        gate.signal()
        wait(for: [done, asked], timeout: 5)
        XCTAssertEqual(keychain.reads.count, 1)
    }

    func test_loadInBackground_deniedStaysDeniedWithoutRetry() {
        keychain.storeKeys(["gemini": "g-key"])
        keychain.failAllReads = errSecUserCanceled
        let first = expectation(description: "first")
        store.loadInBackground(retry: false) { availability in
            XCTAssertEqual(availability, .unavailable)
            first.fulfill()
        }
        wait(for: [first], timeout: 5)

        // Warming again (e.g. reopening Preferences) doesn't prompt again…
        let warmAgain = expectation(description: "warm again")
        store.loadInBackground(retry: false) { availability in
            XCTAssertEqual(availability, .unavailable)
            warmAgain.fulfill()
        }
        wait(for: [warmAgain], timeout: 5)
        XCTAssertEqual(keychain.reads.count, 1)

        // …"Try again" does.
        keychain.failAllReads = nil
        let retried = expectation(description: "retried")
        store.loadInBackground(retry: true) { availability in
            XCTAssertEqual(availability, .loaded)
            retried.fulfill()
        }
        wait(for: [retried], timeout: 5)
        XCTAssertEqual(store.key(.gemini), "g-key")
        XCTAssertEqual(keychain.readsOnMain, [false, false])
    }

    // MARK: Non-blocking reads (HS-54)

    func test_loadedKey_notLoaded_neverTouchesTheKeychain() {
        keychain.storeKeys(["gemini": "g-key"])
        XCTAssertNil(store.loadedKey(.gemini))
        XCTAssertNil(store.loadedKey(.openai))
        XCTAssertTrue(keychain.reads.isEmpty, "a view body must never raise the password prompt")
        XCTAssertEqual(store.availability, .notLoaded)
    }

    func test_loadedKey_whileLoading_returnsAtOnceThenTheKey() {
        keychain.storeKeys(["gemini": "g-key"])
        let gate = DispatchSemaphore(value: 0)
        keychain.gate = gate
        let done = expectation(description: "loaded")
        store.loadInBackground(retry: false) { _ in done.fulfill() }
        XCTAssertEqual(keychain.readStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(store.availability, .loading)

        // The prompt is still up: answered at once, without waiting for it. A wait here
        // would hang this test, since the gate opens only below.
        XCTAssertNil(store.loadedKey(.gemini))

        keychain.gate = nil
        gate.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(store.loadedKey(.gemini), "g-key")
        XCTAssertNil(store.loadedKey(.openai))
        XCTAssertEqual(keychain.reads.count, 1)
    }

    func test_loadedKey_deniedRead_isNilWithoutRetrying() {
        keychain.storeKeys(["gemini": "g-key"])
        keychain.failAllReads = errSecUserCanceled
        XCTAssertNil(store.key(.gemini))
        XCTAssertNil(store.loadedKey(.gemini))
        XCTAssertEqual(keychain.reads.count, 1)
    }

    func test_keyLoadingInBackground_readsOffMainAndServesTheKey() {
        keychain.storeKeys(["gemini": "g-key"])
        let gate = DispatchSemaphore(value: 0)
        keychain.gate = gate
        let readStarted = expectation(description: "read started")
        DispatchQueue.global().async {
            if self.keychain.readStarted.wait(timeout: .now() + 5) == .success { readStarted.fulfill() }
        }
        // A dictation asks from the main actor, as the transcribers do.
        let served = expectation(description: "key served")
        Task { @MainActor in
            let key = await self.store.keyLoadingInBackground(.gemini)
            XCTAssertEqual(key, "g-key")
            served.fulfill()
        }
        // The task runs on main during this wait. That the wait returns, with the prompt
        // still unanswered, shows the main-actor caller suspended instead of blocking main.
        wait(for: [readStarted], timeout: 5)
        XCTAssertEqual(store.availability, .loading)
        XCTAssertNil(store.loadedKey(.gemini))

        keychain.gate = nil
        gate.signal()
        wait(for: [served], timeout: 5)
        XCTAssertEqual(keychain.readsOnMain, [false])

        // Loaded: served from memory, no second read.
        let again = expectation(description: "served again")
        Task { @MainActor in
            let key = await self.store.keyLoadingInBackground(.gemini)
            XCTAssertEqual(key, "g-key")
            again.fulfill()
        }
        wait(for: [again], timeout: 5)
        XCTAssertEqual(keychain.reads.count, 1)
    }

    func test_keyLoadingInBackground_deniedRead_doesNotPromptAgain() {
        keychain.storeKeys(["gemini": "g-key"])
        keychain.failAllReads = errSecUserCanceled
        for _ in 0..<2 {
            let served = expectation(description: "answered")
            Task { @MainActor in
                let key = await self.store.keyLoadingInBackground(.gemini)
                XCTAssertNil(key)
                served.fulfill()
            }
            wait(for: [served], timeout: 5)
        }
        XCTAssertEqual(keychain.reads.count, 1)
        XCTAssertEqual(store.availability, .unavailable)
    }

    func test_mergedItemWins_legacyItemsIgnored() {
        keychain.storeKeys(["gemini": "g-key"])
        keychain.items["openai-api-key"] = "stale"
        XCTAssertNil(store.key(.openai))
        XCTAssertEqual(keychain.reads, ["api-keys"])
        XCTAssertTrue(keychain.writes.isEmpty)
    }
}
