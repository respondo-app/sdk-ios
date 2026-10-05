import XCTest
@testable import RespondoCore

/// Публичный путь `identify()` (RespondoEngine.identify → EngagementController.identityChanged):
/// другой email/userId снимает опрос прежнего контакта, имя и userHash — нет (api-surface.md §3.3).
@MainActor
final class IdentifySurveyTests: XCTestCase {
    private let campaignId = "5e1f3a7b-9c2d-4e8f-a0b1-c2d3e4f5a6b7"
    private let agentId = "7d3f9c2a-1e4b-4a6d-9f21-8c5b0e7a4d10"

    final class FakePresenter: ChatPresenter {
        func present(surface: ChatSurface) {}
        func dismiss() {}
        var isPresented: Bool { false }
    }

    /// Минт отдаёт доставку A; каталог — её же для A и пустой для B (первое совпадение выигрывает).
    private func makeEngine(identity: RespondoIdentity) async -> (RespondoEngine, FakeHttpEngine) {
        let open = String(data: Fixture.data("surveys-open"), encoding: .utf8)!
        let http = FakeHttpEngine()
        http.stub(pathContains: "/api/v1/widget/config", json: String(data: Fixture.data("config"), encoding: .utf8)!)
        http.stub(pathContains: "survey_id=", json: open)
        http.stub(pathContains: "email=b", json: #"{"surveys":[]}"#)
        http.stub(pathContains: "user_id=u-b", json: #"{"surveys":[]}"#)
        http.stub(pathContains: "/widget/surveys", json: open)
        let engine = RespondoEngine(secureStore: InMemorySecureStore(), prefs: InMemoryPreferences(), httpEngineFactory: { http })
        engine.setPresenter(FakePresenter())
        engine.initialize(config: RespondoConfig(agentId: agentId), identity: identity)
        // identify() до конца init буферизуется. Первый каталог запрашивается
        // после `initialized = true` — по нему и видно, что init завершён.
        await waitUntil(timeout: 3) { engine.engagement != nil && http.requestSent(pathContains: "/widget/surveys") }
        return (engine, http)
    }

    private func openSurveyA(_ engine: RespondoEngine) async {
        engine.engagement?.startSurvey(campaignId)
        await waitUntil { engine.engagement?.activeSurvey != nil }
        XCTAssertEqual(engine.engagement?.activeSurvey?.campaignId, campaignId)
    }

    /// Каталог, запрошенный identify(), вернулся и применён.
    private func settleCatalogue(_ http: FakeHttpEngine, contains marker: String) async {
        await waitUntil { http.requestSent(pathContains: marker) }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    func testIdentifyOtherEmailDropsOpenedSurvey() async {
        let (engine, http) = await makeEngine(identity: RespondoIdentity(email: "a@x.io"))
        await openSurveyA(engine)
        engine.identify(RespondoIdentity(email: "b@x.io"))
        XCTAssertNil(engine.engagement?.activeSurvey, "опрос A снят сразу")
        await settleCatalogue(http, contains: "email=b")
        XCTAssertNil(engine.engagement?.activeSurvey, "каталог B не возвращает доставку A")
    }

    func testIdentifyOtherUserIdDropsOpenedSurvey() async {
        let (engine, _) = await makeEngine(identity: RespondoIdentity(userId: "u-a"))
        await openSurveyA(engine)
        engine.identify(RespondoIdentity(userId: "u-b"))
        XCTAssertNil(engine.engagement?.activeSurvey)
    }

    func testIdentifyAnonymousToUserDropsOpenedSurvey() async {
        let (engine, _) = await makeEngine(identity: RespondoIdentity())
        await openSurveyA(engine)
        engine.identify(RespondoIdentity(email: "b@x.io"))
        XCTAssertNil(engine.engagement?.activeSurvey)
    }

    func testIdentifyNameOrUserHashOnlyKeepsOpenedSurvey() async {
        let (engine, http) = await makeEngine(identity: RespondoIdentity(email: "a@x.io"))
        await openSurveyA(engine)
        let before = http.sentRequests.count
        engine.identify(RespondoIdentity(email: " A@x.io ", name: "Ann", userHash: "h"))
        XCTAssertEqual(engine.engagement?.activeSurvey?.campaignId, campaignId)
        await waitUntil { http.sentRequests.dropFirst(before).contains { $0.url.absoluteString.contains("/widget/surveys") } }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(engine.engagement?.activeSurvey?.campaignId, campaignId, "тот же контакт: опрос остаётся")
    }

    // MARK: - overlay.show со штампом контакта

    private func overlayFrame(identity: String?) -> String {
        let surveys = try! JSONSerialization.jsonObject(with: Fixture.data("surveys-list")) as! [String: Any]
        var data: [String: Any] = ["items": surveys["surveys"]!]
        if let identity { data["identity"] = ["user_id": "", "email": identity] }
        let frame = try! JSONSerialization.data(withJSONObject: ["type": "overlay.show", "data": data])
        return String(data: frame, encoding: .utf8)!
    }

    private func deliver(_ text: String, to engine: RespondoEngine) {
        guard case .overlayShow(let items, let contact)? = RealtimeProtocol.decode(text, subscribedConversationId: nil) else {
            return XCTFail("overlay.show не разобран")
        }
        engine.applyOverlayShow(items: items, contact: contact)
    }

    func testDecodeOverlayShowStamp() {
        guard case .overlayShow(_, let contact)? = RealtimeProtocol.decode(overlayFrame(identity: " A@X.io "), subscribedConversationId: nil) else {
            return XCTFail("overlay.show не разобран")
        }
        XCTAssertEqual(contact, RespondoIdentity(email: "a@x.io").contactKey)
        guard case .overlayShow(_, let none)? = RealtimeProtocol.decode(overlayFrame(identity: nil), subscribedConversationId: nil) else {
            return XCTFail("overlay.show не разобран")
        }
        XCTAssertNil(none)
    }

    /// Сокет переживает identify(): кадр A, пришедший после identify(B), до опросов B не доходит.
    func testStaleOverlayFrameOfPreviousContactIsDropped() async {
        let (engine, http) = await makeEngine(identity: RespondoIdentity(email: "a@x.io"))
        engine.identify(RespondoIdentity(email: "b@x.io"))
        await settleCatalogue(http, contains: "email=b")
        deliver(overlayFrame(identity: "a@x.io"), to: engine)
        XCTAssertNil(engine.engagement?.activeSurvey, "кадр A отброшен")
        deliver(overlayFrame(identity: nil), to: engine)
        XCTAssertNil(engine.engagement?.activeSurvey, "кадр без штампа отброшен")
        deliver(overlayFrame(identity: "B@x.io"), to: engine)
        XCTAssertNotNil(engine.engagement?.activeSurvey, "кадр текущего контакта применён")
    }
}
