import Foundation

/// Оркестратор реалтайм-каскада WS → SSE → REST-поллинг.
/// Держит одно активное соединение по правилам `RealtimeStateMachine`, эмитит
/// нормализованные `RealtimeEvent` в единый поток `events`. Всё внутреннее состояние
/// сериализовано актором.
actor RealtimeClient {
    private let apiClient: ApiClient
    private let endpoints: Endpoints
    private let agentId: String

    private var machine = RealtimeStateMachine()
    private var running = false
    // Терминальная защёлка: после stop() клиент уже не поднимется. RespondoEngine
    // создаёт НОВЫЙ RealtimeClient на каждый init/reset, а старый разбирает через
    // stop(). Защищает от гонки, когда tearDownRuntime вызвал stop() в окне между
    // setConversation и start() внутри performInit — start() не воскресит WS.
    private var stopped = false

    // Контекст identify/subscribe.
    private var channelId: String?
    private var visitorId = ""
    private var email: String?
    private var userId: String?
    private var userHash: String?
    private var lang: String?

    private var conversationId: String?
    private var ownership = OwnershipParams()

    // WS.
    private var ws: WebSocketChannel?
    private var wsLoopTask: Task<Void, Never>?
    private var wsReconnectTask: Task<Void, Never>?
    private var wsWatchdog: Task<Void, Never>?
    private var wsConnecting = false
    private var subscribedConvId: String?
    private var backgrounded = false

    // SSE.
    private var sse: SseChannel?
    private var sseLoopTask: Task<Void, Never>?

    // Поллинг.
    private var pollTask: Task<Void, Never>?
    private var pollingCursor: String?

    private var continuation: AsyncStream<RealtimeEvent>.Continuation?
    nonisolated let events: AsyncStream<RealtimeEvent>

    init(apiClient: ApiClient, agentId: String) {
        self.apiClient = apiClient
        self.endpoints = apiClient.endpoints
        self.agentId = agentId
        var captured: AsyncStream<RealtimeEvent>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    // MARK: - Публичное управление

    func setContext(channelId: String?, visitorId: String, email: String?, userId: String?, userHash: String?, lang: String?) {
        self.channelId = channelId
        self.visitorId = visitorId
        self.email = email
        self.userId = userId
        self.userHash = userHash
        self.lang = lang
        if machine.wsHealthy { sendIdentify() }
    }

    func setConversation(id: String?, ownership: OwnershipParams) {
        let changed = conversationId != id
        conversationId = id
        self.ownership = ownership
        machine.conversationPresent = (id != nil)
        if machine.wsHealthy, let id, changed {
            sendSubscribe(id)
        }
        reconcile()
    }

    func setPanelOpen(_ open: Bool) {
        machine.panelOpen = open
        reconcile()
    }

    func setEscalated(_ escalated: Bool) {
        machine.escalated = escalated
    }

    func setPollingCursor(_ messageId: String?) {
        pollingCursor = messageId
    }

    /// Активен ли клиент: `start()` поднял транспорт и `stop()` ещё не вызывался.
    /// Используется тестами жизненного цикла для проверки терминальной защёлки.
    var isRunning: Bool { running }

    func start() {
        guard !stopped else { return } // клиент уже остановлен — не поднимаем соединение
        guard !running else { return }
        running = true
        machine.sseHealthy = true // SSE считается жизнеспособным, пока не пришёл 503
        startWs()
        reconcile()
    }

    func stop() {
        stopped = true
        running = false
        teardownWs()
        teardownFallback()
    }

    /// Отправить read-кадр (только при активном WS; дебаунс — на стороне контроллера).
    func sendRead() {
        guard machine.wsHealthy, let cid = conversationId else { return }
        ws?.send(RealtimeProtocol.readFrame(
            conversationId: cid,
            sessionToken: ownership.sessionToken,
            userHash: ownership.userHash,
            visitorId: ownership.visitorId
        ))
    }

    /// Сигнал ухода приложения в фон: шлём кадр (если WS жив) и помечаем фон, чтобы
    /// на возврате знать о возможном обрыве соединения.
    func notifyBackground() {
        backgrounded = true
        guard machine.wsHealthy else { return }
        ws?.send(RealtimeProtocol.backgroundFrame())
    }

    /// Возврат из фона: если WS жив — шлём foreground-кадр; если соединение оборвалось
    /// в фоне — переподключаемся немедленно, не дожидаясь отложенного reconnect-таймера.
    func notifyForeground() {
        let wasBackgrounded = backgrounded
        backgrounded = false
        if machine.wsHealthy {
            ws?.send(RealtimeProtocol.foregroundFrame())
        } else if running, wasBackgrounded {
            wsReconnectTask?.cancel(); wsReconnectTask = nil
            startWs()
            reconcile()
        }
    }

    /// Ушло ли приложение в фон (для тестов прокидывания lifecycle-хука).
    var isBackgrounded: Bool { backgrounded }

    // MARK: - WS

    private func startWs() {
        guard running, ws == nil else { return }
        wsConnecting = true
        let channel = WebSocketChannel(url: endpoints.websocket(agentId: agentId))
        channel.onOpen = { [weak self] in
            Task { await self?.handleWsOpen() }
        }
        ws = channel
        let stream = channel.connect()
        wsLoopTask = Task { [weak self] in
            for await text in stream {
                await self?.handleWsText(text)
            }
            await self?.handleWsClosed()
        }
        // Сторож: если WS не открылся за 5с — разрешаем фолбэк, не дожидаясь handshake-таймаута.
        wsWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self?.handleWsConnectTimeout()
        }
    }

    private func handleWsOpen() {
        wsConnecting = false
        wsWatchdog?.cancel(); wsWatchdog = nil
        machine.wsHealthy = true
        // Порядок кадров строго identify → subscribe.
        sendIdentify()
        if let cid = conversationId {
            sendSubscribe(cid)
        }
        reconcile() // WS активен — гасим фолбэк.
    }

    private func handleWsConnectTimeout() {
        guard wsConnecting else { return }
        // Соединение висит: разрешаем фолбэк, но не рвём WS (может ещё открыться).
        wsConnecting = false
        reconcile()
    }

    private func handleWsText(_ text: String) {
        guard let event = RealtimeProtocol.decode(text, subscribedConversationId: subscribedConvId) else { return }
        if case .subscribed(let cid) = event {
            subscribedConvId = cid
        }
        // Держим курс поллинга свежим по серверным id из WS — иначе фолбэк
        // WS→поллинг перечитает уже доставленные по WS сообщения (as SSE-ветка).
        if case .newMessage(let dto) = event, isBackendId(dto.id) {
            pollingCursor = dto.id
        }
        // forbidden/ошибка subscribe: не долбим subscribe в цикле — просто прокидываем наверх.
        continuation?.yield(event)
    }

    private func handleWsClosed() {
        ws = nil
        wsLoopTask = nil
        wsWatchdog?.cancel(); wsWatchdog = nil
        wsConnecting = false
        subscribedConvId = nil
        machine.wsHealthy = false
        reconcile() // поднимаем фолбэк
        scheduleWsReconnect()
    }

    private func scheduleWsReconnect() {
        guard running else { return }
        wsReconnectTask?.cancel()
        wsReconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(RealtimeStateMachine.wsReconnectSeconds * 1_000_000_000))
            await self?.startWs()
        }
    }

    private func teardownWs() {
        wsReconnectTask?.cancel(); wsReconnectTask = nil
        wsWatchdog?.cancel(); wsWatchdog = nil
        wsLoopTask?.cancel(); wsLoopTask = nil
        ws?.close(); ws = nil
        wsConnecting = false
        machine.wsHealthy = false
        subscribedConvId = nil
    }

    private func sendIdentify() {
        ws?.send(RealtimeProtocol.identifyFrame(
            visitorId: visitorId,
            email: email,
            userId: userId,
            channelId: channelId,
            sessionToken: ownership.sessionToken,
            userHash: userHash,
            lang: lang,
            conversationId: conversationId
        ))
    }

    private func sendSubscribe(_ conversationId: String) {
        ws?.send(RealtimeProtocol.subscribeFrame(
            conversationId: conversationId,
            sessionToken: ownership.sessionToken,
            userHash: userHash,
            visitorId: visitorId
        ))
    }

    // MARK: - Согласование транспорта

    private func reconcile() {
        guard running else { teardownFallback(); return }
        if wsConnecting {
            // Даём WS завершить попытку — фолбэк не поднимаем.
            teardownFallback()
            return
        }
        switch machine.desiredTransport {
        case .websocket, .idle:
            teardownFallback()
        case .sse:
            stopPolling()
            startSse()
        case .polling:
            stopSse()
            startPolling()
        }
    }

    private func teardownFallback() {
        stopSse()
        stopPolling()
    }

    // MARK: - SSE

    private func startSse() {
        guard sse == nil, let cid = conversationId else { return }
        let channel = SseChannel(apiClient: apiClient)
        sse = channel
        let stream = channel.connect(conversationId: cid, ownership: ownership)
        sseLoopTask = Task { [weak self] in
            for await signal in stream {
                await self?.handleSse(signal)
            }
            await self?.handleSseClosed()
        }
    }

    private func handleSse(_ signal: SseSignal) {
        switch signal {
        case .connected:
            machine.sseHealthy = true
        case .event(let event):
            if case .newMessage(let dto) = event, isBackendId(dto.id) {
                pollingCursor = dto.id
            }
            continuation?.yield(event)
        case .timeout:
            break // после timeout поток закроется → handleSseClosed переподключит
        case .unavailable:
            machine.sseHealthy = false // 503 → деградация к поллингу
        case .closed:
            break
        }
    }

    private func handleSseClosed() {
        sse = nil
        sseLoopTask = nil
        // Переподключаем SSE, если он всё ещё выбранный транспорт; иначе reconcile выберет поллинг.
        reconcile()
    }

    private func stopSse() {
        sse?.close(); sse = nil
        sseLoopTask?.cancel(); sseLoopTask = nil
    }

    // MARK: - Поллинг

    private func startPolling() {
        guard pollTask == nil, conversationId != nil else { return }
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    private func pollLoop() async {
        let firstDelay = machine.firstPollDelaySeconds
        try? await Task.sleep(nanoseconds: UInt64(firstDelay * 1_000_000_000))
        while !Task.isCancelled {
            guard running, !machine.wsHealthy, let cid = conversationId else { break }
            await pollOnce(cid)
            let interval = machine.pollingIntervalSeconds
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if machine.wsHealthy { break }
        }
    }

    private func pollOnce(_ conversationId: String) async {
        do {
            let response = try await apiClient.messages(conversationId: conversationId, after: pollingCursor, ownership: ownership)
            for dto in response.messages ?? [] {
                pollingCursor = dto.id
                continuation?.yield(.newMessage(dto))
            }
            if let status = response.status, status == "resolved" {
                continuation?.yield(.statusChanged(newStatus: status))
            }
        } catch {
            // Любой не-ok молча игнорируется — локальный тред остаётся (fail-safe).
        }
    }

    private func stopPolling() {
        pollTask?.cancel(); pollTask = nil
    }

    private func isBackendId(_ id: String) -> Bool {
        // Серверные id — UUID с дефисами; локальные оптимистичные — без дефиса.
        id.contains("-")
    }
}
