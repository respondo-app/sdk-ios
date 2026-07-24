import XCTest
@testable import RespondoCore

@MainActor
final class ConversationControllerTests: XCTestCase {
    private func messageDTO(id: String, role: String, author: String? = nil, content: String = "text") -> MessageDTO {
        var dict: [String: Any] = [
            "id": id,
            "conversation_id": "a1c4e7b2-5d38-4f6a-9e10-3b7c2d5f8a90",
            "role": role,
            "content": content,
            "created_at": "2026-07-23T13:00:00Z",
        ]
        if let author { dict["author_name"] = author }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(MessageDTO.self, from: data)
    }

    func testUserRoleFilteredFromRealtime() {
        let (controller, _, _) = makeController()
        controller.handle(.newMessage(messageDTO(id: "u1-2222-3333-4444-555555555555", role: "user")))
        XCTAssertTrue(controller.messages.isEmpty, "сообщения role=user отбрасываются (уже оптимистичны)")
    }

    func testAssistantMessageAdded() {
        let (controller, _, _) = makeController()
        controller.handle(.newMessage(messageDTO(id: "a1-2222-3333-4444-555555555555", role: "assistant")))
        XCTAssertEqual(controller.messages.count, 1)
        XCTAssertEqual(controller.messages.first?.role, .assistant)
    }

    func testDedupById() {
        let (controller, _, _) = makeController()
        let dto = messageDTO(id: "a1-2222-3333-4444-555555555555", role: "assistant")
        controller.handle(.newMessage(dto))
        controller.handle(.newMessage(dto))
        XCTAssertEqual(controller.messages.count, 1, "дедуп по id")
    }

    func testAgentNormalizedAndFlagsHumanReplied() {
        let (controller, _, _) = makeController()
        controller.handle(.newMessage(messageDTO(id: "ag-2222-3333-4444-555555555555", role: "agent", author: "Анна")))
        XCTAssertEqual(controller.messages.first?.role, .assistant, "agent → assistant")
        XCTAssertTrue(controller.agentHasReplied)
    }

    func testUnreadBumpsWhenPanelClosed() {
        let (controller, host, _) = makeController()
        host.panelOpen = false
        controller.handle(.newMessage(messageDTO(id: "a1-2222-3333-4444-555555555555", role: "assistant")))
        XCTAssertEqual(host.unread, 1)
    }

    func testNoUnreadWhenPanelOpen() {
        let (controller, host, _) = makeController()
        host.panelOpen = true
        controller.handle(.newMessage(messageDTO(id: "a1-2222-3333-4444-555555555555", role: "assistant")))
        XCTAssertEqual(host.unread, 0)
    }

    func testEscalationStatus() {
        let (controller, host, _) = makeController()
        controller.handle(.statusChanged(newStatus: "escalated"))
        XCTAssertTrue(controller.isEscalated)
        XCTAssertTrue(host.escalated)
    }

    func testBackToAIStatus() {
        let (controller, _, _) = makeController()
        controller.handle(.statusChanged(newStatus: "escalated"))
        controller.handle(.statusChanged(newStatus: "agent"))
        XCTAssertFalse(controller.isEscalated)
        XCTAssertTrue(controller.messages.contains { $0.id == "back-to-ai-ws" })
    }

    func testTypingSetsAuthor() {
        let (controller, _, _) = makeController()
        controller.handle(.typing(authorName: "Анна"))
        XCTAssertEqual(controller.typingAuthor, "Анна")
    }

    func testConversationUpdatedSwitchesLang() {
        let (controller, _, _) = makeController()
        XCTAssertEqual(controller.lang, "ru")
        controller.handle(.conversationUpdated(field: nil, lang: "en"))
        XCTAssertEqual(controller.lang, "en")
    }

    func testEmailValidation() {
        XCTAssertTrue(ConversationController.isValidEmail("a@b.com"))
        XCTAssertFalse(ConversationController.isValidEmail("nope"))
        XCTAssertFalse(ConversationController.isValidEmail("a@b"))
    }

    func testOptimisticSendAndResponse() async throws {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/api/v1/chat", json: String(data: Fixture.data("chat-response-first"), encoding: .utf8)!)
        let (controller, host, _) = makeController(engine: engine)

        controller.send(text: "Как подключить канал?")
        // Оптимистичное сообщение появляется сразу.
        XCTAssertEqual(controller.messages.last?.role, .user)
        XCTAssertEqual(controller.messages.last?.deliveryStatus, .sending)

        // Ждём завершения сети.
        try await waitUntil { !controller.isLoading }

        XCTAssertTrue(controller.messages.contains { $0.role == .assistant && $0.content.contains("Каналы") })
        XCTAssertEqual(controller.suggestedQuestions.count, 3)
        XCTAssertNotNil(host.lastSessionToken, "session_token сохранён из ответа")
        // Оптимистичное сообщение помечено доставленным.
        XCTAssertTrue(controller.messages.contains { $0.role == .user && $0.deliveryStatus == .sent })
    }

    func testSendFailureMarksFailed() async throws {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/api/v1/chat", status: 500, json: #"{"error":"boom"}"#)
        let (controller, _, _) = makeController(engine: engine)
        controller.send(text: "hi")
        try await waitUntil { !controller.isLoading }
        XCTAssertTrue(controller.messages.contains { $0.role == .user && $0.deliveryStatus == .failed })
    }

    func testMessageCappedAt750() async throws {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/api/v1/chat", json: String(data: Fixture.data("chat-response-first"), encoding: .utf8)!)
        let (controller, _, _) = makeController(engine: engine)

        let long = String(repeating: "a", count: 900)
        controller.send(text: long)
        // Пузырь обрезан до лимита 750.
        XCTAssertEqual(controller.messages.last?.content.count, ConversationController.maxMessageLength)

        try await waitUntil { !controller.isLoading }
        // В тело запроса ушло не больше 750 символов.
        XCTAssertTrue(engine.requestSent(pathContains: "/api/v1/chat"))
    }

    func testMessageUpdatedFailedMarksBubble() {
        let (controller, _, _) = makeController()
        controller.handle(.newMessage(messageDTO(id: "ag-2222-3333-4444-555555555555", role: "agent", author: "Анна")))
        controller.handle(.messageUpdated(MessagePatch(
            id: "ag-2222-3333-4444-555555555555",
            deliveryStatus: "failed",
            deliveryError: "recipient unreachable"
        )))
        XCTAssertTrue(controller.messages.contains { $0.id == "ag-2222-3333-4444-555555555555" && $0.deliveryStatus == .failed })
    }

    // MARK: - Bootstrap / resume (P1-1, P2-1)

    /// P1-1: session_token из resume пробрасывается в host (иначе subscribe/history без токена).
    func testResumeSessionTokenPropagatedToHost() {
        let (controller, host, _) = makeController()
        host.sessionToken = "stale-stored-token"
        let resume = ResumeResponseDTO(
            status: "open",
            messages: [messageDTO(id: "a1c4e7b2-5d38-4f6a-9e10-3b7c2d5f8a90", role: "assistant")],
            hasMore: false,
            historyConversationId: "conv-1",
            oldestMessageId: nil,
            conversationId: "conv-1",
            sessionToken: "fresh-resume-token"
        )
        controller.bootstrap(cacheBlob: nil, resume: resume)
        XCTAssertEqual(host.lastConversationId, "conv-1")
        XCTAssertEqual(host.lastSessionToken, "fresh-resume-token", "свежий session_token из resume проброшен в host, а не затёрт хранимым")
    }

    /// P1-1: без токена в resume для живой беседы сохраняем ранее хранимый токен.
    func testResumeWithoutTokenKeepsStored() {
        let (controller, host, _) = makeController()
        host.sessionToken = "stored-token"
        let resume = ResumeResponseDTO(
            status: "open", messages: nil, hasMore: false,
            historyConversationId: "conv-2", oldestMessageId: nil,
            conversationId: "conv-2", sessionToken: nil
        )
        controller.bootstrap(cacheBlob: nil, resume: resume)
        XCTAssertEqual(host.lastSessionToken, "stored-token", "для живой беседы без токена в resume оставляем хранимый")
    }

    /// P2-1: последний серверный id восстановленной беседы доступен для засева курса поллинга.
    func testLastRestoredBackendMessageIdSeeded() {
        let (controller, _, _) = makeController()
        let resume = ResumeResponseDTO(
            status: "open",
            messages: [
                messageDTO(id: "a1c4e7b2-5d38-4f6a-9e10-000000000001", role: "assistant"),
                messageDTO(id: "a1c4e7b2-5d38-4f6a-9e10-000000000002", role: "assistant"),
            ],
            hasMore: false, historyConversationId: "conv-3", oldestMessageId: nil,
            conversationId: "conv-3", sessionToken: "t"
        )
        controller.bootstrap(cacheBlob: nil, resume: resume)
        XCTAssertEqual(controller.lastRestoredBackendMessageId, "a1c4e7b2-5d38-4f6a-9e10-000000000002",
                       "курс поллинга засевается последним серверным id")
    }

    // MARK: - Кампании (P2-1)

    private func campaignMessageDTO(id: String, chatDisplay: Bool) -> MessageDTO {
        var dict: [String: Any] = [
            "id": id,
            "conversation_id": "a1c4e7b2-5d38-4f6a-9e10-3b7c2d5f8a90",
            "role": "assistant",
            "content": "campaign text",
            "created_at": "2026-07-23T13:00:00Z",
        ]
        if chatDisplay { dict["metadata"] = ["chat_display": "thread"] }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(MessageDTO.self, from: data)
    }

    /// P2-1: in-thread кампания без chat_display при закрытой панели даёт ровно +1
    /// (раньше handleNewMessage и handleCampaign бампили независимо → +2).
    func testCampaignUnreadCountedOnce() {
        let (controller, host, _) = makeController()
        host.panelOpen = false
        controller.handle(.campaignConversation(
            conversationId: "c0ffee00-0000-4000-8000-000000000001",
            message: campaignMessageDTO(id: "b1c4e7b2-5d38-4f6a-9e10-000000000abc", chatDisplay: false)
        ))
        XCTAssertEqual(host.unread, 1, "кампания без chat_display считается один раз")
    }

    /// P2-1: кампания с chat_display тоже даёт ровно +1 (без двойного счёта).
    func testCampaignWithChatDisplayCountedOnce() {
        let (controller, host, _) = makeController()
        host.panelOpen = false
        controller.handle(.campaignConversation(
            conversationId: "c0ffee00-0000-4000-8000-000000000002",
            message: campaignMessageDTO(id: "b2c4e7b2-5d38-4f6a-9e10-000000000def", chatDisplay: true)
        ))
        XCTAssertEqual(host.unread, 1)
    }

    func testCampaignNoUnreadWhenPanelOpen() {
        let (controller, host, _) = makeController()
        host.panelOpen = true
        controller.handle(.campaignConversation(
            conversationId: "c0ffee00-0000-4000-8000-000000000003",
            message: campaignMessageDTO(id: "b3c4e7b2-5d38-4f6a-9e10-000000000fff", chatDisplay: false)
        ))
        XCTAssertEqual(host.unread, 0)
    }

    // MARK: - Обрезка по рунам (P2-4)

    func testClampedMessageByUnicodeScalars() {
        // 745 ASCII + составной эмодзи-кластер (7 скаляров) = 752 скаляра.
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.unicodeScalars.count, 7, "семья = 7 скаляров")
        let source = String(repeating: "a", count: 745) + family
        XCTAssertEqual(source.unicodeScalars.count, 752)

        let clamped = ConversationController.clampedMessage(source)
        XCTAssertEqual(clamped.unicodeScalars.count, ConversationController.maxMessageLength,
                       "итог ровно 750 скаляров")
        // Ни один скаляр не разорван: срез совпадает поскалярно и валиден в UTF-8.
        XCTAssertEqual(Array(clamped.unicodeScalars), Array(source.unicodeScalars.prefix(750)))
        let roundTrip = String(decoding: Array(clamped.utf8), as: UTF8.self)
        XCTAssertEqual(roundTrip, clamped, "строка валидна в UTF-8 без разрыва суррогатов")
    }

    func testClampedMessageShortUnchanged() {
        XCTAssertEqual(ConversationController.clampedMessage("привет"), "привет")
    }

    // MARK: - Resolved reset (P3-2)

    func testResolvedResetNotRescheduledOnDuplicate() {
        let (controller, _, _) = makeController()
        controller.handle(.statusChanged(newStatus: "resolved"))
        controller.handle(.statusChanged(newStatus: "resolved")) // дубль (WS + поллинг)
        XCTAssertEqual(controller.resolveResetScheduleCount, 1,
                       "таймер сброса взводится один раз, повтор не перепланирует")
    }

    /// Ждёт условие с таймаутом (для асинхронных Task внутри контроллера).
    private func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timeout ожидания условия"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
