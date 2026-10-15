import Foundation
import CryptoKit
import Security

/// Encrypts private data at rest (clipboard, journal, inbox history). The key lives in the Keychain.
enum Vault {
    private static let service = "com.nav.deck.vault"

    static let key: SymmetricKey = {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "main", kSecReturnData as String: true]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return SymmetricKey(data: data)
        }
        let new = SymmetricKey(size: .bits256)
        let data = new.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: "main", kSecValueData as String: data,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(add as CFDictionary, nil)
        return new
    }()

    static func seal(_ data: Data) throws -> Data {
        try AES.GCM.seal(data, using: key).combined!
    }

    static func open(_ data: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
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
