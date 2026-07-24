import Foundation

/// Мост между `ConversationController` (тред) и `RespondoEngine` (жизненный цикл,
/// наблюдаемые, реалтайм). Реализуется движком. Все методы — на главном акторе.
@MainActor
protocol ConversationHost: AnyObject {
    /// Открыта ли модалка чата сейчас (влияет на unread и read-квитанции).
    var isPanelOpen: Bool { get }
    /// Текущие параметры владения беседой.
    func ownership() -> OwnershipParams
    /// Текущая личность визитёра.
    func currentIdentity() -> RespondoIdentity
    /// Автоконтекст устройства для `metadata`.
    func autoMetadata() -> [String: String]
    /// Беседа/токен изменились — движок обновляет подписку, хранилище и push-регистрацию.
    func conversationDidChange(id: String?, sessionToken: String?)
    /// Состояние эскалации изменилось (влияет на интервал поллинга).
    func escalationDidChange(_ escalated: Bool)
    /// Увеличить счётчик непрочитанных.
    func bumpUnread(by count: Int)
    /// Обнулить счётчик непрочитанных.
    func resetUnread()
    /// Локаль беседы сменилась на лету.
    func languageDidChange(_ lang: String)
    /// Пользователь тапнул ссылку. Вернуть true, если host сам её открыл.
    func requestOpenURL(_ url: URL) -> Bool
}
