import Foundation
import CryptoKit
import Security

/// Encrypts private data at rest (clipboard, journal, private notes). The key lives in the Keychain.
/// When the key can't be read or stored, `key` is nil and nothing is sealed or opened: callers keep data as it is.
enum Vault {
    struct Unavailable: Error {}

    private static let service = "com.nav.deck.vault"
    private static let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                              kSecAttrAccount as String: "main"]
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: SymmetricKey?

    /// Tests swap this to simulate a locked or broken Keychain.
    nonisolated(unsafe) static var keyProvider: () -> SymmetricKey? = keychainKey

    static var key: SymmetricKey? { keyProvider() }

    /// Reads the key, making one only when the Keychain says there is none yet. A failed read is retried next time.
    private static func keychainKey() -> SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        var found: CFTypeRef?
        let status = SecItemCopyMatching(item.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &found)
        if status == errSecSuccess, let data = found as? Data, data.count == 32 {
            cached = SymmetricKey(data: data)
            return cached
        }
        guard status == errSecItemNotFound else { return nil }   // locked, denied or damaged: never replace the key
        let new = SymmetricKey(size: .bits256)
        let add = item.merging([kSecValueData as String: new.withUnsafeBytes { Data($0) },
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 }
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        cached = new
        return new
    }

    /// Erase all: deletes the key, so a new one is made next time.
    static func deleteKey() {
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(item as CFDictionary)
        cached = nil
    }

    static func seal(_ data: Data) throws -> Data {
        guard let key else { throw Unavailable() }
        return try AES.GCM.seal(data, using: key).combined!
    }

    static func open(_ data: Data) throws -> Data {
        guard let key else { throw Unavailable() }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }

    static func seal(_ text: String) throws -> Data { try seal(Data(text.utf8)) }
    static func openText(_ data: Data) -> String? { (try? open(data)).flatMap { String(data: $0, encoding: .utf8) } }

    /// Where Deck keeps its own files: ~/Library/Application Support/Deck
    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Deck")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
