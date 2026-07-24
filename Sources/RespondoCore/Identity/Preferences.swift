import Foundation

/// Непарольное персистентное хранилище (язык, собранный email, seen-флаги кампаний, блоб беседы).
/// Боевая реализация — UserDefaults; в тестах — in-memory.
protocol Preferences: AnyObject, Sendable {
    func string(forKey key: String) -> String?
    func data(forKey key: String) -> Data?
    func set(_ value: String, forKey key: String)
    func set(_ value: Data, forKey key: String)
    func removeValue(forKey key: String)
    func removeAll(withPrefix prefix: String)
    /// Все ключи с указанным префиксом (для точечной чистки при reset).
    func keys(withPrefix prefix: String) -> [String]
}

/// UserDefaults-реализация.
final class UserDefaultsPreferences: Preferences, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func set(_ value: String, forKey key: String) { defaults.set(value, forKey: key) }
    func set(_ value: Data, forKey key: String) { defaults.set(value, forKey: key) }
    func removeValue(forKey key: String) { defaults.removeObject(forKey: key) }

    func removeAll(withPrefix prefix: String) {
        for key in keys(withPrefix: prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    func keys(withPrefix prefix: String) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
    }
}

/// In-memory реализация — для тестов.
final class InMemoryPreferences: Preferences, @unchecked Sendable {
    private var strings: [String: String] = [:]
    private var datas: [String: Data] = [:]
    private let lock = NSLock()

    init() {}

    func string(forKey key: String) -> String? { lock.withLock { strings[key] } }
    func data(forKey key: String) -> Data? { lock.withLock { datas[key] } }
    func set(_ value: String, forKey key: String) { lock.withLock { strings[key] = value } }
    func set(_ value: Data, forKey key: String) { lock.withLock { datas[key] = value } }

    func removeValue(forKey key: String) {
        lock.withLock { strings[key] = nil; datas[key] = nil }
    }

    func removeAll(withPrefix prefix: String) {
        lock.withLock {
            for key in strings.keys where key.hasPrefix(prefix) { strings[key] = nil }
            for key in datas.keys where key.hasPrefix(prefix) { datas[key] = nil }
        }
    }

    func keys(withPrefix prefix: String) -> [String] {
        lock.withLock {
            Array(Set(strings.keys).union(datas.keys)).filter { $0.hasPrefix(prefix) }
        }
    }
}

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
