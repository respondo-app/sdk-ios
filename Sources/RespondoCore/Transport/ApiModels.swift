import Foundation

// DTO REST-контракта `/api/v1/widget/*` и `/api/v1/chat`.
// Ловушка контракта: тело запроса — snake_case, но вложенный объект `identity`
// сериализуется в camelCase (как принимает бэкенд). Поэтому у `ChatIdentityDTO`
// собственные camelCase-ключи, а у внешних тел — snake_case.

/// Вложение чата (ответ `/chat/upload` и элемент `attachments` в теле `/chat`).
struct ChatAttachmentDTO: Codable, Equatable {
    let id: String
    let filename: String
    let contentType: String
    let size: Int64
    let url: String

    enum CodingKeys: String, CodingKey {
        case id, filename, size, url
        case contentType = "content_type"
    }
}

/// Личность внутри тела `/chat` — camelCase-ключи.
struct ChatIdentityDTO: Codable, Equatable {
    var email: String?
    var name: String?
    var userId: String?
    var userHash: String?
    var visitorId: String?
    var metadata: [String: String]?
    var properties: [String: String]?
}

/// Публичная ссылка-источник под ответом ассистента.
struct SourceDTO: Codable, Equatable {
    let title: String?
    let url: String?
    // Внутренние поля RAG (chunk_id/score) бэкенд вырезает; парсим лениво.
}

/// Ссылка на документацию (`doc_links`).
struct DocLinkDTO: Codable, Equatable {
    let title: String?
    let url: String?
}

/// Сообщение беседы (customer-safe форма бэкенда).
struct MessageDTO: Codable, Equatable {
    let id: String
    let conversationId: String?
    let role: String
    let content: String
    let authorName: String?
    let authorAvatarURL: String?
    let attachments: [ChatAttachmentDTO]?
    let sources: [SourceDTO]?
    let metadata: MessageMetadataDTO?
    let createdAt: String?
    let deliveryStatus: String?
    let deliveryError: String?

    enum CodingKeys: String, CodingKey {
        case id, role, content, attachments, sources, metadata
        case conversationId = "conversation_id"
        case authorName = "author_name"
        case authorAvatarURL = "author_avatar_url"
        case createdAt = "created_at"
        case deliveryStatus = "delivery_status"
        case deliveryError = "delivery_error"
    }
}

/// Метаданные сообщения. Все поля опциональны; спец-типы распознаются по ним.
struct MessageMetadataDTO: Codable, Equatable {
    let banner: Bool?
    let chatDisplay: String?
    let replyType: String?
    let contentFormat: String?
    let announcement: JSONValue?
    let surveyStep: JSONValue?
    let surveyInline: JSONValue?
    /// Стандартное уведомление о передаче человеку (текст сервера): оно само —
    /// карточка передачи, вторую рядом не рисуют.
    var handoverCanned: Bool? = nil
    /// Карточка «передано человеку» под ответом модели или своим текстом
    /// агента — на языке клиента.
    var handoverCardText: String? = nil

    enum CodingKeys: String, CodingKey {
        case banner, announcement
        case chatDisplay = "chat_display"
        case replyType = "reply_type"
        case contentFormat = "content_format"
        case surveyStep = "survey_step"
        case surveyInline = "survey_inline"
        case handoverCanned = "handover_canned"
        case handoverCardText = "handover_card_text"
    }
}

/// Карточки, которые SDK рисует сам по смене статуса беседы, на языке
/// КЛИЕНТА (`status_texts`: каталог системных текстов сервера). Кадр WS
/// `status_changed` языка не несёт — SDK запоминает последние из poll,
/// resume, `/chat` и `/escalate`.
struct StatusTextsDTO: Codable, Equatable {
    var backToAI: String? = nil
    var resolved: String? = nil
    /// Блок оценки беседы — только пока закрытие просит оценку (behavior.md §12).
    var ratingQuestion: String? = nil
    var ratingThanks: String? = nil
    var ratingRemarkPrompt: String? = nil
    var ratingRemarkPlaceholder: String? = nil
    var ratingSend: String? = nil
    var ratingEdit: String? = nil

    enum CodingKeys: String, CodingKey {
        case resolved
        case backToAI = "back_to_ai"
        case ratingQuestion = "rating_question"
        case ratingThanks = "rating_thanks"
        case ratingRemarkPrompt = "rating_remark_prompt"
        case ratingRemarkPlaceholder = "rating_remark_placeholder"
        case ratingSend = "rating_send"
        case ratingEdit = "rating_edit"
    }
}

/// Тело `POST /api/v1/chat/conversations/{id}/rating` (behavior.md §12):
/// `score` — всегда, и вместе с отзывом; `client` — ios.
struct RatingRequestDTO: Codable, Equatable {
    var score: Int
    var remark: String?
    var client: String = "ios"
}

/// Ответ оценки: сохранённая оценка, отзыв и можно ли его ещё править.
struct RatingResponseDTO: Codable, Equatable {
    var ok: Bool? = nil
    var score: Int? = nil
    var remark: String? = nil
    var remarkEditable: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case ok, score, remark
        case remarkEditable = "remark_editable"
    }
}

/// Тело `POST /api/v1/chat`.
struct ChatRequestDTO: Codable, Equatable {
    var agentId: String
    var channelId: String?
    var conversationId: String?
    var message: String
    var userEmail: String?
    var source: String?
    var attachments: [ChatAttachmentDTO]?
    var identity: ChatIdentityDTO?
    var sessionToken: String?
    /// Откуда текст сообщения (`InputSource`): набрал посетитель или SDK за него.
    var inputSource: String? = nil

    enum CodingKeys: String, CodingKey {
        case message, source, attachments, identity
        case agentId = "agent_id"
        case channelId = "channel_id"
        case conversationId = "conversation_id"
        case userEmail = "user_email"
        case sessionToken = "session_token"
        case inputSource = "input_source"
    }
}

/// Значения `input_source` тела `POST /api/v1/chat` — как у веб-виджета. Текст, который набрал не
/// посетитель, а SDK за него (пилюля быстрого вопроса, AI-подсказка, заглушка вложения), не слова
/// клиента: сервер не выбирает по нему язык беседы (пилюли приходят на языке страницы, заглушка —
/// на языке SDK).
enum InputSource {
    static let typed = "typed"
    static let quickQuestion = "quick_question"
    static let suggestion = "suggestion"
    static let filesPlaceholder = "files_placeholder"
}

/// Тело ответа `POST /api/v1/chat`.
struct ChatResponseDTO: Codable, Equatable {
    let conversationId: String?
    let sessionToken: String?
    let message: MessageDTO?
    let humanHandover: Bool?
    let suggestedQuestions: [String]?
    let docLinks: [DocLinkDTO]?
    /// Текст карточки «передано человеку» на языке клиента; есть на каждой
    /// ветке с `human_handover`. nil — старый бэкенд, карточка — строкой SDK.
    var handoverCardText: String? = nil
    /// Карточки статусов на языке клиента — на будущие WS-переходы.
    var statusTexts: StatusTextsDTO? = nil
    /// Язык беседы после хода — тот же, что у события
    /// `conversation_updated{lang}`. На новой беседе SDK подписывается на неё
    /// только после этого ответа, и событие первого хода до него не доходит.
    var lang: String? = nil

    // Внимание: сюда НЕ добавляются ticket_url / ticket_id и любые другие
    // ссылки на внутренние системы. Это customer-facing DTO; зеркалит
    // backend/internal/api/handlers/chat_dto.go, где их тоже нет.

    enum CodingKeys: String, CodingKey {
        case message
        case conversationId = "conversation_id"
        case sessionToken = "session_token"
        case humanHandover = "human_handover"
        case suggestedQuestions = "suggested_questions"
        case docLinks = "doc_links"
        case handoverCardText = "handover_card_text"
        case statusTexts = "status_texts"
        case lang
    }
}

/// Ответ `GET /api/v1/chat/resume`.
struct ResumeResponseDTO: Codable, Equatable {
    let status: String?
    let messages: [MessageDTO]?
    let hasMore: Bool?
    let historyConversationId: String?
    let oldestMessageId: String?
    let conversationId: String?
    let sessionToken: String?
    /// Карточки статусов на языке клиента (см. `StatusTextsDTO`).
    var statusTexts: StatusTextsDTO? = nil
    /// Оценка нынешнего закрытия: запрос, выбранная цифра, отзыв.
    var ratingRequested: Bool? = nil
    var visitorRating: Int? = nil
    var ratingRemark: String? = nil
    var ratingRemarkEditable: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case status, messages
        case hasMore = "has_more"
        case historyConversationId = "history_conversation_id"
        case oldestMessageId = "oldest_message_id"
        case conversationId = "conversation_id"
        case sessionToken = "session_token"
        case statusTexts = "status_texts"
        case ratingRequested = "rating_requested"
        case visitorRating = "visitor_rating"
        case ratingRemark = "rating_remark"
        case ratingRemarkEditable = "rating_remark_editable"
    }
}

/// Ответ `GET /api/v1/chat/history`.
struct HistoryResponseDTO: Codable, Equatable {
    let messages: [MessageDTO]?
    let hasMore: Bool?
    let oldestMessageId: String?

    enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
        case oldestMessageId = "oldest_message_id"
    }
}

/// Ответ `GET /api/v1/chat/conversations/{id}/messages` (поллинг).
struct WidgetMessagesResponseDTO: Codable, Equatable {
    let messages: [MessageDTO]?
    let status: String?
    /// Карточки статусов на языке клиента: сервер шлёт их, пока тред у людей
    /// или закрыт.
    var statusTexts: StatusTextsDTO? = nil
    /// Оценка нынешнего закрытия: запрос, выбранная цифра, отзыв.
    var ratingRequested: Bool? = nil
    var visitorRating: Int? = nil
    var ratingRemark: String? = nil
    var ratingRemarkEditable: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case messages, status
        case statusTexts = "status_texts"
        case ratingRequested = "rating_requested"
        case visitorRating = "visitor_rating"
        case ratingRemark = "rating_remark"
        case ratingRemarkEditable = "rating_remark_editable"
    }
}

/// Ответ `POST /api/v1/chat/conversations/{id}/escalate`.
///
/// ГРАНИЦА СЕССИИ. Нажатие «нужен человек» на ЗАКРЫТОЙ беседе её не воскрешает:
/// бэкенд заводит follow-up, эскалирует ЕГО и возвращает здесь id, токен и
/// ссылку назад ИМЕННО новой строки.
///
/// Токен и ссылка назад тут не декодировались вовсе, а вызывающий выбрасывал и
/// сам ответ. Итог: оператор получал в «Needs human» кейс, в который клиент
/// физически не мог написать (SDK продолжал опрашивать закрытую строку), а
/// следующее сообщение форкало ТРЕТЬЮ беседу и перебивало закрытой ссылку
/// вперёд — второй кейс выпадал из цепочки и становился недостижим для ленты,
/// истории и аналитики.
struct EscalationResponseDTO: Codable, Equatable {
    let conversationId: String?
    let status: String?
    let message: String?
    /// Ключ от НОВОЙ строки. Без него собственная лента клиента ответит на
    /// follow-up 403: он рождается с `access=token`.
    let sessionToken: String?
    /// Тред для пользователя тот же — ленту не сбрасываем.
    let previousConversationId: String?
    /// Карточки статусов на языке клиента — «вернулся к ИИ», когда оператор
    /// вернёт тред боту.
    var statusTexts: StatusTextsDTO? = nil

    // Внимание: без ticket_url / ticket_id — см. комментарий у ChatResponseDTO.

    enum CodingKeys: String, CodingKey {
        case status, message
        case conversationId = "conversation_id"
        case sessionToken = "session_token"
        case previousConversationId = "previous_conversation_id"
        case statusTexts = "status_texts"
    }
}

/// Статус рабочих часов (`office_hours`).
struct OfficeHoursDTO: Codable, Equatable {
    let open: Bool?
    let replyTime: String?
    let timezone: String?
    let nextOpenAt: String?
    let nextCloseAt: String?

    enum CodingKeys: String, CodingKey {
        case open, timezone
        case replyTime = "reply_time"
        case nextOpenAt = "next_open_at"
        case nextCloseAt = "next_close_at"
    }
}

/// Ответ `GET /api/v1/widget/config`.
struct WidgetConfigDTO: Codable, Equatable {
    let agentId: String?
    let name: String?
    let title: String?
    let primaryColor: String?
    let logoURL: String?
    let avatarURL: String?
    let greeting: String?
    let greetingEnabled: Bool?
    let quickQuestions: [String]?
    let identityVerificationEnabled: Bool?
    let chatSize: String?
    let borderRadius: Double?
    let suggestedQuestionsEnabled: Bool?
    let proactiveMessagesEnabled: Bool?
    let proactiveDelaySeconds: Int?
    let officeHours: OfficeHoursDTO?
    let visitorLanguage: String?

    enum CodingKeys: String, CodingKey {
        case name, title, greeting
        case agentId = "agent_id"
        case primaryColor = "primary_color"
        case logoURL = "logo_url"
        case avatarURL = "avatar_url"
        case greetingEnabled = "greeting_enabled"
        case quickQuestions = "quick_questions"
        case identityVerificationEnabled = "identity_verification_enabled"
        case chatSize = "chat_size"
        case borderRadius = "border_radius"
        case suggestedQuestionsEnabled = "suggested_questions_enabled"
        case proactiveMessagesEnabled = "proactive_messages_enabled"
        case proactiveDelaySeconds = "proactive_delay_seconds"
        case officeHours = "office_hours"
        case visitorLanguage = "visitor_language"
    }
}

/// Тело `POST /api/v1/widget/events` (Respondo.track).
struct TrackEventRequestDTO: Codable, Equatable {
    var agentId: String?
    var channelId: String?
    var visitorId: String?
    var email: String?
    var userId: String?
    var userHash: String?
    var name: String
    var properties: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case name, email, properties
        case agentId = "agent_id"
        case channelId = "channel_id"
        case visitorId = "visitor_id"
        case userId = "user_id"
        case userHash = "user_hash"
    }
}

/// Тело `POST /api/v1/widget/push/register`.
struct PushRegisterRequestDTO: Codable, Equatable {
    var agentId: String?
    var channelId: String?
    var platform: String
    var token: String
    var appId: String?
    var locale: String?
    var sdkVersion: String?
    var sdkName: String?
    var visitorId: String?
    var email: String?
    var userId: String?
    var userHash: String?
    var sessionToken: String?
    /// `production` | `sandbox` — окружение APNs, в котором действителен токен
    /// (см. `ApnsEnvironment`). Пусто/nil означает «выяснить при доставке».
    var environment: String?

    enum CodingKeys: String, CodingKey {
        case platform, token, email, environment
        case agentId = "agent_id"
        case channelId = "channel_id"
        case appId = "app_id"
        case sdkVersion = "sdk_version"
        case sdkName = "sdk_name"
        case visitorId = "visitor_id"
        case userId = "user_id"
        case userHash = "user_hash"
        case sessionToken = "session_token"
    }
}

/// Тело `POST /api/v1/widget/push/unregister`.
struct PushUnregisterRequestDTO: Codable, Equatable {
    var channelId: String?
    var token: String

    enum CodingKeys: String, CodingKey {
        case token
        case channelId = "channel_id"
    }
}

/// Тело `POST /api/v1/widget/push/opened`.
struct PushOpenedRequestDTO: Codable, Equatable {
    var deliveryId: String?
    var messageId: String?
    var token: String

    enum CodingKeys: String, CodingKey {
        case token
        case deliveryId = "delivery_id"
        case messageId = "message_id"
    }
}

/// Тело `POST /api/v1/widget/identify` — атрибуты `identify()` в профиль контакта
/// сразу, без чата (тот же контракт, что у веб-виджета). Личность — по тем же
/// правилам identity verification, что у `/chat`: `user_hash` подписывает
/// `user_id`/`email`.
struct IdentifyRequestDTO: Codable, Equatable {
    var agentId: String?
    var channelId: String?
    var visitorId: String?
    var email: String?
    var userId: String?
    var userHash: String?
    var name: String?
    var properties: [String: String]
    /// Дата регистрации в продукте (`RespondoIdentity.signedUpAt`), Unix-секунды.
    var signedUpAt: Int64?

    enum CodingKeys: String, CodingKey {
        case email, name, properties
        case agentId = "agent_id"
        case channelId = "channel_id"
        case visitorId = "visitor_id"
        case userId = "user_id"
        case userHash = "user_hash"
        case signedUpAt = "signed_up_at"
    }
}

/// Ответ `POST /api/v1/widget/identify`: всегда `ok`; `created` — контакт личности
/// создан этим вызовом (или к ней перешёл анонимный контакт устройства): SDK
/// переотправляет identify по сокету, чтобы тот нашёл человека сразу.
struct IdentifyResponseDTO: Decodable, Equatable {
    var ok: Bool?
    var created: Bool?
}

/// Тело `POST /api/v1/widget/app-session` — сессия приложения (запуск или
/// возврат из фона): платформа, приложение и язык устройства у контакта без
/// разрешения на пуши.
struct AppSessionRequestDTO: Codable, Equatable {
    var agentId: String?
    var channelId: String?
    var visitorId: String?
    var email: String?
    var userId: String?
    var userHash: String?
    /// Имя личности: сервер ставит его, только если отметка создаёт контакт
    /// (слово приложения, провенанс «claimed»).
    var name: String?
    var platform: String
    var appId: String?
    var appVersion: String?
    var sdkName: String?
    var sdkVersion: String?
    var locale: String?

    enum CodingKeys: String, CodingKey {
        case email, name, platform, locale
        case agentId = "agent_id"
        case channelId = "channel_id"
        case visitorId = "visitor_id"
        case userId = "user_id"
        case userHash = "user_hash"
        case appId = "app_id"
        case appVersion = "app_version"
        case sdkName = "sdk_name"
        case sdkVersion = "sdk_version"
    }
}

/// Тело ошибки бэкенда: `{"error", "code", "message", "details"}`.
///
/// Плоская форма несёт `error` строкой, вложенная (`ErrorHandler`) — объектом
/// `{"code", "message", "details"}`; старый бэкенд — только `{"error": "..."}`.
/// Декод терпимый: ни одна из форм его не роняет, отсутствующее поле — `nil`.
struct BackendError: Codable, Equatable {
    /// Текст `error`: строка — как есть, объект — его `message`, иначе `nil`.
    let error: String?
    /// Машинный код ошибки (`BAD_REQUEST`, `NOT_FOUND`, …); `nil` у старого бэкенда.
    let code: String?
    /// Текст для клиента на его языке (отказ `/escalate`: «передать человеку
    /// не вышло»), если сервер его дал.
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case error, code, message
    }

    /// Вложенная форма поля `error`.
    private struct NestedError: Decodable {
        let message: String?
    }

    init(error: String?, code: String?, message: String?) {
        self.error = error
        self.code = code
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decodeIfPresent(String.self, forKey: .error) {
            error = text
        } else if let nested = try? container.decodeIfPresent(NestedError.self, forKey: .error) {
            error = nested.message
        } else {
            error = nil
        }
        code = try? container.decodeIfPresent(String.self, forKey: .code)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
    }
}
