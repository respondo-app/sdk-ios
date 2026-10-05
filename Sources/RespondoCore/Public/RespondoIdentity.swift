import Foundation

/// Личность визитёра. Все поля опциональны — пустой `RespondoIdentity()` валиден
/// (анонимный визитёр). `metadata` — технический контекст сессии, к которому SDK
/// автоматически домешивает поля устройства (см. `DeviceContext`); `properties` —
/// атрибуты контакта, уходящие в профиль. Host-значения приоритетнее автозначений.
public struct RespondoIdentity: Sendable, Equatable {
    public var userId: String?
    public var email: String?
    public var name: String?
    public var userHash: String?
    public var metadata: [String: String]
    public var properties: [String: String]

    public init(
        userId: String? = nil,
        email: String? = nil,
        name: String? = nil,
        userHash: String? = nil,
        metadata: [String: String] = [:],
        properties: [String: String] = [:]
    ) {
        self.userId = userId
        self.email = email
        self.name = name
        self.userHash = userHash
        self.metadata = metadata
        self.properties = properties
    }

    /// Пустая ли личность (нет ни одного разрешающего контакт поля).
    public var isAnonymous: Bool {
        (userId ?? "").isEmpty && (email ?? "").isEmpty && userHash == nil
    }
}

extension RespondoIdentity {
    /// Ключ контакта для `identify()`: userId и email (email без регистра,
    /// пробелы по краям не значимы). Смена ключа — другой контакт; имя,
    /// `userHash` и свойства контакт не меняют.
    struct ContactKey: Equatable {
        let userId: String?
        let email: String?

        /// Ключ по сырым полям (из `identify()` или штампа `overlay.show`):
        /// пустое после обрезки пробелов — поля нет, email без регистра.
        init(userId: String?, email: String?) {
            func clean(_ value: String?) -> String? {
                guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                    return nil
                }
                return trimmed
            }
            self.userId = clean(userId)
            self.email = clean(email)?.lowercased()
        }

        /// Анонимный визитёр: ни userId, ни email.
        var isAnonymous: Bool { userId == nil && email == nil }
    }

    var contactKey: ContactKey { ContactKey(userId: userId, email: email) }
}
