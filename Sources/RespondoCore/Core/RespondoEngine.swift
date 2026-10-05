import Foundation

/// Мозг SDK: жизненный цикл, command-queue, наблюдаемые, реалтайм, push и мост к треду.
/// `@MainActor` — единый домен сериализации состояния и UI-операций (наблюдаемые и
/// колбэки эмитятся на главном потоке). Публичный фасад `Respondo` тонко форвардит сюда.
@MainActor
public final class RespondoEngine: ConversationHost, EngagementHost {
    public static let shared = RespondoEngine()

    // Зависимости (инъектируются в тестах).
    private let secureStore: SecureStore
    private let prefs: Preferences
    private let makeHttpEngine: () -> HttpEngine
    let identityStore: IdentityStore

    // Публичные наблюдаемые.
    private let unreadBroadcaster = ValueBroadcaster<Int>(0)
    private let chatStateBroadcaster = ValueBroadcaster<RespondoChatState>(.closed)
    // Engagement-потоки для host-приложения (переживают reset — engagement пересоздаётся).
    private let bannersBroadcaster = ValueBroadcaster<[RespondoBanner]>([])
    private let newsUnreadBroadcaster = ValueBroadcaster<Int>(0)
    private let proactiveBroadcaster = ValueBroadcaster<RespondoProactiveMessage?>(nil)
    public weak var delegate: RespondoDelegate?
    /// Открытие диплинка push-кампании (инъектируется в тестах). true — ссылку приняли.
    var openDeepLink: @MainActor (String) async -> Bool = { await DeepLinkOpener.open($0) }

    // Состояние.
    private var config: RespondoConfig?
    private var identity = RespondoIdentity()
    private var initialized = false
    private var initializing = false
    private var currentScreen: String?
    private(set) var lang = "en"
    private(set) var theme: ResolvedTheme = .fallback

    // Рантайм (пересоздаётся при init/reset).
    private var apiClient: ApiClient?
    private var realtime: RealtimeClient?
    private var cache: ConversationCache?
    private var pushManager: PushManager?
    public private(set) var controller: ConversationController?
    public private(set) var engagement: EngagementController?
    private var eventPump: Task<Void, Never>?

    // Монотонный номер поколения инициализации: защищает от гонки перекрывающихся
    // performInit. Каждый запуск захватывает номер и после КАЖДОГО await проверяет,
    // что он ещё актуален; tearDownRuntime/startInit бампят номер и отменяют старую Task.
    private(set) var initGeneration = 0
    private var initTask: Task<Void, Never>?

    private var queue = CommandQueue()
    private weak var presenter: ChatPresenter?

    /// Продакшен-инициализатор: Keychain + UserDefaults + URLSession.
    public convenience init() {
        self.init(
            secureStore: KeychainSecureStore(),
            prefs: UserDefaultsPreferences(),
            httpEngineFactory: { URLSessionHttpEngine() }
        )
    }

    /// Инъекция зависимостей для тестов (доступен через `@testable import`).
    init(
        secureStore: SecureStore,
        prefs: Preferences,
        httpEngineFactory: @escaping () -> HttpEngine
    ) {
        self.secureStore = secureStore
        self.prefs = prefs
        self.makeHttpEngine = httpEngineFactory
        self.identityStore = IdentityStore(secure: secureStore, prefs: prefs)
    }

    // MARK: - Наблюдаемые (для фасада)

    public var unreadCount: Int { unreadBroadcaster.current }
    public func unreadStream() -> AsyncStream<Int> { unreadBroadcaster.makeStream() }
    public var chatState: RespondoChatState { chatStateBroadcaster.current }
    public func chatStateStream() -> AsyncStream<RespondoChatState> { chatStateBroadcaster.makeStream() }

    /// Актуальные баннеры для host-приложения (host может рендерить свои).
    public var banners: [RespondoBanner] { bannersBroadcaster.current }
    public func bannersStream() -> AsyncStream<[RespondoBanner]> { bannersBroadcaster.makeStream() }
    /// Число непрочитанных новостей.
    public var newsUnreadCount: Int { newsUnreadBroadcaster.current }
    public func newsUnreadStream() -> AsyncStream<Int> { newsUnreadBroadcaster.makeStream() }
    /// Поток проактивных сообщений (nil — сброшено).
    public func proactiveStream() -> AsyncStream<RespondoProactiveMessage?> { proactiveBroadcaster.makeStream() }

    public func setPresenter(_ presenter: ChatPresenter) {
        self.presenter = presenter
    }

    // MARK: - Жизненный цикл

    public func initialize(config: RespondoConfig, identity: RespondoIdentity?) {
        guard config.hasValidAgentId else {
            RespondoLog.error("initialize: agentId обязателен и не может быть пустым — SDK остаётся в no-op")
            return
        }
        // Повторный init = destroy предыдущего + новый (очередь очищается).
        if initialized || initializing {
            tearDownRuntime()
            queue.clear()
        }
        self.config = config
        if let identity { self.identity = identity }
        startInit()
    }

    /// Запускает новое поколение инициализации: бампит номер, отменяет прошлую Task.
    private func startInit() {
        initGeneration &+= 1
        let generation = initGeneration
        initializing = true
        initTask?.cancel()
        initTask = Task { [weak self] in await self?.performInit(generation: generation) }
    }

    private func performInit(generation: Int) async {
        guard let config else { return }
        let systemLocale = Locale.current.identifier
        lang = identityStore.storedLang() ?? LocalizedStrings.normalize(config.locale ?? systemLocale)

        let api = ApiClient(engine: makeHttpEngine(), baseUrl: config.baseUrl)
        self.apiClient = api

        // Загрузка конфига виджета (до ответа работаем на дефолтах).
        var configDTO: WidgetConfigDTO?
        do {
            if !config.agentId.isEmpty {
                configDTO = try await api.widgetConfig(
                    agentId: config.agentId, channelId: config.channelId,
                    lang: LocalizedStrings.baseCode(lang), visitorId: identityStore.visitorId()
                )
            } else if let channel = config.channelId {
                configDTO = try await api.widgetConfigByChannel(
                    channelId: channel, lang: LocalizedStrings.baseCode(lang), visitorId: identityStore.visitorId()
                )
            }
        } catch {
            RespondoLog.warn("config load failed, using defaults: \(String(describing: error))")
        }
        guard generation == initGeneration else { return } // перекрыт новым init/reset/destroy

        if let visitorLang = configDTO?.visitorLanguage, !visitorLang.isEmpty,
           LocalizedStrings.supportedLocales.contains(LocalizedStrings.baseCode(visitorLang)) {
            lang = LocalizedStrings.normalize(visitorLang)
            identityStore.setLang(lang)
        }

        let resolvedTheme = ThemeResolver.resolve(config: configDTO, override: config.themeOverride)
        self.theme = resolvedTheme

        let realtime = RealtimeClient(apiClient: api, agentId: config.agentId)
        self.realtime = realtime

        let cache = ConversationCache(prefs: prefs, agentId: config.agentId, channelId: config.channelId)
        self.cache = cache

        let controller = ConversationController(
            apiClient: api, realtime: realtime, cache: cache, identityStore: identityStore,
            agentId: config.agentId, channelId: config.channelId, theme: resolvedTheme, lang: lang
        )
        controller.host = self
        self.controller = controller

        self.pushManager = PushManager(apiClient: api, identityStore: identityStore, agentId: config.agentId, channelId: config.channelId)

        let engagement = EngagementController(apiClient: api, host: self)
        engagement.onProactive = { [weak self] message in
            self?.proactiveBroadcaster.send(message)
            self?.delegate?.respondoProactiveMessage(message)
        }
        engagement.onBanners = { [weak self] banners in self?.bannersBroadcaster.send(banners) }
        engagement.onNewsUnread = { [weak self] count in self?.newsUnreadBroadcaster.send(count) }
        self.engagement = engagement

        // Восстановление беседы: кэш (быстро) + resume (источник правды).
        let cacheBlob = cache.load()
        var resume: ResumeResponseDTO?
        do {
            resume = try await api.resume(
                conversationId: cacheBlob?.conversationId,
                ownership: ownership(),
                agentId: config.agentId.isEmpty ? nil : config.agentId,
                channelId: config.channelId,
                email: identity.email,
                userId: identity.userId
            )
        } catch {
            RespondoLog.debug("resume failed, keeping cache: \(String(describing: error))")
        }
        guard generation == initGeneration else { return } // перекрыт новым init/reset/destroy
        controller.bootstrap(cacheBlob: cacheBlob, resume: resume)

        // Насос реалтайм-событий в контроллер (главный актор).
        eventPump = Task { @MainActor [weak self] in
            guard let realtimeEvents = self?.realtime?.events else { return }
            for await event in realtimeEvents {
                if case .overlayShow(let items) = event {
                    self?.engagement?.applyOverlayItems(items)
                } else {
                    self?.controller?.handle(event)
                    self?.controller?.scheduleRead()
                }
            }
        }

        // WS требует agentId; humans-only деградирует до поллинга при появлении беседы.
        if !config.agentId.isEmpty {
            // Засев курса поллинга последним серверным id восстановленной беседы —
            // фолбэк WS→поллинг не перечитает уже показанные сообщения.
            await realtime.setPollingCursor(controller.lastRestoredBackendMessageId)
            await realtime.setContext(
                channelId: config.channelId, visitorId: identityStore.visitorId(),
                email: identity.email, userId: identity.userId, userHash: identity.userHash,
                lang: LocalizedStrings.baseCode(lang)
            )
            await realtime.setConversation(id: controller.conversationId, ownership: ownership())
            guard generation == initGeneration else { return } // перекрыт до старта — соединение не поднимаем
            await realtime.start()
            guard generation == initGeneration else { return } // перекрыт новым init/reset/destroy
        }

        initialized = true
        initializing = false
        pushManager?.registerPending(identity: identity)

        // Каталоги оверлеев (surveys + banners) — приходят на identify.
        engagement.loadCatalogs()
        // Проактив под текущий экран с задержкой из конфига.
        if resolvedTheme.proactiveMessagesEnabled {
            engagement.scheduleProactive(delay: TimeInterval(resolvedTheme.proactiveDelaySeconds))
        }

        replayQueue()
    }

    public func destroy() {
        tearDownRuntime()
        RespondoLog.debug("destroy: рантайм освобождён, хранилище сохранено")
    }

    private func tearDownRuntime() {
        // Инвалидируем текущее поколение init и отменяем его Task, чтобы
        // проснувшийся после await performInit не трогал уже разобранный рантайм.
        initGeneration &+= 1
        initTask?.cancel(); initTask = nil
        eventPump?.cancel(); eventPump = nil
        if let realtime { Task { await realtime.stop() } }
        presenter?.dismiss()
        controller?.clear()
        engagement?.clear()
        controller = nil
        engagement = nil
        realtime = nil
        apiClient = nil
        cache = nil
        pushManager = nil
        initialized = false
        initializing = false
        setChatState(.closed)
    }

    public func reset() {
        guard initialized || initializing, config != nil else {
            RespondoLog.warn("reset до init — нечего сбрасывать (no-op)")
            return
        }
        let conversationId = controller?.conversationId
        let ownershipSnapshot = ownership()
        let api = apiClient
        let generation = initGeneration
        Task {
            // revoke-session по хранимой беседе (best-effort).
            if let conversationId, let api {
                try? await api.revokeSession(conversationId: conversationId, ownership: ownershipSnapshot)
            }
            // destroy()/иной init в окне revoke-session инвалидировал поколение —
            // не воскрешаем разобранный движок повторной инициализацией.
            guard generation == initGeneration else { return }
            tearDownRuntime()
            queue.clear()
            identityStore.wipeAll()
            identity = RespondoIdentity()
            setUnread(0)
            startInit()
        }
    }

    // MARK: - Публичные методы (буферизуются до init)

    public func identify(_ identity: RespondoIdentity) {
        guard initialized else { queue.enqueue(.identify(identity)); return }
        self.identity = identity
        // Обновляем реалтайм-контекст и push-регистрацию на лету.
        if let config, !config.agentId.isEmpty, let realtime {
            Task {
                await realtime.setContext(
                    channelId: config.channelId, visitorId: identityStore.visitorId(),
                    email: identity.email, userId: identity.userId, userHash: identity.userHash,
                    lang: LocalizedStrings.baseCode(lang)
                )
            }
        }
        pushManager?.registerPending(identity: identity)
        // Личность изменилась — перезагружаем каталоги оверлеев под нового контакта.
        engagement?.loadCatalogs()
    }

    public func track(_ name: String, properties: [String: Any]) {
        performTrack(name, properties: properties.mapValues { JSONValue.from($0) })
    }

    private func performTrack(_ name: String, properties: [String: JSONValue]) {
        guard initialized else { queue.enqueue(.track(name: name, properties: properties)); return }
        guard let config, let api = apiClient else { return }
        let body = TrackEventRequestDTO(
            agentId: config.agentId.isEmpty ? nil : config.agentId,
            channelId: config.channelId,
            visitorId: identityStore.visitorId(),
            email: identity.email,
            userId: identity.userId,
            userHash: identity.userHash,
            name: name,
            properties: properties.isEmpty ? nil : properties
        )
        Task { try? await api.track(body) } // best-effort
    }

    public func open() {
        guard initialized else { queue.enqueue(.open); return }
        // Если был показан проактив-тизер — заносим его текст в тред как приветствие.
        if let proactive = engagement?.consumeProactive() {
            controller?.showProactiveTeaser(proactive.text)
        }
        presentSurface(.thread)
    }

    public func close() {
        guard initialized else { queue.enqueue(.close); return }
        guard chatState == .open || chatState == .opening else { return }
        setChatState(.closing)
        presenter?.dismiss()
        setChatState(.closed)
        delegate?.respondoChatClosed()
        Task { await realtime?.setPanelOpen(false) }
    }

    public func openNews() {
        guard initialized else { queue.enqueue(.openNews); return }
        engagement?.loadNews()
        presentSurface(.news)
    }

    public func openChecklists() {
        guard initialized else { queue.enqueue(.openChecklists); return }
        engagement?.loadChecklists()
        presentSurface(.checklists)
    }

    private func presentSurface(_ surface: ChatSurface) {
        guard let presenter else {
            RespondoLog.warn("UI-презентер не установлен — чат не может быть показан")
            return
        }
        setChatState(.opening)
        presenter.present(surface: surface)
        setChatState(.open)
        if surface == .thread {
            resetUnread()
            Task { await realtime?.setPanelOpen(true) }
            controller?.scheduleRead()
        }
        delegate?.respondoChatOpened()
    }

    // MARK: - Жизненный цикл приложения (хуки для UI-слоя)

    /// Приложение ушло в фон: сигналим реалтайму (кадр + пометка фона). Вызывает
    /// UI-слой из `UIApplication.didEnterBackgroundNotification` (core платформонезависим).
    public func applicationDidEnterBackground() {
        Task { await realtime?.notifyBackground() }
    }

    /// Приложение вернулось на передний план: реалтайм шлёт foreground-кадр и, если
    /// WS оборвался в фоне, переподключается немедленно.
    public func applicationWillEnterForeground() {
        Task { await realtime?.notifyForeground() }
    }

    public func setCurrentScreen(_ name: String?) {
        let changed = currentScreen != name
        currentScreen = name
        // Смена экрана = аналог SPA-навигации: перепланируем проактив под новую страницу.
        if changed, initialized, theme.proactiveMessagesEnabled {
            engagement?.scheduleProactive(delay: TimeInterval(theme.proactiveDelaySeconds))
        }
    }

    public func setPushToken(_ token: String) {
        guard initialized, let pushManager else { queue.enqueue(.setPushToken(token)); return }
        pushManager.setToken(token, identity: identity)
    }

    public func clearPushToken() {
        guard initialized, let pushManager else { queue.enqueue(.clearPushToken); return }
        pushManager.clearToken()
    }

    @discardableResult
    public func handlePush(_ payload: RespondoPushPayload) -> Bool {
        // Дедуп по message_id (если менеджер уже поднят).
        if let pushManager, !pushManager.markProcessed(payload) {
            return true // дубликат — без побочных эффектов, но это наш пуш
        }
        guard initialized else {
            queue.enqueue(.handlePush(payload))
            return true // «свой» ли пуш, решаем сразу; открытие откладываем до init
        }
        processPush(payload)
        return true
    }

    private func processPush(_ payload: RespondoPushPayload) {
        pushManager?.reportOpened(payload)
        if let conversationId = payload.conversationId, !conversationId.isEmpty {
            open()
        } else if let link = payload.deepLink, !link.isEmpty {
            // Push-кампания с экраном для открытия: ссылку открывает сам SDK (как Intercom).
            Task { @MainActor [weak self] in
                guard let self else { return }
                if await !self.openDeepLink(link) {
                    self.delegate?.respondoUnhandledDeepLink(payload)
                }
            }
        } else {
            delegate?.respondoUnhandledDeepLink(payload)
        }
    }

    // MARK: - Проигрывание очереди

    private func replayQueue() {
        let commands = queue.replayOrder()
        queue.clear()
        for command in commands {
            switch command {
            case .identify(let identity): identify(identity)
            case .track(let name, let properties): performTrack(name, properties: properties)
            case .open: open()
            case .close: close()
            case .openNews: openNews()
            case .openChecklists: openChecklists()
            case .setPushToken(let token): setPushToken(token)
            case .clearPushToken: clearPushToken()
            // Полный путь: пре-init пуши проходят дедуп markProcessed (при enqueue
            // менеджера ещё не было), а не сразу processPush.
            case .handlePush(let payload): _ = handlePush(payload)
            }
        }
    }

    // MARK: - ConversationHost

    var isPanelOpen: Bool { chatState == .open }

    func ownership() -> OwnershipParams {
        OwnershipParams(
            sessionToken: config.flatMap { identityStore.sessionToken(agentId: $0.agentId, channelId: $0.channelId) },
            userHash: identity.userHash,
            visitorId: identityStore.visitorId()
        )
    }

    func currentIdentity() -> RespondoIdentity { identity }

    func autoMetadata() -> [String: String] {
        DeviceContext(locale: lang, currentScreen: currentScreen).autoMetadata()
    }

    func conversationDidChange(id: String?, sessionToken: String?) {
        guard let config else { return }
        if let sessionToken {
            identityStore.setSessionToken(sessionToken, agentId: config.agentId, channelId: config.channelId)
        } else if id == nil {
            identityStore.setSessionToken(nil, agentId: config.agentId, channelId: config.channelId)
        }
        if !config.agentId.isEmpty, let realtime {
            let ownershipSnapshot = ownership()
            Task { await realtime.setConversation(id: id, ownership: ownershipSnapshot) }
        }
    }

    func conversationDidClose(sessionToken: String?) {
        guard let config else { return }
        // Свежий ключ сохраняем; ИМЕЮЩИЙСЯ НЕ СТИРАЕМ — он ключ от строки, от
        // которой форкнется follow-up.
        if let sessionToken, !sessionToken.isEmpty {
            identityStore.setSessionToken(sessionToken, agentId: config.agentId, channelId: config.channelId)
        }
        guard let realtime else { return }
        let ownershipSnapshot = ownership()
        Task { await realtime.setConversation(id: nil, ownership: ownershipSnapshot) }
    }

    func escalationDidChange(_ escalated: Bool) {
        Task { await realtime?.setEscalated(escalated) }
    }

    func bumpUnread(by count: Int) {
        setUnread(unreadBroadcaster.current + count)
    }

    func resetUnread() {
        setUnread(0)
    }

    func languageDidChange(_ lang: String) {
        self.lang = lang
    }

    func requestOpenURL(_ url: URL) -> Bool {
        delegate?.respondoUrlRequested(url) ?? false
    }

    // MARK: - EngagementHost

    func engagementParams() -> EngagementParams {
        EngagementParams(
            agentId: config.flatMap { $0.agentId.isEmpty ? nil : $0.agentId },
            channelId: config?.channelId,
            conversationId: controller?.conversationId,
            visitorId: identityStore.visitorId(),
            email: identity.email,
            userId: identity.userId,
            userHash: identity.userHash
        )
    }

    var engagementVisitorId: String { identityStore.visitorId() }
    var engagementLang: String { lang }
    var engagementScreen: String? { currentScreen }
    var isChatOpen: Bool { chatState == .open || chatState == .opening }

    // MARK: - Приватные сеттеры наблюдаемых

    private func setUnread(_ value: Int) {
        let clamped = max(0, value)
        unreadBroadcaster.sendIfChanged(clamped)
        delegate?.respondoUnreadChanged(clamped)
    }

    private func setChatState(_ state: RespondoChatState) {
        chatStateBroadcaster.sendIfChanged(state)
    }
}
