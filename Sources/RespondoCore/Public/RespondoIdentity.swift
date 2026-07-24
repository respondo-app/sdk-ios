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
