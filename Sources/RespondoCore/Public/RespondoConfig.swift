import Foundation

/// Размер листа чата. Управляет высотой bottom-sheet (детентом).
public enum RespondoChatSize: String, Sendable, Equatable {
    case compact
    case `default`
    case large
}

/// Нативное представление внешнего вида чата.
/// Полная семантика полей и маппинг из `/widget/config` — в `sdks/spec/theming.md`.
public struct RespondoTheme: Sendable, Equatable {
    public var primaryColor: RespondoColor?
    public var title: String?
    public var greeting: String?
    public var logoURL: URL?
    public var avatarURL: URL?
    public var chatSize: RespondoChatSize?
    public var cornerRadius: CGFloat?

    public init(
        primaryColor: RespondoColor? = nil,
        title: String? = nil,
        greeting: String? = nil,
        logoURL: URL? = nil,
        avatarURL: URL? = nil,
        chatSize: RespondoChatSize? = nil,
        cornerRadius: CGFloat? = nil
    ) {
        self.primaryColor = primaryColor
        self.title = title
        self.greeting = greeting
        self.logoURL = logoURL
        self.avatarURL = avatarURL
        self.chatSize = chatSize
        self.cornerRadius = cornerRadius
    }
}

/// Неизменяемая конфигурация SDK. Передаётся один раз в `Respondo.initialize`.
/// `agentId` обязателен ВСЕГДА: WebSocket требует его в URL, а `POST /api/v1/chat`
/// валидирует `agent_id` как `required,uuid`. Чисто humans-only веб-сценарий
/// (канал с `agent_id = NULL`) мобильным SDK не поддерживается. `channelId`
/// опционален и, если задан, авторитетно уточняет канал/оформление поверх агента.
public struct RespondoConfig: Sendable, Equatable {
    public let agentId: String
    public var channelId: String?
    /// Дефолт: https://api.respondo.ai
    public var baseUrl: String?
    /// BCP-47; nil → системная локаль.
    public var locale: String?
    public var themeOverride: RespondoTheme?

    public init(
        agentId: String,
        channelId: String? = nil,
        baseUrl: String? = nil,
        locale: String? = nil,
        themeOverride: RespondoTheme? = nil
    ) {
        self.agentId = agentId
        self.channelId = channelId
        self.baseUrl = baseUrl
        self.locale = locale
        self.themeOverride = themeOverride
    }

    /// Задан ли обязательный `agentId` (после обрезки пробелов).
    var hasValidAgentId: Bool {
        !agentId.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
