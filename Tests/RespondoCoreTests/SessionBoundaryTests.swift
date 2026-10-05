import XCTest
@testable import RespondoCore

/// ГРАНИЦА СЕССИИ НА КЛИЕНТЕ.
///
/// Одна беседа — один решённый вопрос. Закрытую строку следующее сообщение
/// пользователя не воскрешает: сервер форкает от неё follow-up и сцепляет их.
/// Пользователю про это не сообщают — у него один непрерывный чат, и ленту
/// этого чата собираем МЫ, идя по цепочке.
///
/// Значит несущая половина правила — клиентская. Сервер отдаёт
/// conversation_id + session_token при ЛЮБОМ статусе, закрытом в том числе,
/// именно затем, чтобы форку было от чего оттолкнуться. SDK их выбрасывал
/// (`resetConversationAfterResolve` обнулял id, ответ эскалации не
/// декодировал ни токен, ни ссылку назад и выбрасывался целиком) — и каждое
/// закрытие рождало осиротевший корень, а нажатие «нужен человек» отдавало
/// оператору кейс, в который пользователь не мог написать.
///
/// Бэкендовый контракт запинен e2e-тестами. Здесь пинится то, чего не
/// проверял никто: что КЛИЕНТ его соблюдает.
@MainActor
final class SessionBoundaryTests: XCTestCase {
    private let convA = "a1c4e7b2-5d38-4f6a-9e10-3b7c2d5f8a90"
    private let convB = "b2d5f8c3-6e49-4a7b-8f21-4c8d3e6a9b01"

    /// Восстановление ЗАКРЫТОЙ беседы: сервер отдал и id, и токен.
    private func resumeClosed(status: String = "resolved") -> ResumeResponseDTO {
        let json = """
        {"status":"\(status)","messages":[],"has_more":false,
         "conversation_id":"\(convA)","session_token":"token-A"}
        """
        return try! JSONDecoder().decode(ResumeResponseDTO.self, from: Data(json.utf8))
    }

    private func waitUntil(timeout: TimeInterval = 6, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timeout ожидания условия"); return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Хэндлы переживают закрытие

    func testClosedThreadKeepsItsHandles() {
        let (controller, host, _) = makeController()
        host.sessionToken = "token-A"

        controller.bootstrap(cacheBlob: nil, resume: resumeClosed())

        XCTAssertEqual(controller.conversationId, convA,
                       "id закрытой строки обязан остаться: от неё форкается follow-up, а без id форкать не от чего")
        XCTAssertTrue(controller.conversationClosed, "на закрытой строке слушать нечего")
        XCTAssertEqual(host.sessionToken, "token-A",
                       "токен — ключ от строки, от которой форкнется follow-up; стереть его значит уйти в форк без доказательства владения")
        XCTAssertEqual(host.closeCount, 1, "реалтайм отцеплен ровно один раз")
    }

    func testArchivedIsAlsoClosed() {
        let (controller, _, _) = makeController()
        controller.bootstrap(cacheBlob: nil, resume: resumeClosed(status: "archived"))
        XCTAssertTrue(controller.conversationClosed,
                      "archived — второй статус закрытия; клиент, знающий только resolved, опрашивал бы мёртвую строку вечно")
        XCTAssertEqual(controller.conversationId, convA)
    }

    func testLiveThreadIsNotClosed() {
        let (controller, host, _) = makeController()
        let json = """
        {"status":"open","messages":[],"conversation_id":"\(convA)","session_token":"token-A"}
        """
        let resume = try! JSONDecoder().decode(ResumeResponseDTO.self, from: Data(json.utf8))
        controller.bootstrap(cacheBlob: nil, resume: resume)
        XCTAssertFalse(controller.conversationClosed)
        XCTAssertEqual(host.closeCount, 0)
        XCTAssertEqual(host.lastConversationId, convA)
    }

    func testResolvedEventKeepsHandlesAfterTheResetTimer() async {
        let (controller, host, _) = makeController()
        host.sessionToken = "token-A"
        controller.bootstrap(cacheBlob: nil, resume: resumeClosed(status: "open"))

        controller.handle(.statusChanged(newStatus: "resolved"))
        await waitUntil { controller.conversationClosed }

        XCTAssertEqual(controller.conversationId, convA,
                       "таймер сброса обнулял id через 3 секунды — после чего следующее сообщение уходило с пустым conversation_id и создавало осиротевший корень")
        XCTAssertEqual(host.sessionToken, "token-A", "токен переживает закрытие")
        XCTAssertFalse(controller.isEscalated)
    }

    // MARK: - Следующее сообщение форкает ОТ закрытой строки

    func testNextMessageNamesTheClosedRowAndAdoptsTheFollowUp() async {
        let (controller, host, engine) = makeController()
        host.sessionToken = "token-A"
        controller.bootstrap(cacheBlob: nil, resume: resumeClosed())

        // Ответ сервера: закрытая строка форкнулась в follow-up.
        engine.stub(pathContains: "/api/v1/chat", json: """
        {"conversation_id":"\(convB)","session_token":"token-B","human_handover":false,
         "message":{"id":"c3e7b2a1-5d38-4f6a-9e10-3b7c2d5f8a91",
                    "conversation_id":"\(convB)","role":"assistant",
                    "content":"уже смотрю","created_at":"2026-08-03T10:00:00Z"}}
        """)

        controller.send(text: "всё ещё не работает")
        await waitUntil { controller.conversationId == self.convB }

        // 1. Запрос назвал ЗАКРЫТУЮ строку — иначе форкать не от чего.
        let sent = engine.sentRequests.first { $0.url.absoluteString.contains("/api/v1/chat") }
        let body = String(decoding: sent?.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains(convA),
                      "POST /chat ушёл без id закрытой строки — сервер уйдёт в ветку «беседы нет» и создаст осиротевший корень: без цепочки, без спам-тега, без человеческой передачи")
        XCTAssertTrue(body.contains("token-A"), "владение доказывается токеном предыдущей сессии")

        // 2. Хэндлы follow-up'а подхвачены.
        XCTAssertEqual(controller.conversationId, convB)
        XCTAssertFalse(controller.conversationClosed, "follow-up живой — реалтайм снова нужен")
        XCTAssertEqual(host.lastConversationId, convB)
        XCTAssertEqual(host.sessionToken, "token-B")
    }

    // MARK: - «Нужен человек» на закрытой строке

    func testEscalateOnClosedThreadAdoptsTheFollowUp() async {
        let (controller, host, engine) = makeController()
        host.sessionToken = "token-A"
        controller.bootstrap(cacheBlob: nil, resume: resumeClosed())

        engine.stub(pathContains: "/escalate", json: """
        {"conversation_id":"\(convB)","status":"escalated","message":"Оператор подключится",
         "session_token":"token-B","previous_conversation_id":"\(convA)"}
        """)

        await controller.escalate()

        XCTAssertTrue(engine.requestSent(pathContains: "/conversations/\(convA)/escalate"),
                      "кнопка обязана дойти до сети: пока id обнулялся, escalate() выходил на первой строке — ни follow-up, ни строки в «Needs human», ни ошибки пользователю")
        XCTAssertEqual(controller.conversationId, convB,
                       "остаться на закрытой строке значит оставить оператору кейс без единого сообщения, а ответ оператора — вне видимости пользователя")
        XCTAssertEqual(host.sessionToken, "token-B",
                       "без ключа от новой строки собственная лента ответит 403: follow-up рождается с access=token")
        XCTAssertFalse(controller.conversationClosed)
        XCTAssertTrue(controller.isEscalated)
    }

    func testEscalationResponseDecodesTheFollowUpHandles() {
        let json = """
        {"conversation_id":"\(convB)","status":"escalated","message":"…",
         "session_token":"token-B","previous_conversation_id":"\(convA)"}
        """
        let dto = try! JSONDecoder().decode(EscalationResponseDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.conversationId, convB)
        XCTAssertEqual(dto.sessionToken, "token-B", "поля не было в DTO вовсе — токен молча терялся при разборе")
        XCTAssertEqual(dto.previousConversationId, convA, "по нему клиент понимает, что тред тот же, и не сбрасывает ленту")
    }

    /// Эскалация на ЖИВОЙ беседе: сессия не менялась, сервер токен не выписывает —
    /// и прежний терять нельзя.
    func testEscalateOnLiveThreadKeepsExistingToken() async {
        let (controller, host, engine) = makeController()
        host.sessionToken = "token-A"
        controller.bootstrap(cacheBlob: nil, resume: resumeClosed(status: "open"))

        engine.stub(pathContains: "/escalate", json: """
        {"conversation_id":"\(convA)","status":"escalated","message":"…"}
        """)

        await controller.escalate()

        XCTAssertEqual(controller.conversationId, convA)
        XCTAssertEqual(host.sessionToken, "token-A", "частичный ответ не имеет права обнулять уже имеющийся ключ")
        XCTAssertTrue(controller.isEscalated)
    }
}
