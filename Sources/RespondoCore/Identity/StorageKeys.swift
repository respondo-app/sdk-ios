import Foundation

/// Логические ключи хранилища. Префиксы совпадают с вебом; `reset()` чистит всё по
/// общему префиксу `respondo` (покрывает и `respondoai_`, и `respondo_`).
enum StorageKeys {
    /// Общий префикс: `reset()` стирает все ключи, начинающиеся с него.
    static let resetPrefix = "respondo"

    static let visitorId = "respondoai_visitor_id"
    static let lang = "respondoai_lang"
    static let collectedEmail = "respondoai_collected_email"
    /// Доставки опросов, которые посетитель закрыл (JSON-массив, новые в конце).
    static let surveyDismissed = "respondo_survey_dismissed"

    /// Блоб беседы: `respondoai_{agentId||"ch"}_{channelId||"default"}`.
    static func conversationBlob(agentId: String, channelId: String?) -> String {
        let agentPart = agentId.isEmpty ? "ch" : agentId
        let channelPart = (channelId?.isEmpty ?? true) ? "default" : channelId!
        return "respondoai_\(agentPart)_\(channelPart)"
    }

    static func chatSeen(_ messageId: String) -> String { "respondo_chat_seen_\(messageId)" }
    static func bannerDismissed(_ id: String) -> String { "respondo_banner_dismissed_\(id)" }
    static func announcementDismissed(_ id: String) -> String { "respondo_announcement_dismissed_\(id)" }
}

/// Генератор анонимного visitor_id в формате веба: `"v_" + random36 + random36`.
enum VisitorId {
    static func generate() -> String {
        "v_" + randomBase36() + randomBase36()
    }

    private static func randomBase36() -> String {
        // Аналог `Math.random().toString(36).slice(2)` — дробь в 36-ричной записи.
        let value = Double.random(in: 0..<1)
        var fractional = value
        var digits = ""
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        for _ in 0..<11 {
            fractional *= 36
            let index = Int(fractional)
            digits.append(alphabet[min(index, 35)])
            fractional -= Double(index)
        }
        return digits
    }
}
