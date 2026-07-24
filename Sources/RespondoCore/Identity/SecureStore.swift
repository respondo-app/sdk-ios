import Foundation
import Security

/// Защищённое хранилище секретов (visitor_id, session_token).
/// Боевая реализация — Keychain; в тестах подменяется in-memory.
protocol SecureStore: AnyObject, Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
    func removeValue(forKey key: String)
    /// Удаляет все ключи с указанным префиксом (для `reset()`).
    func removeAll(withPrefix prefix: String)
}

/// Keychain-реализация (`kSecClassGenericPassword`, доступ после первого разблокирования).
final class KeychainSecureStore: SecureStore, @unchecked Sendable {
    private let serviceName: String
    private let lock = NSLock()

    init(serviceName: String = "ai.respondo.sdk") {
        self.serviceName = serviceName
    }

    func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        let data = Data(value.utf8)
        let query = baseQuery(key)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    func removeValue(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    func removeAll(withPrefix prefix: String) {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) else { continue }
            SecItemDelete(baseQuery(account) as CFDictionary)
        }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]
    }
}

/// In-memory реализация — для юнит-тестов и как фолбэк при заблокированном Keychain.
final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    init() {}

    func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(_ value: String, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    func removeValue(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }

    func removeAll(withPrefix prefix: String) {
        lock.lock(); defer { lock.unlock() }
        for key in storage.keys where key.hasPrefix(prefix) {
            storage[key] = nil
        }
    }
}
