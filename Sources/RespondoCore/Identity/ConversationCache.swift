import Foundation

/// Кэш беседы в UserDefaults. Это КЭШ, а не источник правды: при наличии сети
/// beседа восстанавливается через `/chat/resume`. TTL 24 часа, последние 50 сообщений.
struct ConversationBlob: Codable, Equatable {
    var conversationId: String?
    var escalated: Bool
    var messages: [ChatMessage]
    /// Unix-время последнего сохранения (мс), для проверки TTL.
    var timestampMs: Double
}

final class ConversationCache: @unchecked Sendable {
    static let maxCachedMessages = 50
    static let ttlSeconds: Double = 24 * 60 * 60

    private let prefs: Preferences
    private let key: String

    init(prefs: Preferences, agentId: String, channelId: String?) {
        self.prefs = prefs
        self.key = StorageKeys.conversationBlob(agentId: agentId, channelId: channelId)
    }

    /// Загружает блоб, если он есть и не протух (TTL 24ч). Иначе — nil.
    func load(now: Date = Date()) -> ConversationBlob? {
        guard let data = prefs.data(forKey: key) else { return nil }
        guard let blob = try? JSONDecoder().decode(ConversationBlob.self, from: data) else { return nil }
        let age = now.timeIntervalSince1970 * 1000 - blob.timestampMs
        guard age < Self.ttlSeconds * 1000 else { return nil }
        return blob
    }

    /// Сохраняет последние 50 сообщений + метаданные беседы.
    func save(conversationId: String?, escalated: Bool, messages: [ChatMessage], now: Date = Date()) {
        let trimmed = Array(messages.suffix(Self.maxCachedMessages))
        let blob = ConversationBlob(
            conversationId: conversationId,
            escalated: escalated,
            messages: trimmed,
            timestampMs: now.timeIntervalSince1970 * 1000
        )
        guard let data = try? JSONEncoder().encode(blob) else { return }
        prefs.set(data, forKey: key)
    }

    func clear() {
        prefs.removeValue(forKey: key)
    }
}
