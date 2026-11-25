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
    /// Правило сессий приложения (запуск / возврат из фона, ≥ 20 с между отчётами).
    let sessionTracker: AppSessionTracker
    /// Дедуп `POST /widget/identify` (то же тело дважды не уходит).
    private var identitySync = IdentitySync()
    /// Последний отправленный `POST /widget/identify` (значение — `created` ответа);
    /// по нему сессии приложения и регистрация push-токена ждут ответа (`awaitIdentifyIdle`).
    private var identifyTask: Task<Bool, Never>?

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
    /// Приложение на переднем плане (`active` / `inactive`), а не запущено в фоне
    /// (silent push, background fetch, BGTask). Ядро UIKit не знает: фасад
    /// `RespondoSDK` ставит сюда `UIApplication.shared.applicationState != .background`.
    /// По умолчанию (тесты, macOS) — передний план.
    public var applicationStateProbe: @MainActor () -> Bool = { true }

    // Состояние.
    private var config: RespondoConfig?
    private var identity = RespondoIdentity()
    private var initialized = false
    private var initializing = false
    private var currentScreen: String?
    /// Приложение сейчас на переднем плане: снимок `applicationStateProbe` в начале
    /// init, дальше — хуки жизненного цикла (`willEnterForeground` / `didBecomeActive`
    /// → true, `didEnterBackground` → false). Пока false, отметки сессии не уходят.
    private var inForeground = true
    /// Сессия, которую нельзя было сообщить в фоне (запуск процесса в фоне, вход
    /// другого пользователя из фонового обработчика): уходит при первом настоящем
    /// открытии приложения — по правилу запуска, не по правилу 20 с в фоне.
    private var pendingLaunch = false
    private(set) var lang = "en"
    private(set) var theme: ResolvedTheme = .fallback

    // Рантайм (пересоздаётся при init/reset).
    private var apiClient: ApiClient?
    private var realtime: RealtimeClient?
    private var cache: ConversationCache?
    private var pushManager: PushManager?
    /// Пуш-токен через `reset()`: новый рантайм регистрирует его под новым визитёром, как Android
    /// и Flutter. destroy и повторный init его не переносят.
    private var pushTokenAcrossReset: String?
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
            httpEngineFactory: { URLSessionHttpEngine() },
            sessionTracker: AppSessionTracker.shared
        )
    }

    /// Инъекция зависимостей для тестов (доступен через `@testable import`).
    /// `sessionTracker` nil — свой трекер на этот движок (тесты не делят порог 20 с).
    init(
        secureStore: SecureStore,
        prefs: Preferences,
        httpEngineFactory: @escaping () -> HttpEngine,
        sessionTracker: AppSessionTracker? = nil
    ) {
        self.secureStore = secureStore
        self.prefs = prefs
        self.makeHttpEngine = httpEngineFactory
        self.identityStore = IdentityStore(secure: secureStore, prefs: prefs)
        self.sessionTracker = sessionTracker ?? AppSessionTracker()
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
        // Повторный init = destroy предыдущего + новый. Очередь готового SDK очищается; init
        // поверх ещё не завершённого init проигрывает всё, что вызвано до него (тап холодного
        // старта, токен).
        if initialized || initializing {
            let wasReady = initialized
            tearDownRuntime()
            if wasReady { queue.clear() }
        }
        // Личность init новее identify(), отложенных до него: проигранные после старта, они бы её откатили.
        if identity != nil { queue.dropIdentify() }
        self.config = config
        if let identity { self.identity = identity }
        startInit()
    }

    /// Запускает новое поколение инициализации: бампит номер, отменяет прошлую Task.
    /// `reportLaunch` — сообщить сессию запуска (на `reset()` — нет: это не открытие приложения).
    private func startInit(reportLaunch: Bool = true) {
        initGeneration &+= 1
        let generation = initGeneration
        initializing = true
        initTask?.cancel()
        initTask = Task { [weak self] in await self?.performInit(generation: generation, reportLaunch: reportLaunch) }
    }

    private func performInit(generation: Int, reportLaunch: Bool) async {
        guard let config else { return }
        let systemLocale = Locale.current.identifier
        // Сохранённый язык беседы стартует UI только для продолжаемой беседы: новая беседа
        // определяет язык на сервере заново (локаль устройства, затем детектор).
        let resuming = ConversationCache(prefs: prefs, agentId: config.agentId, channelId: config.channelId).load()?.conversationId != nil
        lang = (resuming ? identityStore.storedLang() : nil) ?? LocalizedStrings.normalize(config.locale ?? systemLocale)

        let api = ApiClient(engine: makeHttpEngine(), baseUrl: config.baseUrl)
        self.apiClient = api
        // Стартовая личность (и её свойства) — в профиль первым запросом, без чата и конфига.
        // Пуш-токен и сокет — после ответа (afterIdentify в конце init).
        let initialIdentify = syncIdentity()
        // Сессия запуска — сразу, не дожидаясь конфига (AppSessionTracker.launched,
        // один раз на процесс: повторный initialize её не даёт), но только если
        // приложение и правда открыто: процесс, поднятый в фоне (silent push,
        // background fetch), сессию не сообщает — она уйдёт при первом открытии
        // (pendingLaunch). Отметка уходит после ответа identify (успех или сбой): с
        // `initialize(config:identity:)` она опережала его и создавала контакт по user_id без email.
        inForeground = applicationStateProbe()
        if reportLaunch {
            // Новый запуск сам решает отложенную сессию прежнего рантайма.
            pendingLaunch = false
            reportAppSession { $0.launched() }
        }

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

        // Язык беседы посетителя, который дал сервер (решение 2026-11-02) — только для
        // продолжаемой беседы, как у виджета: новая беседа определяет язык на сервере
        // заново, и язык прошлого диалога не должен вести UI до первого ответа сервера.
        if resuming, let visitorLang = configDTO?.visitorLanguage, !visitorLang.isEmpty,
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

        let pushManager = PushManager(apiClient: api, identityStore: identityStore, agentId: config.agentId, channelId: config.channelId)
        self.pushManager = pushManager
        // Токен, переживший reset(): регистрация — после ответа identify (afterIdentify).
        if let token = pushTokenAcrossReset {
            pushTokenAcrossReset = nil
            pushManager.adopt(token)
        }

        let engagement = EngagementController(apiClient: api, host: self, prefs: prefs)
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
                if case .overlayShow(let items, let contact) = event {
                    self?.applyOverlayShow(items: items, contact: contact)
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
        // Пуш-токен и сокет — после ответа стартового identify (afterIdentify).
        Task { [weak self] in
            let created = await initialIdentify?.value ?? false
            guard let self, generation == self.initGeneration else { return }
            self.afterIdentify(created: created)
        }

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
        pushTokenAcrossReset = nil
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
            // reset() поверх незавершённого reset(): токен ещё не в PushManager.
            let pushToken = pushManager?.token ?? pushTokenAcrossReset
            tearDownRuntime()
            queue.clear()
            identityStore.wipeAll()
            identity = RespondoIdentity()
            setUnread(0)
            pushTokenAcrossReset = pushToken
            startInit(reportLaunch: false)
        }
    }

    /// Кадр `overlay.show` → engagement-слой, только если он посчитан для
    /// текущего контакта. Сокет переживает `identify()` (`setContext` шлёт
    /// identify по тому же соединению), поэтому кадр прежнего контакта (его
    /// identify или пуш запуска кампании) может прийти после `identify(B)` и
    /// отдал бы B опросы и доставки A. Кадр без штампа `data.identity` тоже
    /// отбрасывается: каталог по HTTP знает, для кого запрошен
    /// (api-surface.md §3.3, как `survey-runtime.ts` на вебе).
    func applyOverlayShow(items: [JSONValue], contact: RespondoIdentity.ContactKey?) {
        guard let contact, contact == identity.contactKey else {
            RespondoLog.debug("overlay.show for another contact dropped")
            return
        }
        engagement?.applyOverlayItems(items)
    }

    // MARK: - Публичные методы (буферизуются до init)

    public func identify(_ identity: RespondoIdentity) {
        guard initialized else { queue.enqueue(.identify(identity)); return }
        // Личность заменяется целиком (api-surface.md §3.3): поле, не переданное
        // в identify(), сбрасывается — так же на вебе, в Android и Flutter.
        let prevKey = self.identity.contactKey
        self.identity = identity
        // Другой контакт: опросы и доставки прежнего (и его запросы в полёте) ему
        // не достаются; события сессии прежнего пользователя — тоже, если он не
        // был анонимом (аноним → пользователь — тот же человек).
        if prevKey != identity.contactKey {
            engagement?.identityChanged(fromAnonymous: prevKey.isAnonymous)
        }
        // Личность (контакт создаётся сразу) и свойства — в профиль, не дожидаясь чата.
        // Вход другого идентифицированного пользователя — его сессия, без порога 20 с,
        // но ПОСЛЕ ответа на identify: новый контакт создаётся уже с именем,
        // свойствами и датой регистрации, и отметка сессии находит его, а не заводит голый.
        let switchedToKnown = prevKey != identity.contactKey && !identity.contactKey.isAnonymous
        let snapshot = identity
        syncIdentity { [weak self] created in
            guard let self else { return }
            if switchedToKnown {
                self.reportAppSession(as: snapshot) { $0.contactChanged() }
            }
            self.afterIdentify(created: created)
        }
        // Обновляем реалтайм-контекст на лету.
        refreshRealtimeContext()
        // Личность изменилась — перезагружаем каталоги оверлеев под нового контакта.
        engagement?.loadCatalogs()
    }

    /// После ответа `/widget/identify` (или сразу, если запроса не было):
    /// - пуш-токен — к контакту текущей личности, когда не останется identify в
    ///   полёте (`registerPushWhenIdle`). Не раньше: регистрация токена могла
    ///   опередить identify и создать контакт первой; теперь контакт уже создан
    ///   identify (с именем, свойствами, датой регистрации);
    /// - `created` — сервер только что создал контакт личности: сокет
    ///   идентифицировался раньше и никого не нашёл, поэтому identify по сокету
    ///   переотправляется — присутствие и оверлеи резолвятся сейчас.
    private func afterIdentify(created: Bool) {
        registerPushWhenIdle()
        if created { refreshRealtimeContext() }
    }

    /// Регистрирует текущий пуш-токен, когда не останется `/widget/identify` в полёте (в том
    /// числе начатого позже): регистрация не создаёт контакт раньше identify. Токен сменили или
    /// сняли за ожидание — регистрируется текущий (или ничего); та же регистрация дважды не уходит.
    private func registerPushWhenIdle() {
        guard let pushManager else { return }
        Task { [weak self] in
            await self?.awaitIdentifyIdle()
            guard let self, self.pushManager === pushManager else { return }
            pushManager.registerPending(identity: self.identity)
        }
    }

    /// Контекст личности сокета (`setContext` шлёт identify по тому же соединению).
    private func refreshRealtimeContext() {
        guard let config, !config.agentId.isEmpty, let realtime else { return }
        let identity = self.identity
        let channelId = config.channelId
        let visitorId = identityStore.visitorId()
        let lang = LocalizedStrings.baseCode(self.lang)
        Task {
            await realtime.setContext(
                channelId: channelId, visitorId: visitorId,
                email: identity.email, userId: identity.userId, userHash: identity.userHash,
                lang: lang
            )
        }
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
        // Событие — после ответа identify в полёте (успех или сбой): иначе /widget/events создавал
        // контакт по user_id без email. Тело (личность) — сейчас. Best-effort.
        Task { [weak self] in
            await self?.awaitIdentifyIdle()
            try? await api.track(body)
        }
        // Событие-триггер оверлей-опроса срабатывает сразу, без сетевого круга.
        engagement?.eventTracked(name)
    }

    /// Открыть оверлей-опрос по id (из редактора опроса, «Additional ways to share»).
    public func startSurvey(_ surveyId: String) {
        guard initialized else { queue.enqueue(.startSurvey(surveyId)); return }
        engagement?.startSurvey(surveyId)
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
        inForeground = false
        // Начало фона — от него меряется правило сессии (≥ 20 с в фоне); первый
        // уход эпизода, повторный сигнал его не сдвигает.
        sessionTracker.wentBackground()
    }

    /// Приложение вернулось на передний план: реалтайм шлёт foreground-кадр и, если
    /// WS оборвался в фоне, переподключается немедленно.
    public func applicationWillEnterForeground() {
        Task { await realtime?.notifyForeground() }
        inForeground = true
        // Процесс жил в фоне и сессию ещё не сообщал — это открытие (правило запуска).
        if pendingLaunch { reportPendingLaunch(); return }
        // Возврат из фона — новая сессия приложения, если в фоне пробыли ≥ 20 с.
        // Событие переднего плана всегда решает отметку фона: не спросили
        // трекер (движок не инициализирован, идёт init, после destroy, нет
        // канала) — отметка снимается, иначе устаревший уход в фон дал бы
        // сессию на следующем быстром возврате.
        guard initialized, reportAppSession({ $0.cameForeground() }) else {
            sessionTracker.discardBackground()
            return
        }
    }

    /// Приложение стало активным (`UIApplication.didBecomeActiveNotification`).
    /// Нужен для отложенного запуска: при холодном старте `willEnterForeground`
    /// не приходит, а у приложения со сценами `applicationState` во время init
    /// может ещё быть `.background`. Обычный возврат из фона решает
    /// `applicationWillEnterForeground`; здесь — только отложенная сессия.
    public func applicationDidBecomeActive() {
        inForeground = true
        if pendingLaunch { reportPendingLaunch() }
    }

    // Отметку фона на обычном возврате решает `applicationWillEnterForeground`
    // (он всегда приходит раньше `didBecomeActive` после `didEnterBackground`).

    /// Отложенная сессия — при первом настоящем открытии. Запуск процесса ещё не
    /// сообщён — по правилу запуска (один раз на процесс), отметка фона снимается:
    /// это то же открытие, второй сессии оно не даёт. Запуск уже был (сессию в
    /// фоне отложил вход другого пользователя из фонового обработчика) — это
    /// возврат из фона: правило ≥ 20 с в фоне.
    private func reportPendingLaunch() {
        pendingLaunch = false
        if sessionTracker.launchAlreadyDecided {
            // Трекер не спросили (нет канала, рантайм снят) — отметку снимаем.
            if !reportAppSession({ $0.cameForeground() }) { sessionTracker.discardBackground() }
            return
        }
        sessionTracker.discardBackground()
        reportAppSession { $0.launched() }
    }

    // MARK: - Профиль контакта: свойства identify() и сессии приложения

    /// `POST /widget/identify`, как `syncIdentity` веб-виджета: личность с `userId`
    /// или `email` создаёт контакт сразу, даже без свойств (вход пользователя в
    /// Intercom Messenger); свойства (`properties` + `languageOverride`) и
    /// `signedUpAt` едут тем же телом. Нужен `channelId`; анониму без свойств —
    /// нечего слать. То же тело дважды не уходит. `after` зовётся, когда запрос
    /// завершён (успехом или ошибкой) вместе с прежними identify в полёте; то же
    /// тело, уже ушедшее, — после их ответа; слать нечего — сразу. Его аргумент —
    /// `created` ответа: сервер создал контакт этой личности.
    /// Возвращает задачу запроса (nil — запроса нет).
    @discardableResult
    private func syncIdentity(
        then after: (@MainActor @Sendable (_ created: Bool) -> Void)? = nil
    ) -> Task<Bool, Never>? {
        guard let config, let api = apiClient,
              let channelId = Self.nonEmpty(config.channelId) else { after?(false); return nil }
        let properties = identity.effectiveProperties
        guard !properties.isEmpty || !identity.contactKey.isAnonymous else { after?(false); return nil }
        let body = IdentifyRequestDTO(
            agentId: Self.nonEmpty(config.agentId),
            channelId: channelId,
            visitorId: identityStore.visitorId(),
            email: Self.nonEmpty(identity.email),
            userId: Self.nonEmpty(identity.userId),
            userHash: Self.nonEmpty(identity.userHash),
            name: Self.nonEmpty(identity.name),
            properties: properties,
            signedUpAt: identity.signedUpAtSeconds
        )
        guard identitySync.claim(body) else {
            // То же тело уже ушло (может, ещё в полёте): его ответ общий — `after` после него.
            if let after {
                Task { [weak self] in
                    await self?.awaitIdentifyIdle()
                    after(false)
                }
            }
            return nil
        }
        let previous = identifyTask
        let task = Task { [weak self] () -> Bool in
            var created = false
            do {
                created = try await api.identify(body)
            } catch {
                self?.identitySync.failed(body)
                RespondoLog.debug("identify sync failed: \(String(describing: error))")
            }
            // Задача завершается, когда завершён и прежний identify: конец последней — в полёте
            // не осталось ни одного (`awaitIdentifyIdle`).
            _ = await previous?.value
            after?(created)
            return created
        }
        identifyTask = task
        return task
    }

    /// Ждёт, пока не останется `POST /widget/identify` в полёте (успех или сбой — неважно),
    /// в том числе запущенного за время ожидания. Сессия приложения и регистрация push-токена
    /// не опережают ответ identify: иначе контакт создавала отметка по user_id — без email, и
    /// импортированная строка с этим email к нему не присоединялась.
    private func awaitIdentifyIdle() async {
        while let task = identifyTask {
            _ = await task.value
            if identifyTask == task {
                identifyTask = nil
                return
            }
        }
    }

    /// `POST /widget/app-session`, если правило `AppSessionTracker` (`decide`) его
    /// пропускает. Нужен `channelId`; без него трекер не спрашивается. В фоне
    /// отметка не уходит вовсе: трекер не спрашивается, сессия откладывается до
    /// первого открытия (`pendingLaunch`, правило запуска). `snapshot` — личность
    /// на момент события (смена контакта), иначе текущая. Best-effort: ошибка
    /// сети лишь теряет одну отметку. Возвращает, спрошен ли трекер (`decide`
    /// вызван — отметка фона им решена); false — не спрошен (нет рантайма или
    /// канала, приложение в фоне), отметку решает вызывающий.
    @discardableResult
    private func reportAppSession(as snapshot: RespondoIdentity? = nil, _ decide: (AppSessionTracker) -> Bool) -> Bool {
        guard let config, let api = apiClient else { return false }
        guard let channelId = Self.nonEmpty(config.channelId) else { return false }
        guard inForeground else { pendingLaunch = true; return false }
        guard decide(sessionTracker) else { return true }
        let who = snapshot ?? identity
        let body = AppSessionRequestDTO(
            agentId: Self.nonEmpty(config.agentId),
            channelId: channelId,
            visitorId: identityStore.visitorId(),
            email: Self.nonEmpty(who.email),
            userId: Self.nonEmpty(who.userId),
            userHash: Self.nonEmpty(who.userHash),
            name: Self.nonEmpty(who.name),
            platform: SdkVersion.platform,
            appId: Self.nonEmpty(Bundle.main.bundleIdentifier),
            appVersion: Self.nonEmpty(who.metadata["app_version"]) ?? Self.nonEmpty(DeviceContext.appVersion),
            sdkName: SdkVersion.source,
            sdkVersion: SdkVersion.current,
            locale: Self.deviceLanguage(configured: config.locale)
        )
        Task { [weak self] in
            // Отметка — после ответа identify в полёте (успех или сбой): решение и тело — сейчас.
            await self?.awaitIdentifyIdle()
            do {
                try await api.appSession(body)
            } catch {
                RespondoLog.debug("app session report failed: \(String(describing: error))")
            }
        }
        return true
    }

    /// Язык устройства для профиля контакта: локаль из конфига, иначе первый
    /// предпочитаемый язык системы (`Locale.current` — язык локализации приложения).
    static func deviceLanguage(configured: String?) -> String? {
        nonEmpty(configured) ?? nonEmpty(Locale.preferredLanguages.first) ?? nonEmpty(Locale.current.identifier)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public func setCurrentScreen(_ name: String?) {
        let changed = currentScreen != name
        currentScreen = name
        // Таргетинг опросов по экрану: новый экран — правила перечитываются.
        if changed, initialized { engagement?.screenDidChange() }
        // Смена экрана = аналог SPA-навигации: перепланируем проактив под новую страницу.
        if changed, initialized, theme.proactiveMessagesEnabled {
            engagement?.scheduleProactive(delay: TimeInterval(theme.proactiveDelaySeconds))
        }
    }

    public func setPushToken(_ token: String) {
        guard initialized, let pushManager else { queue.enqueue(.setPushToken(token)); return }
        // Токен — в PushManager сразу (бикон открытия, ждавший токена, уходит с ним); регистрация —
        // когда identify в полёте не останется.
        pushManager.adopt(token)
        registerPushWhenIdle()
    }

    public func clearPushToken() {
        guard initialized, let pushManager else { queue.enqueue(.clearPushToken); return }
        pushManager.clearToken()
    }

    @discardableResult
    public func handlePush(_ payload: RespondoPushPayload) -> Bool {
        guard initialized else {
            // Дедуп — при проигрывании очереди: PushManager поднимается посреди init, и отметка
            // «виден» до очереди сделала бы проигранный пуш дублем — без открытия и бикона.
            queue.enqueue(.handlePush(payload))
            return true // «свой» ли пуш, решаем сразу; открытие откладываем до init
        }
        // Дедуп по message_id.
        if let pushManager, !pushManager.markProcessed(payload) {
            return true // дубликат — без побочных эффектов, но это наш пуш
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
            case .startSurvey(let id): startSurvey(id)
            case .setPushToken(let token): setPushToken(token)
            case .clearPushToken: clearPushToken()
            // Полный путь: пуши до готовности проходят дедуп markProcessed здесь (при enqueue
            // он не делается), а не сразу processPush.
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
