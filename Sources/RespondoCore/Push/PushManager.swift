import Foundation

/// Клиентская push-логика: регистрация/снятие токена устройства, дедуп входящих
/// пушей по `message_id`, телеметрия открытия. Токен, переданный до `init`,
/// запоминается и регистрируется после инициализации.
@MainActor
final class PushManager {
    private let apiClient: ApiClient
    private let identityStore: IdentityStore
    private let agentId: String
    private let channelId: String?

    /// Токен, переданный до готовности контекста (регистрируется позже).
    private var pendingToken: String?
    /// Текущий зарегистрированный токен (для unregister).
    private(set) var registeredToken: String?
    /// message_id уже обработанных пушей (гасим дубликаты).
    private var seenMessageIds = Set<String>()
    private let bundleId = Bundle.main.bundleIdentifier

    init(apiClient: ApiClient, identityStore: IdentityStore, agentId: String, channelId: String?) {
        self.apiClient = apiClient
        self.identityStore = identityStore
        self.agentId = agentId
        self.channelId = channelId
    }

    /// Сохраняет токен и регистрирует его на бэкенде.
    func setToken(_ token: String, identity: RespondoIdentity) {
        pendingToken = token
        registerPending(identity: identity)
    }

    /// Регистрирует ранее запомненный токен (вызывается после init и на смену identity).
    func registerPending(identity: RespondoIdentity) {
        guard let token = pendingToken else { return }
        let body = PushRegisterRequestDTO(
            agentId: agentId,
            channelId: channelId,
            platform: SdkVersion.platform,
            token: token,
            appId: bundleId,
            locale: identityStore.storedLang() ?? Locale.current.identifier,
            sdkVersion: SdkVersion.current,
            visitorId: identityStore.visitorId(),
            email: identity.email,
            userId: identity.userId,
            userHash: identity.userHash,
            sessionToken: identityStore.sessionToken(agentId: agentId, channelId: channelId)
        )
        Task {
            do {
                try await apiClient.pushRegister(body)
                registeredToken = token
            } catch {
                RespondoLog.warn("push register failed: \(String(describing: error))")
            }
        }
    }

    /// Снимает регистрацию токена (logout).
    func clearToken() {
        let token = registeredToken ?? pendingToken
        pendingToken = nil
        registeredToken = nil
        guard let token else { return }
        let body = PushUnregisterRequestDTO(channelId: channelId, token: token)
        Task {
            do {
                try await apiClient.pushUnregister(body)
            } catch {
                RespondoLog.warn("push unregister failed: \(String(describing: error))")
            }
        }
    }

    /// Проверяет и помечает дубликат по message_id. true — если это НОВЫЙ пуш.
    func markProcessed(_ payload: RespondoPushPayload) -> Bool {
        guard let messageId = payload.messageId else { return true }
        return seenMessageIds.insert(messageId).inserted
    }

    /// Телеметрия открытия push-уведомления.
    func reportOpened(_ payload: RespondoPushPayload) {
        guard registeredToken != nil || payload.deliveryId != nil || payload.messageId != nil else { return }
        let body = PushOpenedRequestDTO(
            deliveryId: payload.deliveryId,
            messageId: payload.messageId,
            token: registeredToken ?? ""
        )
        Task {
            do {
                try await apiClient.pushOpened(body)
            } catch {
                RespondoLog.debug("push opened telemetry failed: \(String(describing: error))")
            }
        }
    }
}
