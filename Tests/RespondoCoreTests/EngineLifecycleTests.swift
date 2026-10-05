import XCTest
@testable import RespondoCore

@MainActor
final class EngineLifecycleTests: XCTestCase {
    final class FakePresenter: ChatPresenter {
        var presented: [ChatSurface] = []
        var isPresented = false
        func present(surface: ChatSurface) { presented.append(surface); isPresented = true }
        func dismiss() { isPresented = false }
    }

    final class CountingDelegate: RespondoDelegate {
        var unhandledDeepLinks = 0
        func respondoUnhandledDeepLink(_ payload: RespondoPushPayload) { unhandledDeepLinks += 1 }
    }

    private func makeEngine() -> (RespondoEngine, FakeHttpEngine, FakePresenter) {
        let http = FakeHttpEngine()
        http.stub(pathContains: "/api/v1/widget/config", json: String(data: Fixture.data("config"), encoding: .utf8)!)
        http.stub(pathContains: "/api/v1/widget/events", json: #"{"ok":true}"#)
        let engine = RespondoEngine(secureStore: InMemorySecureStore(), prefs: InMemoryPreferences(), httpEngineFactory: { http })
        let presenter = FakePresenter()
        engine.setPresenter(presenter)
        return (engine, http, presenter)
    }

    func testCommandsBufferedBeforeInitAndReplayed() async throws {
        let (engine, http, presenter) = makeEngine()

        // Вызовы ДО init — буферизуются.
        engine.identify(RespondoIdentity(userId: "user-42"))
        engine.track("signup", properties: ["plan": "pro"])
        engine.open()

        XCTAssertEqual(engine.chatState, .closed, "до init open не выполняется немедленно")

        engine.initialize(config: RespondoConfig(agentId: "7d3f9c2a-1e4b-4a6d-9f21-8c5b0e7a4d10"), identity: nil)

        // Ждём проигрывания очереди после init.
        try await waitUntil { engine.chatState == .open }

        XCTAssertEqual(presenter.presented, [.thread], "буферизованный open проигран после init")
        XCTAssertTrue(http.requestSent(pathContains: "/api/v1/widget/events"), "буферизованный track отправлен после init")
    }

    func testNoRoutingIdentifierIsNoOp() {
        let (engine, _, _) = makeEngine()
        engine.initialize(config: RespondoConfig(agentId: "", channelId: nil), identity: nil)
        XCTAssertEqual(engine.chatState, .closed)
        XCTAssertEqual(engine.unreadCount, 0)
    }

    /// Push-кампания без беседы, но с диплинком: SDK сам открывает ссылку (как Intercom),
    /// делегат не дёргается; не открылась — respondoUnhandledDeepLink.
    func testCampaignPushOpensDeepLink() async throws {
        for accepted in [true, false] {
            let (engine, _, _) = makeEngine()
            let delegate = CountingDelegate()
            engine.delegate = delegate
            var opened: [String] = []
            engine.openDeepLink = { link in opened.append(link); return accepted }
            engine.initialize(config: RespondoConfig(agentId: "7d3f9c2a-1e4b-4a6d-9f21-8c5b0e7a4d10"), identity: nil)
            try await waitUntil { engine.controller != nil }

            let payload = RespondoPushPayload(kind: .message, conversationId: nil, messageId: "dl-\(accepted)", deepLink: "yourapp://orders/1", title: "t", body: "b", raw: [:])
            _ = engine.handlePush(payload)
            try await waitUntil { !opened.isEmpty }
            try await Task.sleep(nanoseconds: 50_000_000)

            XCTAssertEqual(opened, ["yourapp://orders/1"])
            XCTAssertEqual(delegate.unhandledDeepLinks, accepted ? 0 : 1)
        }
    }

    func testDeepLinkOpenerParsesAndMatchesUniversalLinkDomains() {
        XCTAssertNil(DeepLinkOpener.url(from: "  "))
        XCTAssertNil(DeepLinkOpener.url(from: "javascript:alert(1)"))
        XCTAssertNotNil(DeepLinkOpener.url(from: "yourapp://orders/1"))
        let url = DeepLinkOpener.url(from: "https://app.example.com/bots?id=1")!
        XCTAssertTrue(DeepLinkOpener.isUniversalLink(url, domains: ["*.example.com"]))
        XCTAssertTrue(DeepLinkOpener.isUniversalLink(url, domains: ["app.example.com"]))
        XCTAssertFalse(DeepLinkOpener.isUniversalLink(url, domains: ["example.com"]))
        XCTAssertFalse(DeepLinkOpener.isUniversalLink(DeepLinkOpener.url(from: "yourapp://app.example.com")!, domains: ["app.example.com"]))
    }

    func testHandlePushReturnsTrueSynchronouslyBeforeInit() {
        let (engine, _, _) = makeEngine()
        let payload = RespondoPushPayload(kind: .message, conversationId: "c", messageId: "m", title: "t", body: "b", raw: [:])
        XCTAssertTrue(engine.handlePush(payload), "handlePush решает «свой ли пуш» синхронно, даже до init")
    }

    /// P2-3: два одинаковых пуша (один message_id) до init на replay проходят дедуп
    /// markProcessed — делегат дёргается ровно один раз.
    func testPreInitDuplicatePushDedupedOnReplay() async throws {
        let (engine, _, _) = makeEngine()
        let delegate = CountingDelegate()
        engine.delegate = delegate
        // Пуш без conversationId → respondoUnhandledDeepLink; message_id одинаковый.
        let payload = RespondoPushPayload(kind: .message, conversationId: nil, messageId: "dup-1", title: "t", body: "b", raw: [:])
        _ = engine.handlePush(payload)
        _ = engine.handlePush(payload)

        engine.initialize(config: RespondoConfig(agentId: "7d3f9c2a-1e4b-4a6d-9f21-8c5b0e7a4d10"), identity: nil)
        try await waitUntil { engine.controller != nil }
        // Даём replayQueue проиграться.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(delegate.unhandledDeepLinks, 1, "дубликат пре-init пуша подавлен на replay через markProcessed")
    }

    /// P1-3: два перекрывающихся initialize оставляют один живой контроллер;
    /// устаревшее поколение инвалидируется и не пересоздаёт рантайм после пробуждения.
    func testConcurrentInitializeKeepsSingleGeneration() async throws {
        let http = FakeHttpEngine()
        http.stub(pathContains: "/api/v1/widget/config", json: String(data: Fixture.data("config"), encoding: .utf8)!)
        http.responseDelay = 0.2 // первый performInit зависает на await конфига
        let engine = RespondoEngine(secureStore: InMemorySecureStore(), prefs: InMemoryPreferences(), httpEngineFactory: { http })
        engine.setPresenter(FakePresenter())

        let genBefore = engine.initGeneration
        engine.initialize(config: RespondoConfig(agentId: "7d3f9c2a-1e4b-4a6d-9f21-8c5b0e7a4d10"), identity: nil) // gen A
        engine.initialize(config: RespondoConfig(agentId: "7d3f9c2a-1e4b-4a6d-9f21-8c5b0e7a4d10"), identity: nil) // teardown A + gen B

        try await waitUntil(timeout: 3) { engine.controller != nil }
        let live = engine.controller
        // Даём устаревшему поколению A проснуться после await и убедиться, что оно ничего не портит.
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertNotNil(engine.controller, "после перекрытия остаётся живой контроллер")
        XCTAssertTrue(engine.controller === live, "устаревшее поколение не пересоздало controller")
        XCTAssertGreaterThan(engine.initGeneration, genBefore + 1, "перекрывающийся init инвалидировал раннее поколение (bump в teardown + startInit)")
    }

    /// P2-3: reset() выполняет revoke-session и повторную инициализацию в отложенной
    /// Task. Если в этом окне вызван destroy(), поколение инвалидируется и reset НЕ
    /// воскрешает разобранный движок — controller остаётся nil.
    func testResetDoesNotResurrectAfterDestroy() async throws {
        let (engine, _, _) = makeEngine()
        engine.initialize(config: RespondoConfig(agentId: "7d3f9c2a-1e4b-4a6d-9f21-8c5b0e7a4d10"), identity: nil)
        try await waitUntil { engine.controller != nil }

        engine.reset()   // планирует revoke + teardown + startInit в отложенной Task
        engine.destroy() // бампит поколение, разбирает рантайм синхронно

        // Даём отложенной Task reset() проснуться и убедиться, что она ничего не воскрешает.
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertNil(engine.controller, "reset после destroy не воскрешает движок")
    }

    /// P2-2: lifecycle-хуки движка безопасны до init (no-op) и после init форвардят
    /// в реалтайм без крашей — прокидывание хука из UI-слоя.
    func testLifecycleHooksSafeBeforeAndAfterInit() async throws {
        let (engine, _, _) = makeEngine()
        // До init — тихий no-op (realtime ещё нет).
        engine.applicationDidEnterBackground()
        engine.applicationWillEnterForeground()

        engine.initialize(config: RespondoConfig(agentId: "7d3f9c2a-1e4b-4a6d-9f21-8c5b0e7a4d10"), identity: nil)
        try await waitUntil { engine.controller != nil }

        engine.applicationDidEnterBackground()
        engine.applicationWillEnterForeground()
        // Даём форвардящим Task отработать; движок остаётся живым.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(engine.controller, "после lifecycle-хуков движок жив")
    }

    func testOpenCloseTransitions() async throws {
        let (engine, _, presenter) = makeEngine()
        engine.initialize(config: RespondoConfig(agentId: "7d3f9c2a-1e4b-4a6d-9f21-8c5b0e7a4d10"), identity: nil)
        try await waitUntilInitialized(engine)
        engine.open()
        XCTAssertEqual(engine.chatState, .open)
        XCTAssertTrue(presenter.isPresented)
        engine.close()
        XCTAssertEqual(engine.chatState, .closed)
        XCTAssertFalse(presenter.isPresented)
    }

    private func waitUntilInitialized(_ engine: RespondoEngine) async throws {
        // Косвенно: после init controller != nil.
        try await waitUntil { engine.controller != nil }
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timeout"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
