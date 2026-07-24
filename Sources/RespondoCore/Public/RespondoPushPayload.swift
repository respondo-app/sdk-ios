import Foundation

/// Разобранный payload входящего пуша Respondo.
/// Host-приложение добывает «сырой» словарь из APNs `userInfo` и отдаёт его в `Respondo.handlePush`.
/// SDK распознаёт «свой» пуш по корневому ключу `respondo` в payload и извлекает поля.
public struct RespondoPushPayload: Sendable, Equatable {
    /// `message` — ответ оператора/бота; `campaign` — outbound push-кампания.
    public enum Kind: String, Sendable, Equatable {
        case message
        case campaign
    }

    public let kind: Kind
    public let conversationId: String?
    public let messageId: String?
    public let deliveryId: String?
    public let deepLink: String?
    public let title: String?
    public let body: String?
    public let authorName: String?
    /// Плоское строковое представление вложенных данных (для host-логики/отладки).
    public let raw: [String: String]

    /// Разбор из APNs `userInfo`. nil, если это не пуш Respondo.
    public static func from(_ userInfo: [AnyHashable: Any]) -> RespondoPushPayload? {
        // Полезная нагрузка Respondo всегда лежит под корневым ключом `respondo`.
        let container = extractRespondo(from: userInfo)
        guard let container else { return nil }

        guard
            let typeString = container["type"] as? String,
            let kind = Kind(rawValue: typeString)
        else { return nil }

        let data = container["data"] as? [String: Any] ?? [:]

        var flat: [String: String] = [:]
        func flatten(_ dict: [String: Any], prefix: String) {
            for (key, value) in dict {
                let composed = prefix.isEmpty ? key : "\(prefix).\(key)"
                if let nested = value as? [String: Any] {
                    flatten(nested, prefix: composed)
                } else {
                    flat[composed] = String(describing: value)
                }
            }
        }
        flatten(container, prefix: "")

        return RespondoPushPayload(
            kind: kind,
            conversationId: container["conversation_id"] as? String,
            messageId: container["message_id"] as? String,
            deliveryId: container["delivery_id"] as? String,
            deepLink: container["deep_link"] as? String,
            title: data["title"] as? String,
            body: data["body"] as? String,
            authorName: data["author_name"] as? String,
            raw: flat
        )
    }

    /// Достаёт словарь `respondo` из userInfo: он может прийти как вложенный объект (APNs)
    /// или как JSON-строка (FCM `data.respondo`).
    private static func extractRespondo(from userInfo: [AnyHashable: Any]) -> [String: Any]? {
        if let nested = userInfo["respondo"] as? [String: Any] {
            return nested
        }
        if let jsonString = userInfo["respondo"] as? String,
           let data = jsonString.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed
        }
        return nil
    }

    public init(
        kind: Kind,
        conversationId: String?,
        messageId: String?,
        deliveryId: String? = nil,
        deepLink: String? = nil,
        title: String?,
        body: String?,
        authorName: String? = nil,
        raw: [String: String]
    ) {
        self.kind = kind
        self.conversationId = conversationId
        self.messageId = messageId
        self.deliveryId = deliveryId
        self.deepLink = deepLink
        self.title = title
        self.body = body
        self.authorName = authorName
        self.raw = raw
    }
}
