import Foundation

/// Внутренняя конверсия публичного ответа опроса в JSON тела запроса.
extension RespondoSurveyAnswer {
    var jsonValue: JSONValue {
        switch self {
        case .text(let value), .choice(let value): return .string(value)
        case .number(let value): return .number(value)
        case .multiChoice(let values): return .array(values.map { .string($0) })
        }
    }
}

/// Мост между `EngagementController` и `RespondoEngine`: параметры контакта,
/// текущий экран, состояние панели и открытие URL. Все методы — на главном акторе.
@MainActor
protocol EngagementHost: AnyObject {
    func engagementParams() -> EngagementParams
    var engagementVisitorId: String { get }
    var engagementLang: String { get }
    var engagementScreen: String? { get }
    var isChatOpen: Bool { get }
    func requestOpenURL(_ url: URL) -> Bool
}

/// Ядро engagement-слоя: каталоги (news/surveys/banners/checklists), арбитр оверлеев,
/// проактив, отправка ответов/прогресса. `@Published`-состояние потребляет UI;
/// host-приложение читает потоки (баннеры, непрочитанные новости, проактив).
@MainActor
public final class EngagementController: ObservableObject {
    // MARK: - Наблюдаемое состояние (для UI)

    @Published public private(set) var news: [RespondoNewsItem] = []
    @Published public private(set) var newsUnread: Int = 0
    @Published public private(set) var newsLoading = false
    @Published public private(set) var checklists: [RespondoChecklist] = []
    @Published public private(set) var checklistsLoading = false
    @Published public private(set) var activeOverlay: OverlayDecision = .none

    /// Прогресс текущего опроса-оверлея: индекс шага и собранные ответы.
    @Published public private(set) var surveyStepIndex = 0
    @Published public private(set) var surveyFinished = false
    @Published public private(set) var surveySubmitting = false

    // MARK: - Зависимости

    private let apiClient: ApiClient
    private weak var host: EngagementHost?

    /// Колбэки в движок для host-facing потоков (переживают reset на уровне движка).
    var onProactive: ((RespondoProactiveMessage) -> Void)?
    var onBanners: (([RespondoBanner]) -> Void)?
    var onNewsUnread: ((Int) -> Void)?

    // MARK: - Внутреннее

    private var surveys: [RespondoSurvey] = []
    private var bannerList: [RespondoBanner] = []
    private var dismissed: Set<String> = []
    private var startedChecklists: Set<String> = []
    private var lightboxOpen = false
    private var composerHasText = false
    private var surveyAnswers: [String: RespondoSurveyAnswer] = [:]

    // «Когда и где» опросов (SurveyTargeting): когда открыт текущий экран, какие
    // события-триггеры были в этой сессии и ещё не открыли опрос (живут
    // `SurveyTargeting.eventTTL`, смена экрана их не забывает), таймер ближайшей
    // задержки, опросы, которые сейчас открываются (минт доставки), и те, что
    // сервер открыть отказался.
    private var screenSince = Date()
    private var trackedEvents: [String: Date] = [:]
    private var delayTask: Task<Void, Never>?
    private var openingSurveys: Set<String> = []
    private var refusedSurveys: Set<String> = []
    /// Кампании, открытые явно (`startSurvey`): идут первыми, мимо правил.
    private var explicitSurveys: [String] = []
    /// Закрытые посетителем доставки опросов — переживают перезапуск.
    private let surveyDismissals: SurveyDismissals

    // Поколение контакта: `clear()` (reset/destroy) его повышает, и сетевой
    // ответ, запрошенный для прежнего контакта, отбрасывается — его опрос и
    // доставка не достаются новому. Сами запросы каталога и минта ещё и
    // отменяются (`surveyTasks`).
    private var generation = 0
    private var surveyTasks: [UUID: Task<Void, Never>] = [:]

    private var pendingProactive: RespondoProactiveMessage?
    private var dismissedProactiveScreens: Set<String> = []
    private var proactiveTask: Task<Void, Never>?

    init(apiClient: ApiClient, host: EngagementHost, prefs: Preferences) {
        self.apiClient = apiClient
        self.host = host
        self.surveyDismissals = SurveyDismissals(prefs: prefs)
    }

    // MARK: - Каталоги overlay (surveys + banners): грузятся при identify / overlay.show

    public func loadCatalogs() {
        guard let host else { return }
        let params = host.engagementParams()
        let api = apiClient
        let gen = generation
        trackSurveyTask { [weak self] in
            async let surveysResult = try? api.widgetSurveys(params)
            async let bannersResult = try? api.widgetBanners(params)
            let surveysDTO = await surveysResult
            let bannersDTO = await bannersResult
            guard let self, gen == self.generation else { return }
            if let items = surveysDTO?.surveys {
                // Таргетированный опрос в каталоге всегда без доставки: уже
                // открытый (минт по survey_id) не затираем его пустой копией.
                let opened = self.surveys.filter { !$0.deliveryId.isEmpty }
                self.surveys = items.map(EngagementMapper.toSurvey).map { survey in
                    guard survey.deliveryId.isEmpty else { return survey }
                    return opened.first(where: { $0.campaignId == survey.campaignId }) ?? survey
                }
            }
            if let items = bannersDTO?.banners {
                self.bannerList = items.map(EngagementMapper.toBanner)
                self.onBanners?(self.visibleBanners)
            }
            self.recomputeOverlay()
        }
    }

    /// Обработка WS-события `overlay.show`: элементы каталога приходят пушем.
    /// Каждый item — сырой объект с `content` (OutboundContent) + delivery_id/campaign_id;
    /// классифицируем по content: survey_format → опрос, banner_layout/banner_action → баннер.
    func applyOverlayItems(_ items: [JSONValue]) {
        var newSurveys = surveys
        var newBanners = bannerList
        var bannersChanged = false
        for item in items {
            guard let object = item.objectValue,
                  let data = try? JSONEncoder().encode(item) else { continue }
            let content = object["content"]?.objectValue
            let isSurvey = content?["survey_format"] != nil || content?["questions"] != nil
            let isBanner = content?["banner_layout"] != nil || content?["banner_action"] != nil
            if isSurvey, let dto = try? JSONDecoder().decode(SurveyCatalogItemDTO.self, from: data) {
                // По кампании, а не по доставке: таргетированный опрос приходит
                // без доставки, и повторный пуш не должен затирать уже открытый.
                let survey = EngagementMapper.toSurvey(dto)
                if let index = newSurveys.firstIndex(where: { $0.campaignId == survey.campaignId }) {
                    if newSurveys[index].deliveryId.isEmpty { newSurveys[index] = survey }
                } else {
                    newSurveys.append(survey)
                }
            } else if isBanner, let dto = try? JSONDecoder().decode(BannerCatalogItemDTO.self, from: data) {
                let banner = EngagementMapper.toBanner(dto)
                if !newBanners.contains(where: { $0.deliveryId == banner.deliveryId }) {
                    newBanners.append(banner)
                    bannersChanged = true
                }
            }
        }
        surveys = newSurveys
        bannerList = newBanners
        if bannersChanged { onBanners?(visibleBanners) }
        recomputeOverlay()
    }

    // MARK: - News

    public func loadNews() {
        guard let host else { return }
        newsLoading = true
        let params = host.engagementParams()
        Task { [weak self] in
            let response = try? await self?.apiClient.widgetNews(params)
            guard let self else { return }
            self.newsLoading = false
            guard let response else { return }
            self.news = (response.items ?? []).map(EngagementMapper.toNews)
            self.setNewsUnread(response.unread ?? self.news.filter { !$0.seen }.count)
        }
    }

    public func markNewsSeen(_ id: String) {
        guard let index = news.firstIndex(where: { $0.id == id }), !news[index].seen else { return }
        news[index].seen = true
        setNewsUnread(max(0, newsUnread - 1))
        guard let host else { return }
        let params = host.engagementParams()
        Task { [weak self] in try? await self?.apiClient.widgetNewsSeen(id: id, params: params) }
    }

    // MARK: - Checklists

    public func loadChecklists() {
        guard let host else { return }
        checklistsLoading = true
        let params = host.engagementParams()
        Task { [weak self] in
            let response = try? await self?.apiClient.widgetChecklists(params)
            guard let self else { return }
            self.checklistsLoading = false
            guard let response else { return }
            self.checklists = (response.checklists ?? []).map(EngagementMapper.toChecklist)
            for checklist in self.checklists { self.markChecklistStarted(checklist.id) }
        }
    }

    /// Идемпотентно шлёт `started` при первом показе чек-листа.
    private func markChecklistStarted(_ id: String) {
        guard !startedChecklists.contains(id) else { return }
        startedChecklists.insert(id)
        sendChecklistProgress(id: id, event: "started", taskId: nil)
    }

    /// Тап по задаче чек-листа. url → делегат `onUrlRequested` + отметка выполнения;
    /// manual → переключение чекбокса.
    public func performTask(checklistId: String, taskId: String) {
        guard let index = checklists.firstIndex(where: { $0.id == checklistId }),
              let task = checklists[index].tasks.first(where: { $0.id == taskId }) else { return }
        switch task.action {
        case .url(let url, _):
            _ = host?.requestOpenURL(url)
            setTaskDone(checklistId: checklistId, taskId: taskId, done: true)
        case .manual:
            let isDone = checklists[index].doneTaskIds.contains(taskId)
            setTaskDone(checklistId: checklistId, taskId: taskId, done: !isDone)
        case .tour:
            break // tour-задачи в мобильном контексте скрыты
        }
    }

    private func setTaskDone(checklistId: String, taskId: String, done: Bool) {
        guard let index = checklists.firstIndex(where: { $0.id == checklistId }) else { return }
        if done { checklists[index].doneTaskIds.insert(taskId) }
        else { checklists[index].doneTaskIds.remove(taskId) }
        sendChecklistProgress(id: checklistId, event: done ? "task_done" : "task_undone", taskId: taskId)
    }

    public func dismissChecklist(_ id: String) {
        checklists.removeAll { $0.id == id }
        sendChecklistProgress(id: id, event: "dismissed", taskId: nil)
    }

    private func sendChecklistProgress(id: String, event: String, taskId: String?) {
        guard let host else { return }
        let params = host.engagementParams()
        let body = ChecklistProgressRequestDTO(
            agentId: params.agentId, channelId: params.channelId, visitorId: params.visitorId,
            email: params.email, userId: params.userId, userHash: params.userHash,
            event: event, taskId: taskId
        )
        Task { [weak self] in try? await self?.apiClient.checklistProgress(id: id, body: body) }
    }

    // MARK: - Survey overlay flow

    /// Текущий опрос-оверлей (если арбитр выбрал опрос).
    public var activeSurvey: RespondoSurvey? {
        if case .survey(let survey) = activeOverlay { return survey }
        return nil
    }

    /// Вопросы текущего шага опроса.
    public func currentStepQuestions(_ survey: RespondoSurvey) -> [RespondoQuestion] {
        guard surveyStepIndex < survey.steps.count else { return [] }
        let ids = survey.steps[surveyStepIndex]
        return ids.compactMap { id in survey.questions.first(where: { $0.id == id }) }
    }

    /// Записывает ответ на вопрос (локально + POST /survey/answer).
    public func answerQuestion(_ survey: RespondoSurvey, questionId: String, answer: RespondoSurveyAnswer) {
        surveyAnswers[questionId] = answer
        guard let host else { return }
        let body = SubmitAnswerRequestDTO(
            deliveryId: survey.deliveryId, visitorId: host.engagementVisitorId,
            questionId: questionId, value: answer.jsonValue
        )
        Task { [weak self] in _ = try? await self?.apiClient.surveyAnswer(body) }
    }

    public func answeredValue(_ questionId: String) -> RespondoSurveyAnswer? { surveyAnswers[questionId] }

    /// Все ли обязательные вопросы текущего шага отвечены.
    public func canAdvance(_ survey: RespondoSurvey) -> Bool {
        currentStepQuestions(survey).allSatisfy { !$0.required || surveyAnswers[$0.id] != nil }
    }

    /// Переход к следующему шагу или завершение опроса.
    public func advanceSurvey(_ survey: RespondoSurvey) {
        guard canAdvance(survey) else { return }
        if surveyStepIndex + 1 < survey.steps.count {
            surveyStepIndex += 1
        } else {
            finishSurvey(survey)
        }
    }

    private func finishSurvey(_ survey: RespondoSurvey) {
        surveyFinished = true
        surveySubmitting = true
        guard let host else { return }
        let body = SubmitSurveyRequestDTO(
            deliveryId: survey.deliveryId, visitorId: host.engagementVisitorId,
            answers: surveyAnswers.mapValues { $0.jsonValue }
        )
        Task { [weak self] in
            _ = try? await self?.apiClient.surveySubmit(body)
            self?.surveySubmitting = false
        }
    }

    /// Закрыть текущий опрос (крестик или после благодарности).
    public func dismissSurvey(_ deliveryId: String) {
        dismissed.insert(deliveryId)
        surveyDismissals.add(deliveryId)
        if let survey = surveys.first(where: { $0.deliveryId == deliveryId }) {
            explicitSurveys.removeAll { $0 == survey.campaignId }
        }
        resetSurveyProgress()
        recomputeOverlay()
    }

    private func resetSurveyProgress() {
        surveyStepIndex = 0
        surveyFinished = false
        surveySubmitting = false
        surveyAnswers = [:]
    }

    // MARK: - Когда и где (таргетинг опросов)

    /// Хост сменил экран (`setCurrentScreen`): правила перечитываются для нового
    /// экрана, время на экране начинается заново. События сессии остаются —
    /// `track` перед переходом на экран опроса его откроет. Показанный опрос
    /// остаётся — он следует за посетителем.
    func screenDidChange() {
        screenSince = Date()
        recomputeOverlay()
    }

    /// `Respondo.track(name)`: опрос с таким событием-триггером открывается сразу
    /// (после своей задержки), а не при следующей загрузке каталога.
    func eventTracked(_ name: String) {
        let canon = SurveyTargeting.normalizeEventName(name)
        guard !canon.isEmpty else { return }
        trackedEvents[canon] = Date()
        recomputeOverlay()
    }

    /// Открыть опрос по id кампании прямо сейчас (`Respondo.startSurvey`): мимо
    /// правил экранов, задержки, события и аудитории; расписание, канал и уже
    /// данный ответ сервер проверяет.
    public func startSurvey(_ campaignId: String) {
        let id = campaignId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        if case .survey(let current) = activeOverlay, current.campaignId == id { return }
        openSurvey(campaignId: id, explicit: true)
    }

    /// Минт доставки опроса, который решено показать: GET /widget/surveys?survey_id=.
    private func openSurvey(campaignId: String, explicit: Bool) {
        guard let host, !openingSurveys.contains(campaignId) else { return }
        openingSurveys.insert(campaignId)
        let params = host.engagementParams()
        let api = apiClient
        let gen = generation
        trackSurveyTask { [weak self] in
            let response = try? await api.widgetSurveys(params, surveyId: campaignId, explicit: explicit)
            // Контакт сменился, пока шёл запрос: опрос и доставка — прежнего контакта.
            guard let self, gen == self.generation else { return }
            self.openingSurveys.remove(campaignId)
            guard let dto = response?.surveys?.first, !dto.deliveryId.isEmpty else {
                // Сервер отказал (аудитория, расписание, уже отвечен): на этом
                // запуске больше не спрашиваем.
                if !explicit { self.refusedSurveys.insert(campaignId) }
                self.recomputeOverlay()
                return
            }
            let survey = EngagementMapper.toSurvey(dto)
            // Событие, открывшее опрос, израсходовано: один track — один показ.
            if !explicit, let trigger = self.surveys.first(where: { $0.campaignId == campaignId })?.targeting.triggerEvent {
                self.trackedEvents[trigger] = nil
            }
            if let index = self.surveys.firstIndex(where: { $0.campaignId == campaignId }) {
                self.surveys[index] = survey
            } else {
                self.surveys.append(survey)
            }
            if explicit {
                // Явный запуск показывает опрос снова, даже если его закрывали.
                self.dismissed.remove(survey.deliveryId)
                self.surveyDismissals.remove(survey.deliveryId)
                if !self.explicitSurveys.contains(campaignId) { self.explicitSurveys.append(campaignId) }
            }
            self.recomputeOverlay()
        }
    }

    /// Опросы, которые могут быть показаны прямо сейчас, в порядке приоритета:
    /// уже показанный (следует за посетителем), явно запрошенные, затем каталог
    /// по готовности. Попутно открывает готовые таргетированные опросы и ставит
    /// таймер ближайшей задержки.
    private func showableSurveys() -> [RespondoSurvey] {
        delayTask?.cancel()
        delayTask = nil
        var out: [RespondoSurvey] = []
        if case .survey(let current) = activeOverlay, !isDismissed(current.deliveryId) {
            out.append(current)
        }
        for id in explicitSurveys {
            if let survey = surveys.first(where: { $0.campaignId == id && !$0.deliveryId.isEmpty }) {
                out.append(survey)
            }
        }
        let now = Date()
        trackedEvents = SurveyTargeting.freshEvents(trackedEvents, now: now)
        var soonest: TimeInterval?
        for survey in surveys {
            if !survey.deliveryId.isEmpty, isDismissed(survey.deliveryId) { continue }
            if refusedSurveys.contains(survey.campaignId) { continue }
            // Доставка есть и посетитель опрос не закрывал — его уже открывали
            // этому посетителю (может быть, до перезапуска): он продолжается на
            // любом экране. Закрытый остаётся закрытым и после перезапуска.
            switch SurveyTargeting.readiness(
                survey.targeting, screen: host?.engagementScreen,
                screenSince: screenSince, events: trackedEvents, now: now,
                resumed: !survey.deliveryId.isEmpty
            ) {
            case .ready:
                if survey.deliveryId.isEmpty {
                    openSurvey(campaignId: survey.campaignId, explicit: false)
                } else {
                    out.append(survey)
                }
            case .delay(let seconds):
                soonest = min(soonest ?? seconds, seconds)
            case .event, .elsewhere:
                break
            }
        }
        if let soonest {
            delayTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((soonest + 0.05) * 1_000_000_000))
                if Task.isCancelled { return }
                self?.recomputeOverlay()
            }
        }
        var seen: Set<String> = []
        return out.filter { seen.insert($0.campaignId).inserted }
    }

    // MARK: - Banner

    public func bannerReaction(_ banner: RespondoBanner, emoji: String) {
        sendBannerResponse(banner, kind: "reaction", value: emoji)
        if banner.dismissAfterAction { dismissBanner(banner.deliveryId) }
    }

    public func bannerEmail(_ banner: RespondoBanner, email: String) {
        sendBannerResponse(banner, kind: "email", value: email)
        if banner.dismissAfterAction { dismissBanner(banner.deliveryId) }
    }

    /// Клик по CTA баннера (action=url).
    public func bannerOpenURL(_ banner: RespondoBanner) {
        if let url = banner.url { _ = host?.requestOpenURL(url) }
        if banner.dismissAfterAction { dismissBanner(banner.deliveryId) }
    }

    private func sendBannerResponse(_ banner: RespondoBanner, kind: String, value: String) {
        guard let host else { return }
        let body = BannerResponseRequestDTO(
            deliveryId: banner.deliveryId, visitorId: host.engagementVisitorId, kind: kind, value: value
        )
        Task { [weak self] in try? await self?.apiClient.bannerResponse(body) }
    }

    public func dismissBanner(_ deliveryId: String) {
        dismissed.insert(deliveryId)
        onBanners?(visibleBanners)
        recomputeOverlay()
    }

    // MARK: - Проактив

    /// Запланировать запрос проактива под текущий экран с задержкой `delay` секунд.
    public func scheduleProactive(delay: TimeInterval) {
        proactiveTask?.cancel()
        guard let host, host.engagementParams().agentId != nil else { return }
        let screen = host.engagementScreen
        if let screen, dismissedProactiveScreens.contains(screen) { return }
        proactiveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.fetchProactive()
        }
    }

    private func fetchProactive() async {
        guard let host, host.isChatOpen == false, let agentId = host.engagementParams().agentId else { return }
        // Веб-паритет: проактив не запрашиваем и не показываем, если уже есть активная
        // беседа (посетитель уже в диалоге — тизер был бы навязчивым дублем).
        if let conversationId = host.engagementParams().conversationId, !conversationId.isEmpty { return }
        let screen = host.engagementScreen
        if let screen, dismissedProactiveScreens.contains(screen) { return }
        let dto = (try? await apiClient.proactive(
            agentId: agentId, pageTitle: screen, pagePath: screen,
            pageDescription: nil, lang: LocalizedStrings.baseCode(host.engagementLang)
        )) ?? nil
        guard let message = dto?.message, !message.isEmpty else { return }
        let proactive = RespondoProactiveMessage(text: message, pagePath: dto?.pagePath ?? screen)
        pendingProactive = proactive
        onProactive?(proactive)
    }

    /// Забрать проактив для показа в треде (и очистить).
    public func consumeProactive() -> RespondoProactiveMessage? {
        let message = pendingProactive
        pendingProactive = nil
        return message
    }

    public func dismissProactive() {
        if let screen = host?.engagementScreen { dismissedProactiveScreens.insert(screen) }
        pendingProactive = nil
    }

    // MARK: - Подавление оверлеев

    public func setLightboxOpen(_ open: Bool) {
        guard lightboxOpen != open else { return }
        lightboxOpen = open
        recomputeOverlay()
    }

    public func setComposerHasText(_ hasText: Bool) {
        guard composerHasText != hasText else { return }
        composerHasText = hasText
        recomputeOverlay()
    }

    // MARK: - Служебное

    private var visibleBanners: [RespondoBanner] {
        bannerList.filter { !dismissed.contains($0.deliveryId) }
    }

    private func recomputeOverlay() {
        let previous = activeOverlay
        let decision = OverlayArbiter.decide(OverlayArbiterInput(
            surveys: showableSurveys(), banners: bannerList, dismissed: dismissed,
            lightboxOpen: lightboxOpen, composerHasText: composerHasText
        ))
        // При смене выбранного опроса сбрасываем прогресс шагов.
        if case .survey(let newSurvey) = decision, case .survey(let oldSurvey) = previous,
           newSurvey.campaignId != oldSurvey.campaignId {
            resetSurveyProgress()
        }
        if case .survey = decision, case .survey = previous {} else if decision != previous {
            resetSurveyProgress()
        }
        activeOverlay = decision
    }

    private func setNewsUnread(_ value: Int) {
        newsUnread = value
        onNewsUnread?(value)
    }

    /// Доставка закрыта: на этом запуске или раньше (опрос — в `surveyDismissals`).
    private func isDismissed(_ deliveryId: String) -> Bool {
        dismissed.contains(deliveryId) || surveyDismissals.contains(deliveryId)
    }

    /// Запрос опросов, который `clear()` отменит.
    private func trackSurveyTask(_ body: @escaping @MainActor () async -> Void) {
        let id = UUID()
        surveyTasks[id] = Task { [weak self] in
            await body()
            self?.surveyTasks[id] = nil
        }
    }

    /// `identify()` сменил контакт (другой email или userId, в том числе аноним →
    /// пользователь): опросы и доставки прежнего контакта ему не достаются.
    /// Поколение растёт — каталог и минт, запрошенные для прежнего контакта,
    /// отбрасываются, даже если придут последними; открытые доставки, явные
    /// запуски и закрытия этого запуска забываются, каталог грузится заново
    /// (`loadCatalogs`). Закрытые доставки в хранилище остаются: id доставки свой
    /// у каждого контакта. Время на экране не трогается. События сессии
    /// (`eventTracked`) остаются только при смене аноним → пользователь (тот же
    /// человек вошёл); после другого пользователя (A → B) они забываются —
    /// `track()` пользователя A не открывает опрос пользователю B.
    func identityChanged(fromAnonymous: Bool) {
        dropContactState()
        if !fromAnonymous { trackedEvents = [:] }
        onBanners?(visibleBanners)
        recomputeOverlay()
    }

    /// Состояние опросов и баннеров, принадлежащее контакту.
    private func dropContactState() {
        generation &+= 1
        surveyTasks.values.forEach { $0.cancel() }
        surveyTasks = [:]
        openingSurveys = []; refusedSurveys = []; explicitSurveys = []
        surveys = []; bannerList = []; dismissed = []
        resetSurveyProgress()
        activeOverlay = .none
    }

    /// Закрытые опросы в хранилище остаются: `destroy()` хранилище сохраняет, а
    /// `reset()` стирает его целиком.
    func clear() {
        dropContactState()
        proactiveTask?.cancel()
        delayTask?.cancel(); delayTask = nil
        trackedEvents = [:]
        screenSince = Date()
        news = []; checklists = []
        startedChecklists = []
    }
}
