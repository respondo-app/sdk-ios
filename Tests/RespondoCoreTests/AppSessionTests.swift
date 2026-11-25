import XCTest
@testable import RespondoCore

/// Профиль контакта без чата (модель Intercom): свойства `identify()` уходят в
/// `POST /widget/identify` сразу, сессии приложения — в `POST /widget/app-session`
/// по правилу Intercom «≥ 20 с в фоне — новая сессия» (AppSessionTracker).
@MainActor
final class AppSessionTests: XCTestCase {
    private let agentId = "7d3f9c2a-1e4b-4a6d-9f21-8c5b0e7a4d10"

    final class FakePresenter: ChatPresenter {
        func present(surface: ChatSurface) {}
        func dismiss() {}
        var isPresented: Bool { false }
    }

    /// Управляемые часы трекера.
    final class TestClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    /// Состояние приложения для `applicationStateProbe`: false — процесс поднят в фоне.
    final class AppState {
        var foreground = true
    }

    // MARK: - Правило сессии (Intercom: ≥ 20 с в фоне — новая сессия)

    func testTrackerLaunchOncePerProcess() {
        let clock = TestClock()
        let tracker = AppSessionTracker(clock: { clock.now })
        XCTAssertTrue(tracker.launched(), "запуск — сессия")
        XCTAssertTrue(tracker.launchAlreadyDecided)
        clock.advance(5)
        XCTAssertFalse(tracker.launched(), "повторный initialize через 5 с — не запуск")
        clock.advance(600)
        XCTAssertFalse(tracker.launched(), "повторный initialize через 10 мин — тоже не запуск: один раз на процесс")
        tracker.resetLaunchForTesting()
        XCTAssertTrue(tracker.launched(), "хук тестов снимает отметку")
    }

    func testTrackerForegroundCountsTimeInBackground() {
        let clock = TestClock()
        let tracker = AppSessionTracker(clock: { clock.now })
        XCTAssertTrue(tracker.launched())
        clock.advance(60)
        tracker.wentBackground()
        clock.advance(5)
        XCTAssertFalse(tracker.cameForeground(), "5 с в фоне — та же сессия")
        tracker.wentBackground()
        clock.advance(25)
        XCTAssertTrue(tracker.cameForeground(), "25 с в фоне — новая сессия")
        XCTAssertEqual(tracker.lastReported, clock.now)
    }

    func testTrackerForegroundWithoutBackgroundIsNotASession() {
        let clock = TestClock()
        let tracker = AppSessionTracker(clock: { clock.now })
        clock.advance(100)
        XCTAssertFalse(tracker.cameForeground(), "фона не было — сессии нет")
        tracker.wentBackground()
        clock.advance(30)
        XCTAssertTrue(tracker.cameForeground())
        clock.advance(30)
        XCTAssertFalse(tracker.cameForeground(), "отметка фона снимается возвратом")
    }

    func testTrackerContactChangedIgnoresGap() {
        let clock = TestClock()
        let tracker = AppSessionTracker(clock: { clock.now })
        XCTAssertTrue(tracker.launched())
        clock.advance(1)
        XCTAssertTrue(tracker.contactChanged(), "вход другого пользователя — сразу")
        XCTAssertEqual(tracker.lastReported, clock.now)
        clock.advance(5)
        XCTAssertFalse(tracker.launched(), "запуск сразу после отчёта о входе — не новая сессия")
    }

    // MARK: - Дедуп identify и languageOverride

    func testIdentitySyncDedupesSameBody() {
        var sync = IdentitySync()
        let body = IdentifyRequestDTO(agentId: agentId, channelId: "ch-1", visitorId: "v_1", email: "a@x.io",
                                      properties: ["plan": "pro", "seats": "3"])
        XCTAssertTrue(sync.claim(body))
        XCTAssertFalse(sync.claim(body), "то же тело второй раз не уходит")
        var other = body
        other.properties["plan"] = "team"
        XCTAssertTrue(sync.claim(other), "другое тело уходит")
        sync.failed(body)
        XCTAssertFalse(sync.claim(other), "сбой прежнего тела не снимает отметку нового")
        sync.failed(other)
        XCTAssertTrue(sync.claim(other), "после сбоя то же тело уходит снова")
    }

    func testEffectivePropertiesCarryLanguageOverride() {
        let identity = RespondoIdentity(
            email: "a@x.io",
            properties: ["plan": "pro", "language_override": "fr"],
            languageOverride: " de "
        )
        XCTAssertEqual(identity.effectiveProperties, ["plan": "pro", "language_override": "de"],
                       "типизированное поле главнее одноимённого ключа")
        XCTAssertEqual(RespondoIdentity(properties: ["plan": "pro"], languageOverride: "  ").effectiveProperties,
                       ["plan": "pro"], "пустой язык не уходит")
        XCTAssertTrue(RespondoIdentity().effectiveProperties.isEmpty)
    }

    // MARK: - Движок

    private func makeEngine(
        channelId: String? = "ch-1",
        identity: RespondoIdentity? = nil,
        clock: TestClock = TestClock(),
        state: AppState = AppState()
    ) async -> (RespondoEngine, FakeHttpEngine) {
        let http = FakeHttpEngine()
        http.stub(pathContains: "/api/v1/widget/config", json: String(data: Fixture.data("config"), encoding: .utf8)!)
        http.stub(pathContains: "/api/v1/widget/identify", json: #"{"ok":true}"#)
        http.stub(pathContains: "/api/v1/widget/app-session", json: #"{"ok":true}"#)
        http.stub(pathContains: "/widget/surveys", json: #"{"surveys":[]}"#)
        let engine = RespondoEngine(
            secureStore: InMemorySecureStore(),
            prefs: InMemoryPreferences(),
            httpEngineFactory: { http },
            sessionTracker: AppSessionTracker(clock: { clock.now })
        )
        engine.setPresenter(FakePresenter())
        engine.applicationStateProbe = { state.foreground }
        engine.initialize(config: RespondoConfig(agentId: agentId, channelId: channelId), identity: identity)
        // Каталоги запрашиваются после `initialized = true` и синхронизации личности.
        await waitUntil(timeout: 3) { http.requestSent(pathContains: "/widget/surveys") }
        return (engine, http)
    }

    private func requests(_ http: FakeHttpEngine, _ path: String) -> [HttpRequest] {
        http.sentRequests.filter { $0.url.absoluteString.contains(path) }
    }

    private func json(_ request: HttpRequest) -> [String: Any] {
        guard let body = request.body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            XCTFail("тело запроса не JSON")
            return [:]
        }
        return object
    }

    func testInitReportsAppSessionWithPlatformAndChannel() async {
        let (_, http) = await makeEngine()
        await waitUntil { http.requestSent(pathContains: "/api/v1/widget/app-session") }
        let sessions = requests(http, "/api/v1/widget/app-session")
        XCTAssertEqual(sessions.count, 1, "запуск — одна сессия")
        let body = json(sessions[0])
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["channel_id"] as? String, "ch-1")
        XCTAssertEqual(body["agent_id"] as? String, agentId)
        XCTAssertEqual(body["sdk_name"] as? String, SdkVersion.source)
        XCTAssertEqual(body["sdk_version"] as? String, SdkVersion.current)
        XCTAssertFalse((body["visitor_id"] as? String ?? "").isEmpty, "аноним — по visitor_id")
        XCTAssertFalse((body["locale"] as? String ?? "").isEmpty, "язык устройства")
        XCTAssertNil(body["email"], "пустые поля не уходят")
    }

    func testIdentifyWithPropertiesPostsIdentifyOnceAndReportsContactSession() async {
        let (engine, http) = await makeEngine()
        await waitUntil { http.requestSent(pathContains: "/api/v1/widget/app-session") }
        XCTAssertFalse(http.requestSent(pathContains: "/api/v1/widget/identify"), "аноним без свойств — нечего слать")

        let identity = RespondoIdentity(email: "a@x.io", name: "Ann", userHash: "hash-a",
                                        properties: ["plan": "pro"], languageOverride: "de")
        engine.identify(identity)
        await waitUntil { self.requests(http, "/api/v1/widget/identify").count == 1 }
        let body = json(requests(http, "/api/v1/widget/identify")[0])
        XCTAssertEqual(body["email"] as? String, "a@x.io")
        XCTAssertEqual(body["user_hash"] as? String, "hash-a")
        XCTAssertEqual(body["channel_id"] as? String, "ch-1")
        XCTAssertEqual(body["properties"] as? [String: String], ["plan": "pro", "language_override": "de"])

        // Аноним → пользователь: его сессия мимо порога 20 с, но после identify —
        // контакт создаётся с именем и свойствами, а не голой отметкой.
        await waitUntil { self.requests(http, "/api/v1/widget/app-session").count == 2 }
        let order = http.sentRequests.map(\.url.absoluteString)
        let identifyAt = order.firstIndex { $0.contains("/api/v1/widget/identify") }!
        let sessionAt = order.lastIndex { $0.contains("/api/v1/widget/app-session") }!
        XCTAssertLessThan(identifyAt, sessionAt, "сессия нового контакта — после identify")
        let session = json(requests(http, "/api/v1/widget/app-session")[1])
        XCTAssertEqual(session["email"] as? String, "a@x.io")
        XCTAssertEqual(session["name"] as? String, "Ann", "имя едет и в отметке сессии")

        // Та же личность ещё раз — ни identify, ни сессии.
        engine.identify(identity)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(requests(http, "/api/v1/widget/identify").count, 1, "то же тело дважды не уходит")
        XCTAssertEqual(requests(http, "/api/v1/widget/app-session").count, 2, "тот же контакт — не новая сессия")

        // Новое свойство того же контакта — новое тело, но не сессия.
        engine.identify(RespondoIdentity(email: "a@x.io", userHash: "hash-a", properties: ["plan": "team"], languageOverride: "de"))
        await waitUntil { self.requests(http, "/api/v1/widget/identify").count == 2 }
        XCTAssertEqual(requests(http, "/api/v1/widget/app-session").count, 2)
    }

    func testInitialIdentityPropertiesSyncedAtInit() async {
        let (_, http) = await makeEngine(identity: RespondoIdentity(userId: "u-1", properties: ["plan": "pro"]))
        await waitUntil { http.requestSent(pathContains: "/api/v1/widget/identify") }
        let body = json(requests(http, "/api/v1/widget/identify")[0])
        XCTAssertEqual(body["user_id"] as? String, "u-1")
        XCTAssertEqual(body["properties"] as? [String: String], ["plan": "pro"])
    }

    func testForegroundReportsSessionOnlyAfterTwentySecondsInBackground() async {
        let clock = TestClock()
        let (engine, http) = await makeEngine(clock: clock)
        await waitUntil { http.requestSent(pathContains: "/api/v1/widget/app-session") }

        clock.advance(60)
        engine.applicationWillEnterForeground()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(requests(http, "/api/v1/widget/app-session").count, 1, "возврат без фона — не сессия")

        engine.applicationDidEnterBackground()
        clock.advance(5)
        engine.applicationWillEnterForeground()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(requests(http, "/api/v1/widget/app-session").count, 1, "5 с в фоне — та же сессия")

        engine.applicationDidEnterBackground()
        clock.advance(25)
        engine.applicationWillEnterForeground()
        await waitUntil { self.requests(http, "/api/v1/widget/app-session").count == 2 }
    }

    /// Вход пользователя создаёт контакт (как Intercom Messenger): identify с `userId`
    /// уходит и без свойств, сессия нового контакта — после его ответа.
    func testBareIdentifyCreatesThePersonThenReportsTheSession() async {
        let (engine, http) = await makeEngine()
        await waitUntil { http.requestSent(pathContains: "/api/v1/widget/app-session") }
        engine.identify(RespondoIdentity(userId: "u-7", name: "Bo"))
        await waitUntil { self.requests(http, "/api/v1/widget/app-session").count == 2 }
        let identifies = requests(http, "/api/v1/widget/identify")
        XCTAssertEqual(identifies.count, 1, "userId без свойств — identify уходит: вход создаёт контакт")
        let body = json(identifies[0])
        XCTAssertEqual(body["user_id"] as? String, "u-7")
        XCTAssertEqual(body["name"] as? String, "Bo")
        XCTAssertEqual(body["properties"] as? [String: String], [:])
        XCTAssertNil(body["signed_up_at"], "дата регистрации не передана — не уходит")
        let order = http.sentRequests.map(\.url.absoluteString)
        let identifyAt = order.firstIndex { $0.contains("/api/v1/widget/identify") }!
        let sessionAt = order.lastIndex { $0.contains("/api/v1/widget/app-session") }!
        XCTAssertLessThan(identifyAt, sessionAt, "сессия нового контакта — после identify")
        let session = json(requests(http, "/api/v1/widget/app-session")[1])
        XCTAssertEqual(session["user_id"] as? String, "u-7")
        XCTAssertEqual(session["name"] as? String, "Bo")

        // Тот же вход ещё раз — то же тело, второй identify не уходит.
        engine.identify(RespondoIdentity(userId: "u-7", name: "Bo"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(requests(http, "/api/v1/widget/identify").count, 1)
    }

    /// Пуш-токен — к контакту ПОСЛЕ ответа identify (как отметка сессии):
    /// регистрация токена не опережает `/widget/identify` и не создаёт контакт первой.
    func testPushRegisterGoesAfterTheIdentifyAnswer() async {
        let (engine, http) = await makeEngine()
        http.stub(pathContains: "/api/v1/widget/push/register", json: #"{"ok":true}"#)
        http.responseDelay = 0.05
        engine.setPushToken("apns-token")
        await waitUntil { self.requests(http, "/api/v1/widget/push/register").count == 1 }
        engine.identify(RespondoIdentity(userId: "u-9"))
        await waitUntil { self.requests(http, "/api/v1/widget/push/register").count == 2 }
        let order = http.sentRequests.map(\.url.absoluteString)
        let identifyAt = order.firstIndex { $0.contains("/api/v1/widget/identify") }!
        let registerAt = order.lastIndex { $0.contains("/api/v1/widget/push/register") }!
        XCTAssertLessThan(identifyAt, registerAt, "регистрация токена — после ответа identify")
        XCTAssertEqual(json(requests(http, "/api/v1/widget/push/register")[1])["user_id"] as? String, "u-9")
    }

    /// Ответ `created` — контакт создан этим identify; без тела или другого вида — не «создан»
    /// и не сбой.
    func testIdentifyAnswerCreatedFlag() async throws {
        let http = FakeHttpEngine()
        let api = ApiClient(engine: http, baseUrl: "https://api.respondo.ai")
        let body = IdentifyRequestDTO(channelId: "ch-1", userId: "u-1", properties: [:])
        http.stub(pathContains: "/api/v1/widget/identify", json: #"{"ok":true,"created":true}"#)
        let created = try await api.identify(body)
        XCTAssertTrue(created)
        http.stubs.removeAll()
        http.stub(pathContains: "/api/v1/widget/identify", json: #"{"ok":true}"#)
        let known = try await api.identify(body)
        XCTAssertFalse(known)
        http.stubs.removeAll()
        let empty = try await api.identify(body) // 204 без тела
        XCTAssertFalse(empty)
    }

    func testAnonymousIdentityWithoutPropertiesSendsNoIdentify() async {
        let (engine, http) = await makeEngine()
        engine.identify(RespondoIdentity(name: "Anon", userHash: "h"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(http.requestSent(pathContains: "/api/v1/widget/identify"), "аноним без свойств — нечего слать")
    }

    /// `signedUpAt` — дата регистрации в продукте, Unix-секундами в `signed_up_at`.
    func testSignedUpAtGoesAsUnixSeconds() async {
        let (engine, http) = await makeEngine()
        engine.identify(RespondoIdentity(userId: "u-8", signedUpAt: Date(timeIntervalSince1970: 1_717_149_600.9)))
        await waitUntil { http.requestSent(pathContains: "/api/v1/widget/identify") }
        let body = json(requests(http, "/api/v1/widget/identify")[0])
        XCTAssertEqual((body["signed_up_at"] as? NSNumber)?.int64Value, 1_717_149_600)
        XCTAssertNil(RespondoIdentity(userId: "u-8").signedUpAtSeconds)
    }

    func testResetDoesNotReportSession() async {
        let clock = TestClock()
        let (engine, http) = await makeEngine(clock: clock)
        await waitUntil { http.requestSent(pathContains: "/api/v1/widget/app-session") }
        let catalogs = requests(http, "/widget/surveys").count
        clock.advance(60)
        engine.reset()
        // Повторная инициализация после reset снова запрашивает каталоги.
        await waitUntil(timeout: 3) { self.requests(http, "/widget/surveys").count > catalogs }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(requests(http, "/api/v1/widget/app-session").count, 1, "reset — не открытие приложения")
    }

    func testNoChannelSendsNeitherIdentifyNorSession() async {
        let (engine, http) = await makeEngine(
            channelId: nil,
            identity: RespondoIdentity(email: "a@x.io", properties: ["plan": "pro"], languageOverride: "de")
        )
        engine.identify(RespondoIdentity(email: "b@x.io", properties: ["plan": "team"]))
        engine.applicationWillEnterForeground()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(http.requestSent(pathContains: "/api/v1/widget/identify"), "без channelId identify не уходит")
        XCTAssertFalse(http.requestSent(pathContains: "/api/v1/widget/app-session"), "без channelId сессии не уходят")
    }

    // MARK: - Запуск процесса в фоне (silent push, background fetch)

    func testBackgroundStartReportsNoSessionUntilTheAppOpens() async {
        let state = AppState()
        state.foreground = false
        let (engine, http) = await makeEngine(state: state)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(http.requestSent(pathContains: "/api/v1/widget/app-session"), "процесс в фоне — не открытие")

        // Вход пользователя из фонового обработчика тоже ждёт открытия.
        engine.identify(RespondoIdentity(userId: "u-bg", name: "Bg"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(http.requestSent(pathContains: "/api/v1/widget/app-session"), "в фоне отметок нет вовсе")

        // Пользователь открыл приложение — одна сессия, по правилу запуска.
        state.foreground = true
        engine.applicationWillEnterForeground()
        await waitUntil { self.requests(http, "/api/v1/widget/app-session").count == 1 }
        XCTAssertEqual(json(requests(http, "/api/v1/widget/app-session")[0])["user_id"] as? String, "u-bg")
        engine.applicationDidBecomeActive()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(requests(http, "/api/v1/widget/app-session").count, 1, "didBecomeActive после — та же сессия")
    }

    func testColdStartWithSceneStillInBackgroundReportsOnBecomeActive() async {
        let state = AppState()
        state.foreground = false
        let (engine, http) = await makeEngine(state: state)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(http.requestSent(pathContains: "/api/v1/widget/app-session"))
        // Холодный старт: willEnterForeground не приходит, приходит didBecomeActive.
        state.foreground = true
        engine.applicationDidBecomeActive()
        await waitUntil { self.requests(http, "/api/v1/widget/app-session").count == 1 }
    }

    func testForegroundStartReportsSessionAtInit() async {
        let (engine, http) = await makeEngine()
        await waitUntil { self.requests(http, "/api/v1/widget/app-session").count == 1 }
        engine.applicationDidBecomeActive()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(requests(http, "/api/v1/widget/app-session").count, 1, "активность после открытия — не вторая сессия")
    }

    func testTrackerFirstBackgroundMomentOfEpisodeWins() {
        let clock = TestClock()
        let tracker = AppSessionTracker(clock: { clock.now })
        tracker.wentBackground()            // t0
        clock.advance(30)
        tracker.wentBackground()            // t0+30: повторный сигнал фона момент не сдвигает
        clock.advance(10)
        XCTAssertTrue(tracker.cameForeground(), "t0+40: 40 с в фоне от первого ухода — новая сессия")
        // Новый эпизод начинается с чистой отметки.
        tracker.wentBackground()
        clock.advance(5)
        XCTAssertFalse(tracker.cameForeground(), "новый эпизод: 5 с в фоне")
    }

    func testLaunchedClearsStaleBackgroundMark() {
        let clock = TestClock()
        let tracker = AppSessionTracker(clock: { clock.now })
        tracker.wentBackground()
        clock.advance(60)
        XCTAssertTrue(tracker.launched())
        XCTAssertFalse(tracker.cameForeground(), "открытие сняло отметку фона — устаревший уход не даёт сессию")
    }

    /// Событие переднего плана всегда решает отметку фона: если трекер не
    /// спросили (движок не инициализирован, нет канала), отметка снимается.
    func testForegroundWithoutConsultingTrackerDiscardsBackgroundMark() async {
        let clock = TestClock()
        let tracker = AppSessionTracker(clock: { clock.now })
        let http = FakeHttpEngine()
        http.stub(pathContains: "/api/v1/widget/config", json: String(data: Fixture.data("config"), encoding: .utf8)!)
        http.stub(pathContains: "/api/v1/widget/app-session", json: #"{"ok":true}"#)
        http.stub(pathContains: "/widget/surveys", json: #"{"surveys":[]}"#)
        let engine = RespondoEngine(
            secureStore: InMemorySecureStore(),
            prefs: InMemoryPreferences(),
            httpEngineFactory: { http },
            sessionTracker: tracker
        )
        engine.setPresenter(FakePresenter())
        engine.applicationStateProbe = { true }

        // До init: фон 60 с и возврат — движок не инициализирован, отметка снята.
        engine.applicationDidEnterBackground()
        clock.advance(60)
        engine.applicationWillEnterForeground()
        XCTAssertFalse(tracker.cameForeground(), "возврат до init снял отметку фона")

        // Снова фон до init, возврат до init, затем init и быстрый фон 5 с:
        // устаревший уход (первый момент эпизода) сессию не даёт.
        engine.applicationDidEnterBackground()
        clock.advance(120)
        engine.applicationWillEnterForeground()
        engine.initialize(config: RespondoConfig(agentId: agentId, channelId: "ch-1"), identity: nil)
        await waitUntil(timeout: 3) { http.requestSent(pathContains: "/widget/surveys") }
        await waitUntil { self.requests(http, "/api/v1/widget/app-session").count == 1 }
        engine.applicationDidEnterBackground()
        clock.advance(5)
        engine.applicationWillEnterForeground()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(requests(http, "/api/v1/widget/app-session").count, 1, "5 с в фоне после init — та же сессия")
        engine.destroy()

        // После destroy трекер не спрашивают: фон 60 с и возврат — отметка снята.
        engine.applicationDidEnterBackground()
        clock.advance(60)
        engine.applicationWillEnterForeground()
        XCTAssertFalse(tracker.cameForeground(), "возврат после destroy снял отметку фона")
    }

    /// Без канала отметок нет, и трекер не спрашивают — возврат отметку снимает.
    func testForegroundWithoutChannelDiscardsBackgroundMark() async {
        let clock = TestClock()
        let tracker = AppSessionTracker(clock: { clock.now })
        let http = FakeHttpEngine()
        http.stub(pathContains: "/api/v1/widget/config", json: String(data: Fixture.data("config"), encoding: .utf8)!)
        http.stub(pathContains: "/widget/surveys", json: #"{"surveys":[]}"#)
        let engine = RespondoEngine(
            secureStore: InMemorySecureStore(),
            prefs: InMemoryPreferences(),
            httpEngineFactory: { http },
            sessionTracker: tracker
        )
        engine.setPresenter(FakePresenter())
        engine.applicationStateProbe = { true }
        engine.initialize(config: RespondoConfig(agentId: agentId), identity: nil)
        await waitUntil(timeout: 3) { http.requestSent(pathContains: "/widget/surveys") }
        engine.applicationDidEnterBackground()
        clock.advance(60)
        engine.applicationWillEnterForeground()
        XCTAssertFalse(tracker.cameForeground(), "без канала возврат снял отметку фона")
        XCTAssertTrue(requests(http, "/api/v1/widget/app-session").isEmpty)
    }

    func testReinitDoesNotReportLaunchAgain() async {
        let clock = TestClock()
        let state = AppState()
        let http = FakeHttpEngine()
        http.stub(pathContains: "/api/v1/widget/config", json: String(data: Fixture.data("config"), encoding: .utf8)!)
        http.stub(pathContains: "/api/v1/widget/app-session", json: #"{"ok":true}"#)
        http.stub(pathContains: "/widget/surveys", json: #"{"surveys":[]}"#)
        let tracker = AppSessionTracker(clock: { clock.now })
        let engine = RespondoEngine(
            secureStore: InMemorySecureStore(),
            prefs: InMemoryPreferences(),
            httpEngineFactory: { http },
            sessionTracker: tracker
        )
        engine.setPresenter(FakePresenter())
        engine.applicationStateProbe = { state.foreground }
        let config = RespondoConfig(agentId: agentId, channelId: "ch-1")
        engine.initialize(config: config, identity: nil)
        await waitUntil { self.requests(http, "/api/v1/widget/app-session").count == 1 }
        // Хост пересоздал SDK (destroy + initialize) спустя минуту — не открытие приложения.
        clock.advance(60)
        engine.destroy()
        let catalogs = requests(http, "/widget/surveys").count
        engine.initialize(config: config, identity: nil)
        await waitUntil(timeout: 3) { self.requests(http, "/widget/surveys").count > catalogs }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(requests(http, "/api/v1/widget/app-session").count, 1, "re-init — запуск один раз на процесс")
    }

    func testBackgroundContactSwitchAfterLaunchUsesTheBackgroundRule() async {
        let clock = TestClock()
        let state = AppState()
        let (engine, http) = await makeEngine(clock: clock, state: state)
        await waitUntil { self.requests(http, "/api/v1/widget/app-session").count == 1 }
        // Ушли в фон; вход другого пользователя из фонового обработчика откладывается.
        engine.applicationDidEnterBackground()
        state.foreground = false
        engine.identify(RespondoIdentity(userId: "u-bg"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(requests(http, "/api/v1/widget/app-session").count, 1, "в фоне отметок нет")
        // Возврат через 5 с — запуск уже был, правило фона: та же сессия.
        clock.advance(5)
        state.foreground = true
        engine.applicationWillEnterForeground()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(requests(http, "/api/v1/widget/app-session").count, 1, "5 с в фоне — та же сессия")
        // Следующий эпизод: 25 с в фоне — новая сессия.
        engine.applicationDidEnterBackground()
        clock.advance(25)
        engine.applicationWillEnterForeground()
        await waitUntil { self.requests(http, "/api/v1/widget/app-session").count == 2 }
    }

    func testIdentifyFrameDeclaresAppSessions() throws {
        let data = RealtimeProtocol.identifyFrame(
            visitorId: "v_1", email: nil, userId: nil, channelId: "ch-1",
            sessionToken: nil, userHash: nil, lang: "en", conversationId: nil
        )
        let frame = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try XCTUnwrap(frame["features"] as? [String])
        XCTAssertTrue(features.contains("app_sessions"), "сервер не считает identify SDK активностью")
        XCTAssertTrue(features.contains("survey_targeting"))
    }

    func testChatIdentityCarriesLanguageOverride() {
        let identity = RespondoIdentity(properties: ["plan": "pro"], languageOverride: "pt-BR")
        let dto = ChatIdentityDTO(properties: identity.effectiveProperties)
        XCTAssertEqual(dto.properties?["language_override"], "pt-BR")
    }

    // MARK: - Холодный старт: стартовая личность и push до готовности

    /// Ворота ответа `/widget/identify`: ответ задерживается, пока тест их не откроет.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        func open() { lock.withLock { isOpen = true } }
        var opened: Bool { lock.withLock { isOpen } }
    }

    /// Движок, ещё не инициализированный, и транспорт, держащий ответ identify до `gate.open()`.
    private func coldEngine(gate: Gate, identifyStatus: Int = 200) -> (RespondoEngine, FakeHttpEngine) {
        let http = FakeHttpEngine()
        http.stub(pathContains: "/api/v1/widget/config", json: String(data: Fixture.data("config"), encoding: .utf8)!)
        http.stub(pathContains: "/api/v1/widget/identify", status: identifyStatus, json: #"{"ok":true}"#)
        http.stub(pathContains: "/api/v1/widget/app-session", json: #"{"ok":true}"#)
        http.stub(pathContains: "/api/v1/widget/push/", json: #"{"ok":true}"#)
        http.stub(pathContains: "/widget/surveys", json: #"{"surveys":[]}"#)
        http.beforeResponse = { request in
            guard request.url.absoluteString.contains("/api/v1/widget/identify") else { return }
            while !gate.opened { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        let clock = TestClock()
        let engine = RespondoEngine(
            secureStore: InMemorySecureStore(),
            prefs: InMemoryPreferences(),
            httpEngineFactory: { http },
            sessionTracker: AppSessionTracker(clock: { clock.now })
        )
        engine.setPresenter(FakePresenter())
        return (engine, http)
    }

    /// Тап холодного старта обработан раньше, чем пришёл токен, и оба — пока идёт init:
    /// бикон открытия уходит с токеном; регистрация токена и сессия запуска — после ответа identify.
    func testColdStartTapBeforeTokenReportsTheOpenWithTheToken() async {
        let gate = Gate()
        let (engine, http) = coldEngine(gate: gate)
        engine.initialize(config: RespondoConfig(agentId: agentId, channelId: "ch-1"),
                          identity: RespondoIdentity(userId: "u-1", userHash: "hash"))
        let tap = RespondoPushPayload(kind: .campaign, conversationId: nil, messageId: "m-1", deliveryId: "d-1",
                                      title: nil, body: nil, raw: [:])
        XCTAssertTrue(engine.handlePush(tap))
        engine.setPushToken("apns-token")

        await waitUntil(timeout: 3) { self.requests(http, "/api/v1/widget/push/opened").count == 1 }
        let opened = json(requests(http, "/api/v1/widget/push/opened")[0])
        XCTAssertEqual(opened["token"] as? String, "apns-token", "бикон открытия — с токеном, хотя регистрации ещё нет")
        XCTAssertEqual(opened["delivery_id"] as? String, "d-1")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(requests(http, "/api/v1/widget/push/register").isEmpty, "регистрация ждёт ответа identify")
        XCTAssertTrue(requests(http, "/api/v1/widget/app-session").isEmpty, "сессия запуска ждёт ответа identify")

        gate.open()
        await waitUntil { self.requests(http, "/api/v1/widget/push/register").count == 1 }
        await waitUntil { self.requests(http, "/api/v1/widget/app-session").count == 1 }
        let register = json(requests(http, "/api/v1/widget/push/register")[0])
        XCTAssertEqual(register["token"] as? String, "apns-token")
        XCTAssertEqual(register["user_id"] as? String, "u-1")
        let session = json(requests(http, "/api/v1/widget/app-session")[0])
        XCTAssertEqual(session["user_id"] as? String, "u-1", "сессия запуска — стартовой личности")
        XCTAssertEqual(requests(http, "/api/v1/widget/push/opened").count, 1, "бикон — один")
    }

    /// Сбой identify сессию запуска не держит: она уходит после ответа, каким бы он ни был.
    func testLaunchSessionGoesAfterAFailedIdentifyToo() async {
        let gate = Gate()
        let (engine, http) = coldEngine(gate: gate, identifyStatus: 500)
        engine.initialize(config: RespondoConfig(agentId: agentId, channelId: "ch-1"),
                          identity: RespondoIdentity(userId: "u-1"))
        await waitUntil(timeout: 3) { http.requestSent(pathContains: "/api/v1/widget/identify") }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(requests(http, "/api/v1/widget/app-session").isEmpty, "сессия запуска ждёт ответа identify")
        gate.open()
        await waitUntil { self.requests(http, "/api/v1/widget/app-session").count == 1 }
    }

    /// `setPushToken`, затем `clearPushToken` до готовности: токен не регистрируется и
    /// снимается на сервере.
    func testPushTokenClearedBeforeReadyIsUnregisteredNotRegistered() async {
        let gate = Gate()
        gate.open()
        let (engine, http) = coldEngine(gate: gate)
        engine.setPushToken("old-token")
        engine.clearPushToken()
        engine.initialize(config: RespondoConfig(agentId: agentId, channelId: "ch-1"), identity: nil)
        await waitUntil(timeout: 3) { self.requests(http, "/api/v1/widget/push/unregister").count == 1 }
        XCTAssertEqual(json(requests(http, "/api/v1/widget/push/unregister")[0])["token"] as? String, "old-token")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(requests(http, "/api/v1/widget/push/register").isEmpty)
    }

    /// Тап и токен до `initialize`: init их не стирает — бикон открытия уходит с токеном.
    func testTapAndTokenBeforeInitializeAreKept() async {
        let gate = Gate()
        gate.open()
        let (engine, http) = coldEngine(gate: gate)
        let tap = RespondoPushPayload(kind: .campaign, conversationId: nil, messageId: "m-0", deliveryId: "d-0",
                                      title: nil, body: nil, raw: [:])
        XCTAssertTrue(engine.handlePush(tap))
        engine.setPushToken("apns-token")
        engine.initialize(config: RespondoConfig(agentId: agentId, channelId: "ch-1"),
                          identity: RespondoIdentity(userId: "u-1", userHash: "hash"))
        await waitUntil(timeout: 3) { self.requests(http, "/api/v1/widget/push/opened").count == 1 }
        let opened = json(requests(http, "/api/v1/widget/push/opened")[0])
        XCTAssertEqual(opened["token"] as? String, "apns-token")
        XCTAssertEqual(opened["delivery_id"] as? String, "d-0")
        await waitUntil { self.requests(http, "/api/v1/widget/push/register").count == 1 }
    }

    /// Тап после готовности, раньше `setPushToken` (`await initialize`, затем тап быстрее токена):
    /// бикон открытия ждёт токена и уходит с ним.
    func testTapAfterReadyBeforeTokenReportsTheOpenWhenTheTokenArrives() async {
        let (engine, http) = await makeEngine(identity: RespondoIdentity(userId: "u-1", userHash: "hash"))
        http.stub(pathContains: "/api/v1/widget/push/", json: #"{"ok":true}"#)
        let tap = RespondoPushPayload(kind: .campaign, conversationId: nil, messageId: "m-2", deliveryId: "d-2",
                                      title: nil, body: nil, raw: [:])
        XCTAssertTrue(engine.handlePush(tap))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(requests(http, "/api/v1/widget/push/opened").isEmpty, "токена ещё нет")

        engine.setPushToken("apns-token")
        await waitUntil { self.requests(http, "/api/v1/widget/push/opened").count == 1 }
        let opened = json(requests(http, "/api/v1/widget/push/opened")[0])
        XCTAssertEqual(opened["token"] as? String, "apns-token")
        XCTAssertEqual(opened["delivery_id"] as? String, "d-2")
    }

    /// identify в полёте и `setPushToken`: регистрацию просят оба после одного ответа — уходит одна.
    func testTokenWithIdentifyInFlightRegistersOnce() async {
        let gate = Gate()
        let (engine, http) = coldEngine(gate: gate)
        engine.initialize(config: RespondoConfig(agentId: agentId, channelId: "ch-1"),
                          identity: RespondoIdentity(userId: "u-1", userHash: "hash"))
        engine.setPushToken("apns-token")
        await waitUntil(timeout: 3) { http.requestSent(pathContains: "/widget/surveys") }
        gate.open()
        await waitUntil { self.requests(http, "/api/v1/widget/push/register").count == 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(requests(http, "/api/v1/widget/push/register").count, 1, "то же тело второй раз не уходит")
    }

    /// identify(A), затем identify(B), ответ A — раньше: перерегистрация токена ждёт и ответа B,
    /// иначе она создавала контакт B по user_id без email.
    func testReRegistrationAfterIdentifyWaitsForLaterIdentifies() async {
        let (engine, http) = await makeEngine()
        http.stub(pathContains: "/api/v1/widget/push/", json: #"{"ok":true}"#)
        engine.setPushToken("apns-token")
        await waitUntil { self.requests(http, "/api/v1/widget/push/register").count == 1 }

        let gateA = Gate()
        let gateB = Gate()
        http.beforeResponse = { request in
            guard request.url.absoluteString.contains("/api/v1/widget/identify") else { return }
            let body = request.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let gate = body.contains("user-b") ? gateB : gateA
            while !gate.opened { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        engine.identify(RespondoIdentity(userId: "user-a", userHash: "hash-a"))
        engine.identify(RespondoIdentity(userId: "user-b", userHash: "hash-b"))
        await waitUntil { self.requests(http, "/api/v1/widget/identify").count == 2 }
        gateA.open()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(requests(http, "/api/v1/widget/push/register").count, 1,
                       "identify user-b ещё в полёте — регистрации нет")

        gateB.open()
        await waitUntil { self.requests(http, "/api/v1/widget/push/register").count == 2 }
        XCTAssertEqual(json(requests(http, "/api/v1/widget/push/register")[1])["user_id"] as? String, "user-b")
    }

    /// `track()` при identify в полёте: событие уходит после его ответа, с личностью вызова.
    func testTrackWaitsForTheIdentifyInFlight() async {
        let gate = Gate()
        let (engine, http) = coldEngine(gate: gate)
        engine.initialize(config: RespondoConfig(agentId: agentId, channelId: "ch-1"),
                          identity: RespondoIdentity(userId: "u-1", userHash: "hash"))
        engine.track("checkout_opened", properties: [:])
        await waitUntil(timeout: 3) { http.requestSent(pathContains: "/widget/surveys") }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(requests(http, "/api/v1/widget/events").isEmpty, "событие ждёт ответа identify")

        gate.open()
        await waitUntil { self.requests(http, "/api/v1/widget/events").count == 1 }
        XCTAssertEqual(json(requests(http, "/api/v1/widget/events")[0])["user_id"] as? String, "u-1")
    }

    /// Тап и токен до `initialize`, затем `initialize` поверх ещё не завершённого: вызовы до них
    /// не стираются — бикон открытия уходит с токеном.
    func testInitializeOverAnUnfinishedInitializeKeepsTheTapAndTheToken() async {
        let gate = Gate()
        gate.open()
        let (engine, http) = coldEngine(gate: gate)
        let tap = RespondoPushPayload(kind: .campaign, conversationId: nil, messageId: "m-3", deliveryId: "d-3",
                                      title: nil, body: nil, raw: [:])
        XCTAssertTrue(engine.handlePush(tap))
        engine.setPushToken("apns-token")
        engine.initialize(config: RespondoConfig(agentId: agentId, channelId: "ch-1"), identity: nil)
        engine.initialize(config: RespondoConfig(agentId: agentId, channelId: "ch-1"),
                          identity: RespondoIdentity(userId: "u-1", userHash: "hash"))
        await waitUntil(timeout: 3) { self.requests(http, "/api/v1/widget/push/opened").count == 1 }
        let opened = json(requests(http, "/api/v1/widget/push/opened")[0])
        XCTAssertEqual(opened["token"] as? String, "apns-token")
        XCTAssertEqual(opened["delivery_id"] as? String, "d-3")
        await waitUntil { self.requests(http, "/api/v1/widget/push/register").count == 1 }
        XCTAssertEqual(json(requests(http, "/api/v1/widget/push/register")[0])["user_id"] as? String, "u-1")
    }
}
