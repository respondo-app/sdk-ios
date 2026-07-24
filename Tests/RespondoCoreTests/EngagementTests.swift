import XCTest
@testable import RespondoCore

@MainActor
final class EngagementTests: XCTestCase {
    // MARK: - Декодинг + маппинг каталогов из фикстур

    func testSurveyCatalogDecodesAndMaps() {
        let dto = Fixture.decode(SurveysCatalogResponseDTO.self, "surveys-list")
        let survey = EngagementMapper.toSurvey(dto.surveys![0])
        XCTAssertEqual(survey.format, .inModal)
        XCTAssertEqual(survey.questions.count, 3)
        XCTAssertEqual(survey.questions.first?.type, .csat)
        XCTAssertTrue(survey.questions.first?.required == true)
        XCTAssertEqual(survey.steps.count, 3) // по умолчанию — один вопрос на шаг
        XCTAssertEqual(survey.sender?.name, "Анна")
    }

    func testBannerCatalogDecodesAndMaps() {
        let dto = Fixture.decode(BannersCatalogResponseDTO.self, "banners-list")
        let banner = EngagementMapper.toBanner(dto.banners![0])
        XCTAssertEqual(banner.action, .url)
        XCTAssertEqual(banner.position, .bottom)
        XCTAssertEqual(banner.layout, .floating)
        XCTAssertEqual(banner.url?.absoluteString, "https://respondo.ai/pricing")
        XCTAssertEqual(banner.linkLabel, "Смотреть тарифы")
        XCTAssertEqual(banner.backgroundHex, "#F5F3FF")
        XCTAssertTrue(banner.openNewTab)
    }

    func testNewsDecodesAndMaps() {
        let dto = Fixture.decode(NewsListResponseDTO.self, "news-list")
        XCTAssertEqual(dto.unread, 1)
        let first = EngagementMapper.toNews(dto.items![0])
        XCTAssertFalse(first.seen)
        XCTAssertEqual(first.labels, ["Новое", "Mobile"])
        XCTAssertNotNil(first.imageURL)
        let second = EngagementMapper.toNews(dto.items![1])
        XCTAssertTrue(second.seen)
        XCTAssertNil(second.imageURL) // пустая строка → nil
    }

    func testChecklistDecodesAndMaps() {
        let dto = Fixture.decode(ChecklistsCatalogResponseDTO.self, "checklists-list")
        let checklist = EngagementMapper.toChecklist(dto.checklists![0])
        XCTAssertEqual(checklist.tasks.count, 2)
        XCTAssertTrue(checklist.doneTaskIds.contains("task-connect-inbox"))
        // первая задача — url, вторая — manual
        if case .url(let url, _) = checklist.tasks[0].action {
            XCTAssertEqual(url.absoluteString, "https://app.respondo.ai/channels")
        } else { XCTFail("ожидался url-экшен") }
        if case .manual = checklist.tasks[1].action {} else { XCTFail("ожидался manual-экшен") }
        XCTAssertEqual(checklist.progress.done, 1)
        XCTAssertEqual(checklist.progress.total, 2)
    }

    func testTourTasksHidden() {
        let checklist = RespondoChecklist(
            id: "c1", title: "t", body: nil, dismissible: true,
            tasks: [
                RespondoChecklistTask(id: "a", title: "A", body: nil, action: .manual),
                RespondoChecklistTask(id: "b", title: "B", body: nil, action: .tour(tourId: "tour-1")),
            ],
            status: "started", doneTaskIds: []
        )
        XCTAssertEqual(checklist.visibleTasks.count, 1)
        XCTAssertEqual(checklist.visibleTasks.first?.id, "a")
        XCTAssertEqual(checklist.progress.total, 1) // tour не считается
    }

    // MARK: - Каталоги + арбитр

    func testLoadCatalogsPicksSurvey() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/widget/surveys", json: String(data: Fixture.data("surveys-list"), encoding: .utf8)!)
        engine.stub(pathContains: "/widget/banners", json: String(data: Fixture.data("banners-list"), encoding: .utf8)!)
        let env = makeEngagement(engine: engine)
        let engagement = env.controller
        engagement.loadCatalogs()
        await waitUntil { engagement.activeSurvey != nil }
        XCTAssertNotNil(engagement.activeSurvey, "арбитр выбрал опрос поверх баннера")
    }

    // MARK: - Survey flow

    func testSurveyFlowAnswerAdvanceSubmit() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/widget/surveys", json: String(data: Fixture.data("surveys-list"), encoding: .utf8)!)
        let env = makeEngagement(engine: engine)
        let engagement = env.controller
        engagement.loadCatalogs()
        await waitUntil { engagement.activeSurvey != nil }
        let survey = engagement.activeSurvey!

        // Шаг 1 — csat обязателен: до ответа продвижение заблокировано.
        XCTAssertFalse(engagement.canAdvance(survey))
        engagement.answerQuestion(survey, questionId: "q_csat", answer: .number(5))
        XCTAssertTrue(engagement.canAdvance(survey))
        engagement.advanceSurvey(survey)
        XCTAssertEqual(engagement.surveyStepIndex, 1)

        // Шаг 2 и 3 — необязательные.
        engagement.advanceSurvey(survey)
        XCTAssertEqual(engagement.surveyStepIndex, 2)
        engagement.advanceSurvey(survey)
        XCTAssertTrue(engagement.surveyFinished)
        await waitUntil { engine.requestSent(pathContains: "/widget/survey/submit") }
        XCTAssertTrue(engine.requestSent(pathContains: "/widget/survey/answer"))
    }

    func testDismissSurveyClearsOverlay() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/widget/surveys", json: String(data: Fixture.data("surveys-list"), encoding: .utf8)!)
        let env = makeEngagement(engine: engine)
        let engagement = env.controller
        engagement.loadCatalogs()
        await waitUntil { engagement.activeSurvey != nil }
        engagement.dismissSurvey(engagement.activeSurvey!.deliveryId)
        XCTAssertNil(engagement.activeSurvey)
        XCTAssertEqual(engagement.activeOverlay, .none)
    }

    // MARK: - Checklists

    func testChecklistUrlTaskOpensAndCompletes() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/widget/checklists", json: String(data: Fixture.data("checklists-list"), encoding: .utf8)!)
        let env = makeEngagement(engine: engine)
        let engagement = env.controller
        let host = env.host
        engagement.loadChecklists()
        await waitUntil { !engagement.checklists.isEmpty }
        let checklist = engagement.checklists[0]
        engagement.performTask(checklistId: checklist.id, taskId: "task-invite-team") // manual → done
        XCTAssertTrue(engagement.checklists[0].doneTaskIds.contains("task-invite-team"))

        engagement.performTask(checklistId: checklist.id, taskId: "task-connect-inbox") // url
        XCTAssertEqual(host.openedURLs.last?.absoluteString, "https://app.respondo.ai/channels")
        await waitUntil { engine.requestSent(pathContains: "/progress") }
    }

    func testChecklistDismiss() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/widget/checklists", json: String(data: Fixture.data("checklists-list"), encoding: .utf8)!)
        let env = makeEngagement(engine: engine)
        let engagement = env.controller
        engagement.loadChecklists()
        await waitUntil { !engagement.checklists.isEmpty }
        let id = engagement.checklists[0].id
        engagement.dismissChecklist(id)
        XCTAssertTrue(engagement.checklists.isEmpty)
    }

    // MARK: - News

    func testNewsMarkSeenDecrementsUnread() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/widget/news", json: String(data: Fixture.data("news-list"), encoding: .utf8)!)
        let env = makeEngagement(engine: engine)
        let engagement = env.controller
        engagement.loadNews()
        await waitUntil { !engagement.news.isEmpty }
        XCTAssertEqual(engagement.newsUnread, 1)
        let unseen = engagement.news.first { !$0.seen }!
        engagement.markNewsSeen(unseen.id)
        XCTAssertEqual(engagement.newsUnread, 0)
        XCTAssertTrue(engagement.news.first { $0.id == unseen.id }!.seen)
        await waitUntil { engine.requestSent(pathContains: "/seen") }
    }

    // MARK: - Proactive

    func testProactiveDeliversAndConsumes() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/widget/proactive", json: #"{"message":"Need a hand?","page_path":"home"}"#)
        let env = makeEngagement(engine: engine)
        let engagement = env.controller
        let host = env.host
        host.chatOpen = false
        var received: RespondoProactiveMessage?
        engagement.onProactive = { received = $0 }
        engagement.scheduleProactive(delay: 0)
        await waitUntil { received != nil }
        XCTAssertEqual(received?.text, "Need a hand?")
        XCTAssertEqual(engagement.consumeProactive()?.text, "Need a hand?")
        XCTAssertNil(engagement.consumeProactive()) // забирается один раз
    }

    func testProactiveSkippedWhenChatOpen() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/widget/proactive", json: #"{"message":"Hi"}"#)
        let env = makeEngagement(engine: engine)
        let engagement = env.controller
        let host = env.host
        host.chatOpen = true
        var received: RespondoProactiveMessage?
        engagement.onProactive = { received = $0 }
        engagement.scheduleProactive(delay: 0)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(received, "при открытом чате проактив не показывается")
    }

    /// P3-1: при уже активной беседе проактив не запрашивается и не показывается (веб-паритет).
    func testProactiveSkippedWhenConversationActive() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/widget/proactive", json: #"{"message":"Hi"}"#)
        let env = makeEngagement(engine: engine)
        let engagement = env.controller
        let host = env.host
        host.chatOpen = false
        host.params.conversationId = "c0ffee00-0000-4000-8000-000000000009"
        var received: RespondoProactiveMessage?
        engagement.onProactive = { received = $0 }
        engagement.scheduleProactive(delay: 0)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(received, "при активной беседе проактив не показывается")
        XCTAssertFalse(engine.requestSent(pathContains: "/widget/proactive"), "запрос проактива не отправлен")
    }

    // MARK: - overlay.show

    func testApplyOverlayItemsMergesSurvey() {
        let engagement = makeEngagement().controller
        let surveysJSON = try! JSONSerialization.jsonObject(with: Fixture.data("surveys-list")) as! [String: Any]
        let surveyItem = JSONValue.from((surveysJSON["surveys"] as! [Any])[0])
        engagement.applyOverlayItems([surveyItem])
        XCTAssertNotNil(engagement.activeSurvey)
        XCTAssertEqual(engagement.activeSurvey?.questions.first?.type, .csat)
    }
}
