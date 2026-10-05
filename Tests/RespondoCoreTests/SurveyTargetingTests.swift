import XCTest
@testable import RespondoCore

/// «Когда и где» оверлей-опросов в приложении: чистая часть и поведение контроллера.
@MainActor
final class SurveyTargetingTests: XCTestCase {
    private let campaignId = "5e1f3a7b-9c2d-4e8f-a0b1-c2d3e4f5a6b7"

    // MARK: - Чистая часть

    func testScreenRulesMatchByAnyAndExclusionsAlwaysHold() {
        let rules = [
            RespondoScreenRule(op: "starts_with", value: "Checkout"),
            RespondoScreenRule(op: "exact", value: "Cart"),
            RespondoScreenRule(op: "not_contains", value: "Error"),
        ]
        XCTAssertTrue(SurveyTargeting.screenMatches(rules, screen: "CheckoutPayment"))
        XCTAssertTrue(SurveyTargeting.screenMatches(rules, screen: "Cart"))
        XCTAssertFalse(SurveyTargeting.screenMatches(rules, screen: "CheckoutError"))
        XCTAssertFalse(SurveyTargeting.screenMatches(rules, screen: "Home"))
        XCTAssertFalse(SurveyTargeting.screenMatches(rules, screen: nil), "экран не задан — правилам не подходит")
        XCTAssertTrue(SurveyTargeting.screenMatches([], screen: nil), "нет правил — любой экран")
    }

    func testEventNameCanonMatchesBackend() {
        XCTAssertEqual(SurveyTargeting.normalizeEventName("  Order   Placed "), "order_placed")
        XCTAssertEqual(SurveyTargeting.clampDelay(-5), 0)
        XCTAssertEqual(SurveyTargeting.clampDelay(9999), 600)
    }

    func testReadinessWaitsForEventThenDelay() {
        let since = Date(timeIntervalSince1970: 1_000)
        let targeting = RespondoSurveyTargeting(delaySeconds: 10, triggerEvent: "order_placed")
        XCTAssertEqual(
            SurveyTargeting.readiness(targeting, screen: "Home", screenSince: since, events: [:], now: since + 60),
            .event
        )
        let fired = since + 30
        XCTAssertEqual(
            SurveyTargeting.readiness(targeting, screen: "Home", screenSince: since,
                                      events: ["order_placed": fired], now: fired + 4),
            .delay(seconds: 6), "задержка считается от события"
        )
        XCTAssertEqual(
            SurveyTargeting.readiness(targeting, screen: "Home", screenSince: since,
                                      events: ["order_placed": fired], now: fired + 10),
            .ready
        )
        // Событие на прошлом экране: задержка считается от прихода на этот.
        let arrived = fired + 100
        XCTAssertEqual(
            SurveyTargeting.readiness(targeting, screen: "Home", screenSince: arrived,
                                      events: ["order_placed": fired], now: arrived + 4),
            .delay(seconds: 6)
        )
    }

    func testResumedSurveyOpensAnywhereButNeverOffItsPlatform() {
        let since = Date(timeIntervalSince1970: 1_000)
        let targeting = RespondoSurveyTargeting(
            screenRules: [RespondoScreenRule(op: "exact", value: "Checkout")], delaySeconds: 30, triggerEvent: "x"
        )
        XCTAssertEqual(
            SurveyTargeting.readiness(targeting, screen: "Home", screenSince: since, events: [:], now: since),
            .elsewhere
        )
        XCTAssertEqual(
            SurveyTargeting.readiness(targeting, screen: "Home", screenSince: since, events: [:], now: since, resumed: true),
            .ready, "доставка есть — опрос продолжается на любом экране"
        )
        let webOnly = RespondoSurveyTargeting(showsInApps: false)
        XCTAssertEqual(
            SurveyTargeting.readiness(webOnly, screen: "Home", screenSince: since, events: [:], now: since, resumed: true),
            .elsewhere
        )
    }

    func testEventsLiveForTheSession() {
        let now = Date(timeIntervalSince1970: 100_000)
        let fresh = SurveyTargeting.freshEvents([
            "a": now - 60,
            "stale": now - SurveyTargeting.eventTTL - 1,
            "future": now + 5,
        ], now: now)
        XCTAssertEqual(Array(fresh.keys), ["a"])
    }

    func testTargetedFixtureMapsScreenRulesAndIgnoresUrlRules() {
        let dto = Fixture.decode(SurveysCatalogResponseDTO.self, "surveys-targeted")
        let survey = EngagementMapper.toSurvey(dto.surveys!.first!)
        XCTAssertEqual(survey.deliveryId, "")
        XCTAssertEqual(survey.targeting.screenRules.count, 2)
        XCTAssertEqual(survey.targeting.triggerEvent, "order_placed")
        // URL-правила веба SDK не читает: экран «Checkout» подходит, хоть адреса и нет.
        XCTAssertTrue(SurveyTargeting.screenMatches(survey.targeting.screenRules, screen: "Checkout"))
    }

    // MARK: - Контроллер

    private func targetedEnv() -> EngagementEnv {
        let engine = FakeHttpEngine()
        // Первое совпадение выигрывает: минт по survey_id — раньше каталога.
        engine.stub(pathContains: "survey_id=", json: String(data: Fixture.data("surveys-open"), encoding: .utf8)!)
        engine.stub(pathContains: "/widget/surveys", json: String(data: Fixture.data("surveys-targeted"), encoding: .utf8)!)
        return makeEngagement(engine: engine)
    }

    func testCatalogDeclaresFeatureAndPlatform() async {
        let env = targetedEnv()
        env.controller.loadCatalogs()
        await waitUntil { env.engine.requestSent(pathContains: "features=survey_targeting") }
        XCTAssertTrue(env.engine.requestSent(pathContains: "platform=app"))
    }

    func testIdentifyFrameDeclaresPlatform() throws {
        let data = RealtimeProtocol.identifyFrame(
            visitorId: "v", email: nil, userId: nil, channelId: nil, sessionToken: nil,
            userHash: nil, lang: nil, conversationId: nil
        )
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(frame["platform"] as? String, "app")
        XCTAssertEqual(frame["features"] as? [String], ["survey_targeting"])
    }

    func testOpenedSurveyResumesOnAnyScreenAfterRelaunch() async {
        // Каталог после перезапуска: доставка уже есть (опрос открывали), экран чужой.
        let engine = FakeHttpEngine()
        let opened = String(data: Fixture.data("surveys-targeted"), encoding: .utf8)!
            .replacingOccurrences(of: "\"delivery_id\": \"\"", with: "\"delivery_id\": \"6f2a4b8c-0d3e-4f9a-b1c2-d3e4f5a6b7c8\"")
        engine.stub(pathContains: "/widget/surveys", json: opened)
        let env = makeEngagement(engine: engine)
        env.host.screen = "Settings"
        env.controller.loadCatalogs()
        await waitUntil { env.controller.activeSurvey != nil }
        XCTAssertEqual(env.controller.activeSurvey?.deliveryId, "6f2a4b8c-0d3e-4f9a-b1c2-d3e4f5a6b7c8")
        XCTAssertFalse(env.engine.requestSent(pathContains: "survey_id="), "доставка уже есть — минт не нужен")
    }

    func testTargetedSurveyOpensOnlyOnMatchingScreenAfterEvent() async {
        let env = targetedEnv()
        env.host.screen = "Home"
        env.controller.loadCatalogs()
        await waitUntil { env.engine.requestSent(pathContains: "/widget/surveys") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        env.host.screen = "Checkout"
        env.controller.screenDidChange()
        XCTAssertNil(env.controller.activeSurvey, "нужный экран, но события ещё не было")

        env.host.screen = "Home"
        env.controller.screenDidChange()
        env.controller.eventTracked("Order placed")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(env.controller.activeSurvey, "не тот экран — событие опрос не открывает")
        XCTAssertFalse(env.engine.requestSent(pathContains: "survey_id="))

        // Событие пережило смену экрана: track перед переходом на экран опроса.
        env.host.screen = "Checkout"
        env.controller.screenDidChange()
        await waitUntil { env.controller.activeSurvey != nil }
        XCTAssertEqual(env.controller.activeSurvey?.deliveryId, "6f2a4b8c-0d3e-4f9a-b1c2-d3e4f5a6b7c8")
        XCTAssertFalse(env.engine.requestSent(pathContains: "source=api"))

        // Начатый опрос следует за посетителем на другой экран.
        env.host.screen = "Home"
        env.controller.screenDidChange()
        XCTAssertNotNil(env.controller.activeSurvey)

        // Повторная загрузка каталога (без доставки) не затирает открытый опрос.
        env.controller.loadCatalogs()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(env.controller.activeSurvey?.deliveryId, "6f2a4b8c-0d3e-4f9a-b1c2-d3e4f5a6b7c8")
    }

    /// Событие сессии на экране без опроса, затем смена контакта, каталог нового
    /// контакта и экран опроса: открылся ли опрос.
    private func eventSurvivesIdentityChange(fromAnonymous: Bool) async -> (opened: Bool, minted: Bool) {
        let env = targetedEnv()
        env.host.screen = "Home"
        env.controller.loadCatalogs()
        await waitUntil { env.engine.requestSent(pathContains: "/widget/surveys") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        env.controller.eventTracked("Order placed")
        env.controller.identityChanged(fromAnonymous: fromAnonymous)
        env.controller.loadCatalogs()
        try? await Task.sleep(nanoseconds: 150_000_000)
        env.host.screen = "Checkout"
        env.controller.screenDidChange()
        try? await Task.sleep(nanoseconds: 200_000_000)
        return (env.controller.activeSurvey != nil, env.engine.requestSent(pathContains: "survey_id="))
    }

    func testAnotherUsersTrackedEventDoesNotOpenSurvey() async {
        let result = await eventSurvivesIdentityChange(fromAnonymous: false)
        XCTAssertFalse(result.opened, "track() пользователя A не открывает опрос пользователю B")
        XCTAssertFalse(result.minted)
    }

    func testAnonymousToIdentifiedKeepsSessionEvents() async {
        let result = await eventSurvivesIdentityChange(fromAnonymous: true)
        XCTAssertTrue(result.opened, "аноним → пользователь — тот же человек, событие остаётся")
    }

    func testStartSurveyOpensExplicitlyAnywhere() async {
        let env = targetedEnv()
        env.host.screen = "Settings"
        env.controller.startSurvey(campaignId)
        await waitUntil { env.controller.activeSurvey != nil }
        XCTAssertTrue(env.engine.requestSent(pathContains: "source=api"))
        XCTAssertEqual(env.controller.activeSurvey?.campaignId, campaignId)
    }

    func testDismissedSurveyStaysClosedAfterRelaunch() async {
        // Опрос с доставкой нацелен на «Checkout»; посетитель закрыл его,
        // приложение перезапущено на чужом экране — опрос не возвращается.
        let delivery = "6f2a4b8c-0d3e-4f9a-b1c2-d3e4f5a6b7c8"
        let opened = String(data: Fixture.data("surveys-targeted"), encoding: .utf8)!
            .replacingOccurrences(of: "\"delivery_id\": \"\"", with: "\"delivery_id\": \"\(delivery)\"")
        let prefs = InMemoryPreferences()
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "survey_id=", json: String(data: Fixture.data("surveys-open"), encoding: .utf8)!)
        engine.stub(pathContains: "/widget/surveys", json: opened)

        let first = makeEngagement(engine: engine, prefs: prefs)
        first.host.screen = "Settings"
        first.controller.loadCatalogs()
        await waitUntil { first.controller.activeSurvey != nil }
        first.controller.dismissSurvey(delivery)
        XCTAssertNil(first.controller.activeSurvey)

        let relaunched = makeEngagement(engine: engine, prefs: prefs)
        relaunched.host.screen = "Settings"
        relaunched.controller.loadCatalogs()
        await waitUntil { relaunched.engine.sentRequests.count >= 4 }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(relaunched.controller.activeSurvey, "закрытый опрос не возвращается после перезапуска")

        // Явный startSurvey показывает его снова и снимает отметку.
        relaunched.controller.startSurvey(campaignId)
        await waitUntil { relaunched.controller.activeSurvey != nil }
        XCTAssertEqual(relaunched.controller.activeSurvey?.deliveryId, delivery)
    }

    func testClearDuringOpenDropsThePreviousContactsSurvey() async {
        // Минт доставки ещё идёт, когда host вызывает reset(): запрос отменён,
        // опрос прежнего контакта новому не достаётся.
        let slow = targetedEnv()
        slow.engine.responseDelay = 0.1
        slow.host.screen = "Settings"
        slow.controller.startSurvey(campaignId)
        slow.controller.clear()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(slow.controller.activeSurvey)

        // Ответ уже получен, и reset() успевает до его обработки: отмена тут
        // ничего не меняет, ответ отбрасывает поколение.
        let racing = targetedEnv()
        racing.host.screen = "Settings"
        let controller = racing.controller
        racing.engine.beforeResponse = { request in
            guard request.url.absoluteString.contains("survey_id=") else { return }
            await MainActor.run { controller.clear() }
        }
        racing.controller.startSurvey(campaignId)
        await waitUntil { racing.engine.requestSent(pathContains: "survey_id=") }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(racing.controller.activeSurvey, "ответ прежнего контакта отброшен по поколению")
    }

    func testPlatformIsReadCaseAndWhitespaceInsensitively() throws {
        func mapped(_ platform: String) throws -> Bool {
            let json = """
            {"surveys":[{"campaign_id":"c","delivery_id":"","content":{"survey_format":"in_modal",
            "survey_platform":"\(platform)","questions":[]}}]}
            """
            let dto = try JSONDecoder().decode(SurveysCatalogResponseDTO.self, from: Data(json.utf8))
            return EngagementMapper.toSurvey(try XCTUnwrap(dto.surveys?.first)).targeting.showsInApps
        }
        XCTAssertFalse(try mapped("web"))
        XCTAssertFalse(try mapped(" WEB "))
        XCTAssertFalse(try mapped("Web"))
        XCTAssertTrue(try mapped("apps"))
        XCTAssertTrue(try mapped(""))
        XCTAssertTrue(SurveyTargeting.showsInApps(nil))
    }

    func testContactKeyIsUserIdAndEmailOnly() {
        let a = RespondoIdentity(userId: "u1", email: "A@x.io", name: "A")
        var same = a
        same.email = " a@x.io "; same.name = "B"; same.userHash = "h"
        XCTAssertEqual(a.contactKey, same.contactKey)
        var other = a
        other.email = "b@x.io"
        XCTAssertNotEqual(a.contactKey, other.contactKey)
        XCTAssertNotEqual(RespondoIdentity().contactKey, a.contactKey)
    }

    func testIdentityChangeWhileOpenInFlightLeavesNoPreviousDelivery() async {
        // identify(B), пока минт доставки контакта A ещё идёт: доставка A не достаётся B.
        let racing = targetedEnv()
        racing.host.screen = "Settings"
        let controller = racing.controller
        racing.engine.beforeResponse = { request in
            guard request.url.absoluteString.contains("survey_id=") else { return }
            await MainActor.run { controller.identityChanged(fromAnonymous: false) }
        }
        racing.controller.startSurvey(campaignId)
        await waitUntil { racing.engine.requestSent(pathContains: "survey_id=") }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(racing.controller.activeSurvey, "минт контакта A отброшен")

        // Каталог B без доставки: открытая доставка A не подмешивается по campaign_id.
        racing.engine.beforeResponse = nil
        racing.controller.loadCatalogs()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(racing.controller.activeSurvey)
    }

    func testIdentityChangeDropsOpenedDeliveryAndStaleCatalogue() async {
        // Опрос A открыт — identify(B) его снимает, и каталог без доставки его не возвращает.
        let env = targetedEnv()
        env.host.screen = "Settings"
        env.controller.startSurvey(campaignId)
        await waitUntil { env.controller.activeSurvey != nil }
        env.controller.identityChanged(fromAnonymous: false)
        XCTAssertNil(env.controller.activeSurvey)
        env.controller.loadCatalogs()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(env.controller.activeSurvey, "каталог без доставки не наследует доставку A")

        // Каталог A (с доставкой) получен, и identify(B) успевает до его обработки: отброшен.
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/widget/surveys", json: String(data: Fixture.data("surveys-open"), encoding: .utf8)!)
        let stale = makeEngagement(engine: engine)
        stale.host.screen = "Settings"
        let controller = stale.controller
        engine.beforeResponse = { request in
            guard request.url.absoluteString.contains("/widget/surveys") else { return }
            await MainActor.run { controller.identityChanged(fromAnonymous: false) }
        }
        stale.controller.loadCatalogs()
        await waitUntil { engine.requestSent(pathContains: "/widget/surveys") }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(stale.controller.activeSurvey, "каталог контакта A, пришедший последним, отброшен")
    }
}
