import Foundation

/// Роль автора сообщения в треде (роль `agent` бэкенда нормализуется в `assistant`).
public enum ChatRole: String, Codable, Sendable, Equatable {
    case user
    case assistant
    case system
}

/// Статус доставки исходящего пользовательского сообщения (нативное улучшение над вебом).
public enum ChatDeliveryStatus: String, Codable, Sendable, Equatable {
    case sending
    case sent
    case failed
}

/// Вложение сообщения (UI-форма).
public struct ChatAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let filename: String
    public let contentType: String
    public let size: Int64
    public let url: String

    public var isImage: Bool { contentType.hasPrefix("image/") }

    public init(id: String, filename: String, contentType: String, size: Int64, url: String) {
        self.id = id
        self.filename = filename
        self.contentType = contentType
        self.size = size
        self.url = url
    }
}

/// Публичная ссылка-источник под ответом ассистента.
public struct ChatSource: Codable, Sendable, Equatable, Identifiable {
    public var id: String { url }
    public let title: String
    public let url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

/// UI-модель сообщения треда. Локальные (оптимистичные) id — без дефиса; серверные — UUID с дефисами.
public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var role: ChatRole
    public var content: String
    public var authorName: String?
    public var authorAvatarURL: String?
    public var attachments: [ChatAttachment]
    public var sources: [ChatSource]
    public var deliveryStatus: ChatDeliveryStatus?
    public var createdAt: Date
    /// Признак локального (оптимистичного) сообщения, ещё не подтверждённого сервером.
    public var isLocal: Bool

    public init(
        id: String,
        role: ChatRole,
        content: String,
        authorName: String? = nil,
        authorAvatarURL: String? = nil,
        attachments: [ChatAttachment] = [],
        sources: [ChatSource] = [],
        deliveryStatus: ChatDeliveryStatus? = nil,
        createdAt: Date = Date(),
        isLocal: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.authorName = authorName
        self.authorAvatarURL = authorAvatarURL
        self.attachments = attachments
        self.sources = sources
        self.deliveryStatus = deliveryStatus
        self.createdAt = createdAt
        self.isLocal = isLocal
    }

    /// Признак «человек ответил» — наличие имени автора у ассистентского сообщения.
    public var isFromHumanAgent: Bool {
        role == .assistant && (authorName?.isEmpty == false)
    }
}
