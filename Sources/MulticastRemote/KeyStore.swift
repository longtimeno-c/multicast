import CryptoKit
import Foundation
import Security

/// A pairing: the long-term key shared with one peer. The hub keeps one per paired remote
/// (keyed by remote id); a remote keeps one per hub (keyed by hub id).
public struct PairingRecord: Codable, Sendable, Equatable, Identifiable {
    public var peerID: String
    public var peerName: String
    /// 32 bytes. Secret: never logged, never sent.
    public var key: Data
    public var pairedAt: Date

    public var id: String { peerID }

    public init(peerID: String, peerName: String, key: Data, pairedAt: Date = Date()) {
        self.peerID = peerID
        self.peerName = peerName
        self.key = key
        self.pairedAt = pairedAt
    }

    var symmetricKey: SymmetricKey { SymmetricKey(data: key) }
}

/// Where pairing keys live. `KeychainPairingKeyStore` in the apps, `InMemoryPairingKeyStore` in tests.
public protocol PairingKeyStore: AnyObject, Sendable {
    func record(for peerID: String) throws -> PairingRecord?
    func save(_ record: PairingRecord) throws
    func remove(peerID: String) throws
    func allRecords() throws -> [PairingRecord]
}

public final class InMemoryPairingKeyStore: PairingKeyStore, @unchecked Sendable {
    private let records = Locked<[String: PairingRecord]>([:])

    public init(_ initial: [PairingRecord] = []) {
        records.withLock { r in for rec in initial { r[rec.peerID] = rec } }
    }

    public func record(for peerID: String) throws -> PairingRecord? { records.value[peerID] }
    public func save(_ record: PairingRecord) throws { records.withLock { $0[record.peerID] = record } }
    public func remove(peerID: String) throws { records.withLock { _ = $0.removeValue(forKey: peerID) } }
    public func allRecords() throws -> [PairingRecord] { records.value.values.sorted { $0.pairedAt < $1.pairedAt } }
}

public struct KeychainError: Error, Equatable, LocalizedError {
    public var status: OSStatus
    public var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// Pairing keys as generic-password items: one per peer, account = peer id, this device only,
/// never synced. Use different `service` names for the hub's and the remote's stores.
public final class KeychainPairingKeyStore: PairingKeyStore, @unchecked Sendable {
    public let service: String
    private let useDataProtectionKeychain: Bool

    /// `useDataProtectionKeychain` selects the modern keychain on macOS, which needs the app to
    /// be signed with a keychain access group; it is always used on iOS.
    public init(service: String, useDataProtectionKeychain: Bool = false) {
        self.service = service
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    private func baseQuery() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        #if os(macOS)
        if useDataProtectionKeychain { q[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return q
    }

    public func record(for peerID: String) throws -> PairingRecord? {
        var q = baseQuery()
        q[kSecAttrAccount as String] = peerID
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return try? JSONDecoder().decode(PairingRecord.self, from: data)
    }

    public func save(_ record: PairingRecord) throws {
        let data = try JSONEncoder().encode(record)
        var q = baseQuery()
        q[kSecAttrAccount as String] = record.peerID
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: "Multicast pairing"]
        let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            q.merge(update) { $1 }
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            q[kSecAttrSynchronizable as String] = false
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func remove(peerID: String) throws {
        var q = baseQuery()
        q[kSecAttrAccount as String] = peerID
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public func allRecords() throws -> [PairingRecord] {
        var q = baseQuery()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = out as? [[String: Any]] else { throw KeychainError(status: status) }
        let accounts = items.compactMap { $0[kSecAttrAccount as String] as? String }
        return try accounts.compactMap { try record(for: $0) }.sorted { $0.pairedAt < $1.pairedAt }
    }
}

/// Pairing keys in one JSON file, readable and writable by this user only (mode 0600). For the
/// command-line tools and scripted tests; the apps keep keys in the Keychain.
public final class FilePairingKeyStore: PairingKeyStore, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    private func load() -> [String: PairingRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: PairingRecord].self, from: data)) ?? [:]
    }

    private func write(_ records: [String: PairingRecord]) throws {
        let data = try JSONEncoder().encode(records)
        let tmp = url.appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    public func record(for peerID: String) throws -> PairingRecord? { lock.withLock { load()[peerID] } }
    public func save(_ record: PairingRecord) throws {
        try lock.withLock { var r = load(); r[record.peerID] = record; try write(r) }
    }
    public func remove(peerID: String) throws { try lock.withLock { var r = load(); r[peerID] = nil; try write(r) } }
    public func allRecords() throws -> [PairingRecord] {
        lock.withLock { load().values.sorted { $0.pairedAt < $1.pairedAt } }
    }
}

/// Serves pairing records from memory and does every read and write of the store behind it on
/// one serial dispatch queue, so no caller ever waits on the store.
///
/// For the hub's Keychain store: on an ad hoc signed build `SecItemCopyMatching` can block its
/// thread until someone answers a Keychain access prompt at the Mac. Called from the handshake,
/// that parked a Swift concurrency thread per reconnecting remote; with this cache a handshake
/// that arrives before the records are loaded is refused at once (`NotReady`, the remote retries
/// with backoff), and nothing in the hub stalls on the prompt.
///
/// Writes update memory at once and reach the store in order on the queue; a failed write is
/// kept in `lastWriteError` (the pairing still works until the hub quits).
public final class CachingPairingKeyStore: PairingKeyStore, @unchecked Sendable {
    public struct NotReady: Error, LocalizedError {
        public var errorDescription: String? { "The pairing keys aren\u{2019}t loaded yet." }
    }

    private struct State {
        var loaded: [String: PairingRecord]?
        /// Saves (non-nil) and removals (nil) made before the load finished, applied over it.
        var changes: [String: PairingRecord?] = [:]
        var loading = false
        var loadWaiters: [CheckedContinuation<Void, Never>] = []
        var lastLoadError: String?
        var lastWriteError: String?
    }

    private let backing: any PairingKeyStore
    private let queue = DispatchQueue(label: "multicast.pairing-keys")
    private let state = Locked(State())

    public init(wrapping backing: any PairingKeyStore) {
        self.backing = backing
    }

    public var isLoaded: Bool { state.value.loaded != nil }
    public var lastWriteError: String? { state.value.lastWriteError }

    /// Starts loading (if not loaded or loading) and returns once the load attempt ends.
    public func load() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s -> Bool in
                if s.loaded != nil { return true }
                s.loadWaiters.append(c)
                return false
            }
            if ready { c.resume() } else { startLoading() }
        }
    }

    private func startLoading() {
        let start = state.withLock { s -> Bool in
            guard s.loaded == nil, !s.loading else { return false }
            s.loading = true
            return true
        }
        guard start else { return }
        queue.async { [backing, state] in
            let result = Result { try backing.allRecords() }
            let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.loading = false
                switch result {
                case .success(let records):
                    var all = Dictionary(records.map { ($0.peerID, $0) }, uniquingKeysWith: { $1 })
                    for (id, change) in s.changes { all[id] = change }
                    s.loaded = all
                    s.changes = [:]
                    s.lastLoadError = nil
                case .failure(let error):
                    s.lastLoadError = error.localizedDescription
                }
                defer { s.loadWaiters.removeAll() }
                return s.loadWaiters
            }
            for w in waiters { w.resume() }
        }
    }

    public func record(for peerID: String) throws -> PairingRecord? {
        let answer = state.withLock { s -> PairingRecord?? in
            if let change = s.changes[peerID] { return .some(change) }
            guard let loaded = s.loaded else { return nil }
            return .some(loaded[peerID])
        }
        guard let answer else {
            startLoading()   // retries a load that failed earlier
            throw NotReady()
        }
        return answer
    }

    public func save(_ record: PairingRecord) throws {
        state.withLock { s in
            if s.loaded != nil { s.loaded?[record.peerID] = record } else { s.changes[record.peerID] = .some(record) }
        }
        queue.async { [backing, state] in
            do { try backing.save(record) } catch {
                state.withLock { $0.lastWriteError = error.localizedDescription }
            }
        }
    }

    public func remove(peerID: String) throws {
        state.withLock { s in
            if s.loaded != nil { s.loaded?[peerID] = nil } else { s.changes[peerID] = .some(nil) }
        }
        queue.async { [backing, state] in
            do { try backing.remove(peerID: peerID) } catch {
                state.withLock { $0.lastWriteError = error.localizedDescription }
            }
        }
    }

    public func allRecords() throws -> [PairingRecord] {
        guard let loaded = state.value.loaded else {
            startLoading()
            throw NotReady()
        }
        return loaded.values.sorted { $0.pairedAt < $1.pairedAt }
    }

    /// Returns once every write issued so far has reached the store (tests, quitting).
    public func flush() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
    }
}
