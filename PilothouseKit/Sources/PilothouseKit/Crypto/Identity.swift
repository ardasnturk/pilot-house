import Foundation
import Synchronization
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A long-term Curve25519 (X25519) identity key pair.
///
/// The Mac has one; every phone has one. Public keys are exchanged once during
/// QR pairing and pinned afterwards (see SECURITY.md).
public struct IdentityKeyPair: Sendable, Hashable {
    /// Raw 32-byte X25519 private key. Never leaves the Keychain except in memory.
    public let rawPrivateKey: Data
    /// Raw 32-byte X25519 public key.
    public let publicKey: Data

    public init(rawPrivateKey: Data) throws {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
        self.rawPrivateKey = key.rawRepresentation
        publicKey = key.publicKey.rawRepresentation
    }

    public static func generate() -> IdentityKeyPair {
        let key = Curve25519.KeyAgreement.PrivateKey()
        // A freshly generated key always round-trips; the force-free fallback keeps
        // the API non-throwing without `try!`.
        if let pair = try? IdentityKeyPair(rawPrivateKey: key.rawRepresentation) {
            return pair
        }
        preconditionFailure("CryptoKit produced an invalid Curve25519 key")
    }

    /// Stable short identifier derived from the public key.
    public var fingerprint: String { KeyFingerprint.identifier(for: publicKey) }
}

/// Derivations of a public key that are safe to show or store.
public enum KeyFingerprint {
    /// `base64url(SHA-256(publicKey)[0..<16])` — used as Mac ID / device ID.
    public static func identifier(for publicKey: Data) -> String {
        Base64URL.encode(Data(SHA256.hash(data: publicKey).prefix(16)))
    }

    /// Human-comparable code, e.g. `7KQ2-M9XD-4TPA`. Shown on both screens during
    /// pairing so a cautious user can compare them.
    public static func displayCode(for publicKey: Data) -> String {
        let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        let digest = Array(SHA256.hash(data: publicKey))
        var characters: [Character] = []
        var buffer: UInt32 = 0
        var bits = 0
        var index = 0
        while characters.count < 12 {
            if bits < 5 {
                buffer = (buffer << 8) | UInt32(digest[index])
                index += 1
                bits += 8
            }
            bits -= 5
            characters.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1F)])
        }
        let groups = stride(from: 0, to: 12, by: 4).map { String(characters[$0..<$0 + 4]) }
        return groups.joined(separator: "-")
    }
}

/// Persists the local identity key.
public protocol IdentityStore: Sendable {
    /// Returns the stored identity, creating and storing one on first use.
    func loadOrCreateIdentity() throws -> IdentityKeyPair
    /// Deletes the stored identity (pairings become invalid).
    func deleteIdentity() throws
}

/// Volatile store for tests and the demo server.
public final class InMemoryIdentityStore: IdentityStore {
    private let identity: Mutex<IdentityKeyPair?>

    public init(identity: IdentityKeyPair? = nil) {
        self.identity = Mutex(identity)
    }

    public func loadOrCreateIdentity() throws -> IdentityKeyPair {
        identity.withLock { stored in
            if let stored { return stored }
            let created = IdentityKeyPair.generate()
            stored = created
            return created
        }
    }

    public func deleteIdentity() throws {
        identity.withLock { $0 = nil }
    }
}

/// File-backed identity store for hosts without a Keychain (the Linux server,
/// D-110). The key is kept as base64url text in a file only its owner can
/// read (`0600`, folder `0700`).
public struct FileIdentityStore: IdentityStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public enum FileStoreError: Error, Sendable, Equatable {
        case invalidData
        case writeFailed(String)
    }

    public func loadOrCreateIdentity() throws -> IdentityKeyPair {
        if FileManager.default.fileExists(atPath: url.path) {
            let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let raw = Base64URL.decode(text) else { throw FileStoreError.invalidData }
            return try IdentityKeyPair(rawPrivateKey: raw)
        }
        let identity = IdentityKeyPair.generate()
        try Self.writePrivately(Data(Base64URL.encode(identity.rawPrivateKey).utf8), to: url)
        return identity
    }

    public func deleteIdentity() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Writes `data` atomically with permissions `0600`, creating the folder (`0700`).
    public static func writePrivately(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw FileStoreError.writeFailed(url.path)
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

#if canImport(Security)
import Security

/// Keychain-backed identity store.
///
/// The private key is a generic-password item, accessible after first unlock,
/// never synchronised and never migrated to another device. On macOS the
/// login keychain is used (works for Developer ID apps without a provisioning
/// profile; docs/DECISIONS.md D-020).
public struct KeychainIdentityStore: IdentityStore {
    public let service: String
    public let account: String

    public init(service: String, account: String = "identity.x25519") {
        self.service = service
        self.account = account
    }

    public enum KeychainError: Error, Sendable, Equatable {
        case unexpectedStatus(Int32)
        case invalidData
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func loadOrCreateIdentity() throws -> IdentityKeyPair {
        if let existing = try load() { return existing }
        let identity = IdentityKeyPair.generate()
        var attributes = baseQuery
        attributes[kSecValueData as String] = identity.rawPrivateKey
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse
        attributes[kSecAttrLabel as String] = "Pilothouse identity key"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try load() {
            return existing
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return identity
    }

    public func deleteIdentity() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func load() throws -> IdentityKeyPair? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data else { throw KeychainError.invalidData }
        return try IdentityKeyPair(rawPrivateKey: data)
    }
}

/// Stores small secrets (the optional Anthropic API key) in the Keychain.
public struct KeychainSecretStore: Sendable {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String?, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainIdentityStore.KeychainError.unexpectedStatus(status) }
    }
}
#endif
