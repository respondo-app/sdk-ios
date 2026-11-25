import XCTest
@testable import RespondoCore

/// Системные карточки на языке КЛИЕНТА: китайский клиент
/// английского приложения после китайского разговора получал карточки
/// «передано человеку», «вернулся к ИИ», «чат завершён» строками SDK на
/// UI-локали приложения. Сервер отдаёт их на языке клиента
/// (`handover_card_text`, `status_texts`, `message` ответа `/escalate`);
/// строки SDK — только фолбэк.
@MainActor
final class ServerTextsTests: XCTestCase {
    private let conv = "c0ffee00-1111-4222-8333-444455556666"
    private let zhCard = "您的请求已转交人工客服，请稍候。"
    private let zhBack = "对话已转回 AI 助手。有什么可以帮您？"
    private let zhEnded = "对话已结束。感谢您的咨询！"
    private let zhFailed = "暂时无法为您转接人工客服，请一分钟后再试。"

    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func chatJSON(handover: Bool = false, message: [String: Any]? = nil, card: String? = nil, statusTexts: [String: String]? = nil) -> String {
        var body: [String: Any] = ["conversation_id": conv, "session_token": "tok-1", "human_handover": handover]
        if let message { body["message"] = message }
        if let card { body["handover_card_text"] = card }
        if let statusTexts { body["status_texts"] = statusTexts }
        return json(body)
    }

    private func sdk(_ key: String) -> String { LocalizedStrings.shared.string(key, lang: "ru") }

    private func send(_ controller: ConversationController, _ text: String) async {
        controller.send(text: text)
        await waitUntil { !controller.isLoading }
    }

    func testDTOsDecodeServerTexts() throws {
        let chat = try JSONDecoder().decode(ChatResponseDTO.self, from: Data(chatJSON(
            handover: true, card: zhCard, statusTexts: ["back_to_ai": zhBack, "resolved": ""]).utf8))
        XCTAssertEqual(chat.handoverCardText, zhCard)
        XCTAssertEqual(chat.statusTexts?.backToAI, zhBack)
        let poll = try JSONDecoder().decode(WidgetMessagesResponseDTO.self, from: Data(json(
            ["status": "escalated", "status_texts": ["resolved": zhEnded]]).utf8))
        XCTAssertEqual(poll.statusTexts?.resolved, zhEnded)
        let legacy = try JSONDecoder().decode(ResumeResponseDTO.self, from: Data(#"{"status":"open"}"#.utf8))
        XCTAssertNil(legacy.statusTexts, "старый бэкенд без поля")

        // Пустое поле известный текст не затирает, новое — заменяет.
        let merged = StatusTexts(backToAI: zhBack, resolved: zhEnded)
            .merging(StatusTextsDTO(backToAI: "  ", resolved: "Gespräch beendet."))
        XCTAssertEqual(merged.backToAI, zhBack)
        XCTAssertEqual(merged.resolved, "Gespräch beendet.")
    }

    func testHandoverCardUsesServerText() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/api/v1/chat", json: chatJSON(
            handover: true,
            message: ["id": "a1a1a1a1-0000-4000-8000-000000000001", "role": "assistant",
                      "content": "关于提现问题，我为您转接人工客服。", "created_at": "2026-10-30T10:00:00Z",
                      "metadata": ["handover_notice": true]],
            card: zhCard))
        let (controller, _, _) = makeController(engine: engine)
        await send(controller, "我要提现")
        XCTAssertTrue(controller.messages.contains { $0.role == .system && $0.content == zhCard })
        XCTAssertFalse(controller.messages.contains { $0.content == sdk("escalatedMessage") })
        XCTAssertTrue(controller.isEscalated)
    }

    func testLegacyHandoverFallsBackToSDKString() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/api/v1/chat", json: chatJSON(handover: true))
        let (controller, _, _) = makeController(engine: engine)
        await send(controller, "我要提现")
        XCTAssertTrue(controller.messages.contains { $0.role == .system && $0.content == sdk("escalatedMessage") },
                      "старый бэкенд без handover_card_text — строка SDK")
    }

    func testCannedNoticeIsTheCard() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/api/v1/chat", json: chatJSON(
            handover: true,
            message: ["id": "b2b2b2b2-0000-4000-8000-000000000002", "role": "assistant",
                      "content": zhCard, "created_at": "2026-10-30T10:00:00Z",
                      "metadata": ["handover_notice": true, "handover_canned": true]],
            card: zhCard))
        let (controller, _, _) = makeController(engine: engine)
        await send(controller, "转人工")
        XCTAssertEqual(controller.messages.filter { $0.content == zhCard }.count, 1,
                       "стандартное уведомление — само карточка, второй рядом нет")
        XCTAssertTrue(controller.isEscalated)
    }

    func testHandoverEchoOfCustomerMessageDrawsServerCardOnly() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/api/v1/chat", json: chatJSON(
            handover: true,
            message: ["id": "e1e1e1e1-0000-4000-8000-000000000003", "role": "user",
                      "content": "我要提现", "created_at": "2026-10-30T10:00:00Z"],
            card: zhCard))
        let (controller, _, _) = makeController(engine: engine)
        await send(controller, "我要提现")
        XCTAssertTrue(controller.messages.contains { $0.role == .system && $0.content == zhCard },
                      "карточка на любой ветке передачи — текстом сервера")
        XCTAssertEqual(controller.messages.filter { $0.role == .user }.count, 1,
                       "эхо реплики клиента — не второй пузырь")
        XCTAssertTrue(controller.isEscalated)
    }

    func testStatusCardsUseRememberedServerTexts() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/api/v1/chat", json: chatJSON(
            handover: true, card: zhCard, statusTexts: ["back_to_ai": zhBack, "resolved": zhEnded]))
        let (controller, _, _) = makeController(engine: engine)
        await send(controller, "转人工")
        XCTAssertEqual(controller.statusTexts.backToAI, zhBack)

        // Кадр status_changed языка не несёт — карточка запомненным текстом.
        controller.handle(.statusChanged(newStatus: "bot"))
        XCTAssertEqual(controller.messages.first { $0.id == "back-to-ai-ws" }?.content, zhBack)

        // Поллинг приносит свежие тексты раньше перехода.
        controller.handle(.statusTexts(StatusTextsDTO(resolved: "Gespräch beendet.")))
        controller.handle(.statusChanged(newStatus: "resolved"))
        XCTAssertEqual(controller.messages.first { $0.id == "resolved-ws" }?.content, "Gespräch beendet.")
    }

    func testStatusCardsFallBackToSDKStringsAndClearOnReset() {
        let (controller, _, _) = makeController()
        controller.handle(.statusChanged(newStatus: "agent"))
        XCTAssertEqual(controller.messages.first { $0.id == "back-to-ai-ws" }?.content, sdk("backToAI"))

        controller.handle(.statusTexts(StatusTextsDTO(backToAI: zhBack)))
        XCTAssertEqual(controller.statusTexts.backToAI, zhBack)
        controller.clear()
        XCTAssertNil(controller.statusTexts.backToAI, "другой пользователь — другой язык")
    }

    func testEscalateUsesServerMessageAndRefusalText() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/escalate", json: json([
            "conversation_id": conv, "status": "escalated", "message": zhCard,
            "status_texts": ["back_to_ai": zhBack],
        ]))
        engine.stub(pathContains: "/api/v1/chat", json: chatJSON())
        let (controller, _, _) = makeController(engine: engine)
        await send(controller, "我要提现")
        await controller.escalate()
        XCTAssertEqual(controller.messages.first { $0.id == "handover-\(conv)" }?.content, zhCard)
        XCTAssertEqual(controller.statusTexts.backToAI, zhBack)

        // Локальный «Continue with AI» — тоже на языке клиента.
        await controller.continueWithAI()
        XCTAssertEqual(controller.messages.first { $0.id == "back-to-ai-\(conv)" }?.content, zhBack)

        // Отказ — серверный текст на языке клиента.
        engine.stubs.removeAll()
        engine.stub(pathContains: "/escalate", status: 500, json: json(["error": "Internal error", "message": zhFailed]))
        await controller.escalate()
        XCTAssertEqual(controller.messages.first { $0.id == "escalate-error-\(conv)" }?.content, zhFailed)
    }

    func testEscalateRefusalWithoutMessageFallsBack() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/escalate", status: 404, json: #"{"error":"not found"}"#)
        engine.stub(pathContains: "/api/v1/chat", json: chatJSON())
        let (controller, _, _) = makeController(engine: engine)
        await send(controller, "hi")
        await controller.escalate()
        XCTAssertEqual(controller.messages.first { $0.id == "escalate-error-\(conv)" }?.content, sdk("networkError"))
    }

    func testHandoverCardTextOrder() {
        let notice = try! JSONDecoder().decode(MessageDTO.self, from: Data(json([
            "id": "x-1", "role": "assistant", "content": "关于提现问题，我为您转接人工客服。",
            "metadata": ["handover_card_text": zhCard],
        ]).utf8))
        XCTAssertEqual(ServerTexts.handoverCardText(response: nil, notice: notice, fallback: "sdk"), zhCard,
                       "нет поля ответа — metadata уведомления")
        XCTAssertEqual(ServerTexts.handoverCardText(response: "card", notice: notice, fallback: "sdk"), "card",
                       "поле ответа — первым")
        XCTAssertEqual(ServerTexts.handoverCardText(response: "  ", notice: nil, fallback: "sdk"), "sdk")
    }
}
