import Foundation

/// Личность визитёра. Все поля опциональны — пустой `RespondoIdentity()` валиден
/// (анонимный визитёр). `metadata` — технический контекст сессии, к которому SDK
/// автоматически домешивает поля устройства (см. `DeviceContext`); `properties` —
/// атрибуты контакта, уходящие в профиль. Host-значения приоритетнее автозначений.
///
/// `identify()` с `userId` или `email` создаёт контакт сразу (`POST /widget/identify`),
/// даже без свойств — как вход пользователя в Intercom Messenger: человек, который
/// ни разу не писал в чат, всё равно есть в контактах, сегментах и сериях.
/// `properties`, `languageOverride` и `signedUpAt` доходят до профиля тем же
/// запросом, без ожидания первого сообщения — как `updateUser` у Intercom.
public struct RespondoIdentity: Sendable, Equatable {
    public var userId: String?
    public var email: String?
    public var name: String?
    public var userHash: String?
    public var metadata: [String: String]
    public var properties: [String: String]
    /// Явный язык контакта (BCP-47, напр. `de`, `pt-BR`) — Intercom `languageOverride`.
    /// Главнее языка устройства и определённого по тексту: на нём говорят беседы,
    /// рассылки и письма контакту. Уходит свойством `language_override`; nil не
    /// снимает уже заданный язык (снять — в профиле контакта или через API).
    public var languageOverride: String?
    /// Когда человек зарегистрировался в вашем продукте — Intercom `signedUpAt`
    /// (`created_at`). Уходит в `signed_up_at` контакта (Unix-секунды). Не передан —
    /// дата регистрации остаётся пустой: первый запуск приложения регистрацией не
    /// считается. Подписанная личность (`userHash`) переписывает известную дату,
    /// неподписанная — только заполняет пустую.
    public var signedUpAt: Date?

    public init(
        userId: String? = nil,
        email: String? = nil,
        name: String? = nil,
        userHash: String? = nil,
        metadata: [String: String] = [:],
        properties: [String: String] = [:],
        languageOverride: String? = nil,
        signedUpAt: Date? = nil
    ) {
        self.userId = userId
        self.email = email
        self.name = name
        self.userHash = userHash
        self.metadata = metadata
        self.properties = properties
        self.languageOverride = languageOverride
        self.signedUpAt = signedUpAt
    }

    /// `signedUpAt` в Unix-секундах (тело `signed_up_at`); nil — не передан.
    var signedUpAtSeconds: Int64? {
        guard let signedUpAt else { return nil }
        let seconds = signedUpAt.timeIntervalSince1970.rounded(.down)
        guard seconds.isFinite else { return nil }
        return Int64(seconds)
    }

    /// Свойства, которые уходят на сервер: `properties` плюс `language_override`
    /// из `languageOverride` (типизированное поле главнее одноимённого ключа).
    var effectiveProperties: [String: String] {
        var out = properties
        if let language = languageOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            out[Self.languageOverrideKey] = language
        }
        return out
    }

    /// Ключ свойства явного языка контакта (сервер: `language_override`).
    static let languageOverrideKey = "language_override"

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
