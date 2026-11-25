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

    /// Последний переданный токен (регистрирует `registerPending`).
    private var pendingToken: String?
    /// Текущий зарегистрированный токен (для unregister).
    private(set) var registeredToken: String?
    /// Токен устройства, известный SDK (переданный или зарегистрированный).
    var token: String? { pendingToken ?? registeredToken }
    /// Тело последней регистрации, ушедшей или в полёте (без `sessionToken` — сервер его не
    /// читает): то же тело второй раз не уходит. Сбой и снятие токена его сбрасывают.
    private var lastRegistration: PushRegisterRequestDTO?
    /// Тапы, обработанные раньше, чем стал известен токен (`reportOpened`): бикон открытия
    /// уходит, как только токен появится (`adopt`). Не больше `openedWithoutTokenCap`.
    private var openedWithoutToken: [RespondoPushPayload] = []
    private let openedWithoutTokenCap = 10
    /// message_id уже обработанных пушей (гасим дубликаты).
    private var seenMessageIds = Set<String>()
    private let bundleId = Bundle.main.bundleIdentifier

    init(apiClient: ApiClient, identityStore: IdentityStore, agentId: String, channelId: String?) {
        self.apiClient = apiClient
        self.identityStore = identityStore
        self.agentId = agentId
        self.channelId = channelId
    }

    /// Запоминает токен без сети: бикон открытия пуша уходит с ним сразу (и биконы, ждавшие
    /// токена, — сейчас), регистрацию делает `registerPending` после ответа identify.
    func adopt(_ token: String) {
        pendingToken = token
        let waiting = openedWithoutToken
        openedWithoutToken = []
        for payload in waiting { reportOpened(payload) }
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
            sdkName: SdkVersion.source,
            visitorId: identityStore.visitorId(),
            email: identity.email,
            userId: identity.userId,
            userHash: identity.userHash,
            sessionToken: identityStore.sessionToken(agentId: agentId, channelId: channelId),
            environment: ApnsEnvironment.current
        )
        // То же тело (токен, личность, визитёр) уже ушло или в полёте — не повторяем: на холодном
        // старте регистрацию после ответа identify просят и setPushToken, и identify.
        var unsessioned = body
        unsessioned.sessionToken = nil
        let key = unsessioned
        guard key != lastRegistration else { return }
        lastRegistration = key
        Task {
            do {
                try await apiClient.pushRegister(body)
                registeredToken = token
            } catch {
                if lastRegistration == key { lastRegistration = nil }
                RespondoLog.warn("push register failed: \(String(describing: error))")
            }
        }
    }

    /// Снимает регистрацию токена (logout).
    func clearToken() {
        let token = registeredToken ?? pendingToken
        pendingToken = nil
        registeredToken = nil
        lastRegistration = nil
        openedWithoutToken = []
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

    /// Телеметрия открытия push-уведомления. Токен — последний переданный, даже если его
    /// регистрация ещё ждёт ответа identify: сервер находит устройство по токену с прошлого
    /// запуска. Токена ещё нет (тап холодного старта раньше `setPushToken`) — бикон ждёт `adopt`:
    /// без токена сервер открытие не засчитывает.
    func reportOpened(_ payload: RespondoPushPayload) {
        guard let token = pendingToken ?? registeredToken else {
            openedWithoutToken.append(payload)
            if openedWithoutToken.count > openedWithoutTokenCap { openedWithoutToken.removeFirst() }
            return
        }
        let body = PushOpenedRequestDTO(
            deliveryId: payload.deliveryId,
            messageId: payload.messageId,
            token: token
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
