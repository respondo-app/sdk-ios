import Foundation

/// Персистентная идентичность и токены. visitor_id и session_token — в защищённом
/// хранилище (Keychain); язык и собранный email — в UserDefaults.
/// Все операции синхронные; сериализация доступа обеспечивается вызывающим актором.
final class IdentityStore: @unchecked Sendable {
    private let secure: SecureStore
    private let prefs: Preferences
    private var cachedVisitorId: String?

    init(secure: SecureStore, prefs: Preferences) {
        self.secure = secure
        self.prefs = prefs
    }

    /// Анонимный visitor_id: читается из Keychain, генерируется и персистится при первом запуске.
    /// Стабильность на сессию гарантируется in-memory кэшем (важно: не плодить новый id на каждый запрос).
    func visitorId() -> String {
        if let cached = cachedVisitorId { return cached }
        if let stored = secure.string(forKey: StorageKeys.visitorId) {
            cachedVisitorId = stored
            return stored
        }
        let generated = VisitorId.generate()
        secure.set(generated, forKey: StorageKeys.visitorId)
        cachedVisitorId = generated
        return generated
    }

    // MARK: - session_token (в Keychain, ключ производный от блоба беседы)

    private func sessionTokenKey(agentId: String, channelId: String?) -> String {
        StorageKeys.conversationBlob(agentId: agentId, channelId: channelId) + ".token"
    }

    func sessionToken(agentId: String, channelId: String?) -> String? {
        secure.string(forKey: sessionTokenKey(agentId: agentId, channelId: channelId))
    }

    func setSessionToken(_ token: String?, agentId: String, channelId: String?) {
        let key = sessionTokenKey(agentId: agentId, channelId: channelId)
        if let token, !token.isEmpty {
            secure.set(token, forKey: key)
        } else {
            secure.removeValue(forKey: key)
        }
    }

    // MARK: - Локаль и собранный email

    func storedLang() -> String? { prefs.string(forKey: StorageKeys.lang) }
    func setLang(_ lang: String) { prefs.set(lang, forKey: StorageKeys.lang) }

    func collectedEmail() -> String? { prefs.string(forKey: StorageKeys.collectedEmail) }
    func setCollectedEmail(_ email: String) { prefs.set(email, forKey: StorageKeys.collectedEmail) }

    // MARK: - seen/dismissed флаги кампаний

    func markChatSeen(_ messageId: String) { prefs.set("1", forKey: StorageKeys.chatSeen(messageId)) }
    func isChatSeen(_ messageId: String) -> Bool { prefs.string(forKey: StorageKeys.chatSeen(messageId)) != nil }

    // MARK: - reset

    /// Полностью стирает данные Respondo и сбрасывает in-memory кэш visitor_id.
    /// Следующий `visitorId()` сгенерирует нового анонима.
    func wipeAll() {
        secure.removeAll(withPrefix: StorageKeys.resetPrefix)
        prefs.removeAll(withPrefix: StorageKeys.resetPrefix)
        cachedVisitorId = nil
    }
}
