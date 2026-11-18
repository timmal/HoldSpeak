import Foundation
import Security

/// The outcome of reading one Keychain item. A denied or cancelled password prompt
/// is `failed`, not `notFound`: treating it as "no item" loses the other keys on the next save.
public enum KeychainRead: Equatable {
    case found(String)
    case notFound
    case failed(OSStatus)
}

/// The Keychain operations the API key storage needs, so tests can use a fake.
public protocol KeychainStoring {
    func read(_ account: String) -> KeychainRead
    func set(_ value: String, for account: String) -> Bool
    /// True when the item is gone afterwards, including when there was none.
    func delete(_ account: String) -> Bool
}

/// The real Keychain, service `com.timmal.push-to-talk`.
public struct SystemKeychain: KeychainStoring {
    public init() {}
    public func read(_ account: String) -> KeychainRead { Keychain.read(account) }
    public func set(_ value: String, for account: String) -> Bool { Keychain.set(value, for: account) }
    public func delete(_ account: String) -> Bool { Keychain.delete(account) }
}

/// Generic-password items for this app's secrets.
public enum Keychain {
    private static let service = "com.timmal.push-to-talk"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func read(_ account: String) -> KeychainRead {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                pttLog("Keychain read \(account): unreadable data")
                return .failed(errSecDecode)
            }
            return .found(value)
        case errSecItemNotFound:
            return .notFound
        default:
            pttLog("Keychain read \(account) failed: \(status)")
            return .failed(status)
        }
    }

    /// nil when the item is missing or could not be read.
    public static func string(for account: String) -> String? {
        if case .found(let value) = read(account) { return value }
        return nil
    }

    @discardableResult
    public static func set(_ value: String, for account: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            pttLog("Keychain update failed: \(status)")
            return false
        }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(add as CFDictionary, nil)
        if added != errSecSuccess { pttLog("Keychain add failed: \(added)") }
        return added == errSecSuccess
    }

    @discardableResult
    public static func delete(_ account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            pttLog("Keychain delete \(account) failed: \(status)")
            return false
        }
        return true
    }
}

/// The cloud API keys. All of them live in one Keychain item: the app is self-signed,
/// so macOS asks for the password once per item after every update, and one item means
/// one prompt. Read once, then served from memory: finalize asks on every dictation.
///
/// Thread-safe: the state is guarded by `condition`. The Keychain read runs outside the
/// lock in state `.loading` (it can wait for the user to answer a password prompt), and
/// only one read runs at a time: anyone asking meanwhile waits for its outcome instead
/// of triggering a second prompt.
public final class APIKeyStore: @unchecked Sendable {
    public enum Availability: Equatable {
        /// Not read from the Keychain yet.
        case notLoaded
        /// A read is running, possibly waiting on a password prompt.
        case loading
        case loaded
        /// The read failed (prompt denied or cancelled). Nothing is written in this
        /// state: the item may hold keys this session cannot see.
        case unavailable
    }

    static let keysAccount = "api-keys"
    /// One item per provider, before the keys were merged.
    static func legacyKeyAccount(_ provider: CloudProvider) -> String {
        "\(provider.rawValue)-api-key"
    }

    private let keychain: KeychainStoring
    private let condition = NSCondition()
    // Guarded by `condition`.
    private var keys: [String: String] = [:]
    private var state: Availability = .notLoaded
    /// Legacy items were merged in memory but the merged item couldn't be saved:
    /// they are deleted after the next successful save. Touched only by the one
    /// running read (state `.loading`) or under the lock.
    private var legacyItemsPending = false

    public init(keychain: KeychainStoring) {
        self.keychain = keychain
    }

    public var availability: Availability {
        condition.lock(); defer { condition.unlock() }
        return state
    }

    /// nil when there is no key, or when the Keychain couldn't be read. Reads the
    /// Keychain on the calling thread the first time, unless `loadInBackground` already
    /// has; while a read runs elsewhere it waits for that one.
    public func key(_ provider: CloudProvider) -> String? {
        condition.lock(); defer { condition.unlock() }
        loadIfNeeded(retry: false)
        return state == .loaded ? keys[provider.rawValue] : nil
    }

    /// The key if the keys are already loaded, else nil, also while a read is running.
    /// Never reads the Keychain and never waits: the one to use on the main thread,
    /// e.g. in a SwiftUI view body. Pair it with `loadInBackground` so the view is
    /// refreshed once the keys are in.
    public func loadedKey(_ provider: CloudProvider) -> String? {
        condition.lock(); defer { condition.unlock() }
        return state == .loaded ? keys[provider.rawValue] : nil
    }

    /// Like `key`, but the Keychain read, or the wait for one already running, happens
    /// off the calling thread: a caller on the main actor is suspended, not blocked, while
    /// a password prompt is up. Doesn't prompt again after a failed read.
    public func keyLoadingInBackground(_ provider: CloudProvider) async -> String? {
        condition.lock()
        if state == .loaded {
            defer { condition.unlock() }
            return keys[provider.rawValue]
        }
        condition.unlock()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            loadInBackground(retry: false) { _ in done.resume() }
        }
        return loadedKey(provider)
    }

    /// Reads the Keychain again unless the keys are already loaded.
    @discardableResult
    public func reload() -> Availability {
        condition.lock(); defer { condition.unlock() }
        loadIfNeeded(retry: true)
        return state
    }

    /// Reads the Keychain on a background queue and calls `completion` on the main
    /// queue. `retry` also re-reads after a failed read; without it a failed read
    /// stays failed, so warming up never prompts twice.
    public func loadInBackground(retry: Bool, completion: @escaping (Availability) -> Void) {
        condition.lock()
        let claimed = Self.needsLoad(state, retry: retry)
        // Claimed here, not on the queue, so `availability` reads `.loading` right away.
        if claimed { state = .loading }
        condition.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            if claimed { self.runLoad() }
            self.condition.lock()
            // Not claimed: another read may still be running; wait for its outcome.
            while self.state == .loading { self.condition.wait() }
            let outcome = self.state
            self.condition.unlock()
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// nil or empty removes the key. False when the Keychain is unavailable or the write
    /// failed; the keys in memory are then left as they were.
    @discardableResult
    public func setKey(_ key: String?, for provider: CloudProvider) -> Bool {
        condition.lock(); defer { condition.unlock() }
        loadIfNeeded(retry: true)
        // Writing without the other provider's key would drop it from the shared item.
        guard state == .loaded else {
            pttLog("Keychain: API keys unavailable, \(provider.rawValue) key not saved")
            return false
        }
        var updated = keys
        if let key, !key.isEmpty {
            updated[provider.rawValue] = key
        } else {
            updated[provider.rawValue] = nil
        }
        guard save(updated) else {
            pttLog("Keychain: \(provider.rawValue) key not saved")
            return false
        }
        keys = updated
        return true
    }

    private static func needsLoad(_ state: Availability, retry: Bool) -> Bool {
        state == .notLoaded || (retry && state == .unavailable)
    }

    /// Called and returns with the lock held; releases it while the Keychain is read.
    private func loadIfNeeded(retry: Bool) {
        // Waiting on a running read is as bad as reading: either way the main run loop,
        // and the event tap on it, stalls while a password prompt is up (HS-54).
        if Thread.isMainThread, state == .loading || Self.needsLoad(state, retry: retry) {
            pttLog("APIKeyStore: Keychain \(state == .loading ? "wait" : "read") on the main thread")
        }
        while state == .loading { condition.wait() }
        guard Self.needsLoad(state, retry: retry) else { return }
        state = .loading
        condition.unlock()
        runLoad()
        condition.lock()
    }

    /// Runs without the lock, in state `.loading` claimed by the caller; publishes the outcome.
    private func runLoad() {
        let loaded = readKeys()
        condition.lock()
        if let loaded {
            keys = loaded
            state = .loaded
        } else {
            state = .unavailable
        }
        condition.broadcast()
        condition.unlock()
    }

    /// nil when a read failed.
    private func readKeys() -> [String: String]? {
        switch keychain.read(Self.keysAccount) {
        case .found(let json):
            if let decoded = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) {
                return decoded
            }
            pttLog("Keychain: API keys item is not valid JSON, looking for legacy items")
        case .notFound:
            break
        case .failed(let status):
            pttLog("Keychain: API keys unavailable (\(status))")
            return nil
        }

        var merged: [String: String] = [:]
        for provider in CloudProvider.allCases {
            switch keychain.read(Self.legacyKeyAccount(provider)) {
            case .found(let key) where !key.isEmpty:
                merged[provider.rawValue] = key
            case .found, .notFound:
                break
            case .failed(let status):
                pttLog("Keychain: legacy \(provider.rawValue) key unavailable (\(status))")
                return nil
            }
        }
        if !merged.isEmpty {
            legacyItemsPending = true
            if save(merged) {
                pttLog("Keychain: merged \(merged.count) API key(s) into one item")
            }
        }
        return merged
    }

    @discardableResult
    private func save(_ keys: [String: String]) -> Bool {
        let saved: Bool
        if keys.isEmpty {
            saved = keychain.delete(Self.keysAccount)
        } else if let data = try? JSONEncoder().encode(keys) {
            saved = keychain.set(String(decoding: data, as: UTF8.self), for: Self.keysAccount)
        } else {
            saved = false
        }
        if saved, legacyItemsPending {
            CloudProvider.allCases.forEach { _ = keychain.delete(Self.legacyKeyAccount($0)) }
            legacyItemsPending = false
        }
        return saved
    }
}
