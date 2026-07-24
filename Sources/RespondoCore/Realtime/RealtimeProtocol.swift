import Foundation

/// Нормализованное событие беседы, которое потребляет `ConversationController`.
/// Единая форма для WS, SSE и поллинга.
/// Частичное обновление уже существующего сообщения (статус доставки).
/// Бэкенд (chat_delivery.go::publishMessageUpdated) шлёт РОВНО
/// `{id, conversation_id, delivery_status[, delivery_error]}` — без role и content.
struct MessagePatch: Equatable {
    let id: String
    let deliveryStatus: String?
    let deliveryError: String?
}

enum RealtimeEvent: Equatable {
    case newMessage(MessageDTO)
    case statusChanged(newStatus: String)
    case typing(authorName: String?)
    case conversationUpdated(field: String?, lang: String?)
    case messageUpdated(MessagePatch)
    case campaignConversation(conversationId: String, message: MessageDTO?)
    /// Подходящие оверлеи (surveys in_modal + banners) — приходит на identify/launch.
    case overlayShow(items: [JSONValue])
    /// Подтверждение подписки на беседу.
    case subscribed(conversationId: String)
    /// Ошибка обработки клиентского кадра (`invalid conversation_id` / `conversation not found` / `forbidden`).
    case error(message: String)
}

/// Кодирование клиентских кадров и декодирование входящих событий WS/SSE.
enum RealtimeProtocol {
    // MARK: - Клиентские кадры

    static func identifyFrame(
        visitorId: String,
        email: String?,
        userId: String?,
        channelId: String?,
        sessionToken: String?,
        userHash: String?,
        lang: String?,
        conversationId: String?
    ) -> Data {
        var frame: [String: Any] = ["type": "identify", "visitor_id": visitorId]
        frame["email"] = nonEmpty(email)
        frame["user_id"] = nonEmpty(userId)
        frame["channel_id"] = nonEmpty(channelId)
        frame["session_token"] = nonEmpty(sessionToken)
        frame["user_hash"] = nonEmpty(userHash)
        frame["lang"] = nonEmpty(lang)
        frame["conversation_id"] = nonEmpty(conversationId)
        return encode(frame)
    }

    static func subscribeFrame(conversationId: String, sessionToken: String?, userHash: String?, visitorId: String?) -> Data {
        var frame: [String: Any] = ["type": "subscribe", "conversation_id": conversationId]
        frame["session_token"] = nonEmpty(sessionToken)
        frame["user_hash"] = nonEmpty(userHash)
        frame["visitor_id"] = nonEmpty(visitorId)
        return encode(frame)
    }

    static func readFrame(conversationId: String, sessionToken: String?, userHash: String?, visitorId: String?) -> Data {
        var frame: [String: Any] = ["type": "read", "conversation_id": conversationId]
        frame["session_token"] = nonEmpty(sessionToken)
        frame["user_hash"] = nonEmpty(userHash)
        frame["visitor_id"] = nonEmpty(visitorId)
        return encode(frame)
    }

    static func backgroundFrame() -> Data { encode(["type": "background"]) }
    static func foregroundFrame() -> Data { encode(["type": "foreground"]) }

    // MARK: - Декодирование входящих

    /// Разбирает текстовый кадр в `RealtimeEvent`. Возвращает nil для игнорируемых
    /// (tooltip.catalog / tour.catalog — веб-DOM-оверлеи) и нераспознанных кадров;
    /// overlay.show разбирается в `.overlayShow` (каталог оверлеев engagement-слоя).
    /// `subscribedConversationId` — беседа, на которую клиент подписан (для повторной
    /// фильтрации событий беседы по conversation_id).
    static func decode(_ text: String, subscribedConversationId: String?) -> RealtimeEvent? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        switch type {
        case "tooltip.catalog", "tour.catalog":
            // Мобильные SDK эти события игнорируют (веб-DOM-оверлеи).
            return nil
        case "overlay.show":
            // Каталог оверлеев (engagement-слой Ф3): items — сырые объекты кампаний.
            let items = ((object["data"] as? [String: Any])?["items"] as? [Any])?.map(JSONValue.from) ?? []
            return .overlayShow(items: items)
        case "subscribed":
            guard let cid = object["conversation_id"] as? String else { return nil }
            return .subscribed(conversationId: cid)
        case "error":
            let message = (object["data"] as? [String: Any])?["message"] as? String ?? "error"
            return .error(message: message)
        case "campaign_conversation":
            guard let cid = object["conversation_id"] as? String else { return nil }
            let message = decodeMessage(object["data"])
            return .campaignConversation(conversationId: cid, message: message)
        default:
            break
        }

        // События беседы: повторная клиентская фильтрация по conversation_id.
        if let subscribed = subscribedConversationId,
           let cid = object["conversation_id"] as? String,
           cid != subscribed {
            return nil
        }

        switch type {
        case "new_message":
            guard let message = decodeMessage(object["data"]) else { return nil }
            return .newMessage(message)
        case "message_updated":
            // data — ЧАСТИЧНЫЙ объект: бэкенд шлёт ровно {id, conversation_id,
            // delivery_status[, delivery_error]}, без role/content. Парсим как патч, не как сообщение.
            guard let data = object["data"] as? [String: Any], let id = data["id"] as? String else { return nil }
            return .messageUpdated(MessagePatch(
                id: id,
                deliveryStatus: data["delivery_status"] as? String,
                deliveryError: data["delivery_error"] as? String
            ))
        case "status_changed":
            guard let status = (object["data"] as? [String: Any])?["new_status"] as? String else { return nil }
            return .statusChanged(newStatus: status)
        case "typing":
            let author = (object["data"] as? [String: Any])?["author_name"] as? String
            return .typing(authorName: author)
        case "conversation_updated":
            let payload = object["data"] as? [String: Any]
            return .conversationUpdated(field: payload?["field"] as? String, lang: payload?["lang"] as? String)
        default:
            return nil
        }
    }

    private static func decodeMessage(_ value: Any?) -> MessageDTO? {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(MessageDTO.self, from: data)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func encode(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }
}
