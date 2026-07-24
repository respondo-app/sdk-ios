import Foundation

/// Преобразование серверного `MessageDTO` в UI-модель `ChatMessage`.
enum MessageMapper {
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Нормализует роль: `agent`/`visitor` учитываются на уровне фильтрации;
    /// в UI попадают только user/assistant/system, роль `agent` → `assistant`.
    static func normalizedRole(_ raw: String) -> ChatRole {
        switch raw {
        case "user", "visitor": return .user
        case "system": return .system
        default: return .assistant // assistant, agent, bot → assistant
        }
    }

    static func parseDate(_ raw: String?) -> Date {
        guard let raw, !raw.isEmpty else { return Date() }
        return isoFormatter.date(from: raw) ?? isoFormatterNoFraction.date(from: raw) ?? Date()
    }

    /// Как `parseDate`, но возвращает nil, если строка пуста или не распознана
    /// (для полей, где отсутствие даты значимо, напр. `published_at`).
    static func parseDateOptional(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return isoFormatter.date(from: raw) ?? isoFormatterNoFraction.date(from: raw)
    }

    /// Только публичные http(s)-источники (внутренние RAG бэкенд вырезает; дублируем guard).
    static func publicSources(_ dtos: [SourceDTO]?) -> [ChatSource] {
        (dtos ?? []).compactMap { dto in
            guard let title = dto.title, !title.isEmpty,
                  let urlString = dto.url,
                  let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            return ChatSource(title: title, url: urlString)
        }
    }

    static func attachments(_ dtos: [ChatAttachmentDTO]?) -> [ChatAttachment] {
        (dtos ?? []).map {
            ChatAttachment(id: $0.id, filename: $0.filename, contentType: $0.contentType, size: $0.size, url: $0.url)
        }
    }

    static func toChatMessage(_ dto: MessageDTO) -> ChatMessage {
        ChatMessage(
            id: dto.id,
            role: normalizedRole(dto.role),
            content: dto.content,
            authorName: dto.authorName,
            authorAvatarURL: dto.authorAvatarURL,
            attachments: attachments(dto.attachments),
            sources: publicSources(dto.sources),
            deliveryStatus: nil,
            createdAt: parseDate(dto.createdAt),
            isLocal: false
        )
    }
}
