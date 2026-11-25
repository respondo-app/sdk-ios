import Foundation
import XCTest
@testable import RespondoCore

/// Проверяет, что все 15 фикстур спеки декодируются в DTO SDK без потери ключевых полей.
final class FixtureDecodingTests: XCTestCase {
    func testConfigDecodes() {
        let config = Fixture.decode(WidgetConfigDTO.self, "config")
        XCTAssertEqual(config.primaryColor, "#2563eb")
        XCTAssertEqual(config.chatSize, "default")
        XCTAssertTrue(config.identityVerificationEnabled ?? false)
        XCTAssertEqual(config.quickQuestions?.count, 3)
        XCTAssertEqual(config.officeHours?.open, true)
        XCTAssertEqual(config.visitorLanguage, "ru")
    }

    func testChatResponseFirstDecodes() {
        let response = Fixture.decode(ChatResponseDTO.self, "chat-response-first")
        XCTAssertEqual(response.humanHandover, false)
        XCTAssertEqual(response.message?.role, "assistant")
        XCTAssertEqual(response.suggestedQuestions?.count, 3)
        XCTAssertEqual(response.docLinks?.count, 2)
        XCTAssertNotNil(response.sessionToken)
    }

    /// Текст, который набрал SDK за посетителя (пилюля, AI-подсказка, заглушка вложения), уходит с
    /// `input_source` — сервер не выбирает по нему язык беседы. Без источника ключа нет.
    func testChatRequestCarriesInputSource() throws {
        let tagged = ChatRequestDTO(agentId: "a", message: "How do I start?", inputSource: InputSource.suggestion)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tagged)) as? [String: Any]
        XCTAssertEqual(json?["input_source"] as? String, "suggestion")

        let plain = ChatRequestDTO(agentId: "a", message: "hi")
        let plainJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
        XCTAssertNil(plainJSON?["input_source"])
    }

    /// Язык беседы после хода едет и в ответе `/chat` (`lang`): на новую беседу
    /// SDK подписывается только после ответа, и событие
    /// `conversation_updated{lang}` первого хода до него не доходит.
    func testChatResponseCarriesTurnLanguage() throws {
        let zh = try JSONDecoder().decode(
            ChatResponseDTO.self,
            from: Data(#"{"conversation_id":"c1","human_handover":false,"lang":"zh-Hant"}"#.utf8)
        )
        XCTAssertEqual(zh.lang, "zh-Hant")
        let fixture = Fixture.decode(ChatResponseDTO.self, "chat-response-first")
        XCTAssertNil(fixture.lang)
    }

    func testChatResponseHandoverDecodes() {
        let response = Fixture.decode(ChatResponseDTO.self, "chat-response-handover")
        XCTAssertEqual(response.humanHandover, true)
        XCTAssertNotNil(response.message)
    }

    /// Прод-инцидент: после эскалации виджет показывал клиенту кнопку
    /// «View ticket #42466» со ссылкой на
    /// https://<tenant>.zendesk.com/agent/tickets/42466 — staff-интерфейс
    /// хелпдеска арендатора.
    ///
    /// Раньше фикстура handover сама содержала ticket_url/ticket_id, а этот сьют
    /// утверждал их наличие — то есть тесты защищали утечку. Утверждение
    /// перевёрнуто: ни в одном клиентском payload не должно быть ключа со
    /// словом "ticket". Скан рекурсивный, поэтому вложенное поле тоже не
    /// проскочит. Аналог backend/internal/api/handlers/escalation_no_ticket_leak_test.go.
    func testCustomerFacingFixturesCarryNoTicketKeys() {
        for name in ["chat-response-handover", "chat-response-first", "resume", "history-page"] {
            guard let json = try? JSONSerialization.jsonObject(with: Fixture.data(name)) else {
                XCTFail("фикстура \(name) не разобралась как JSON")
                continue
            }
            for key in Self.jsonKeys(json) where key.lowercased().contains("ticket") {
                XCTFail("фикстура \(name) содержит ключ \"\(key)\": номер и URL тикета — "
                    + "внутренние данные хелпдеска арендатора, клиенту они не уходят")
            }
        }
    }

    /// Рекурсивно собирает имена всех ключей JSON-объектов, включая вложенные в массивы.
    private static func jsonKeys(_ value: Any) -> [String] {
        if let dict = value as? [String: Any] {
            return dict.flatMap { [$0.key] + jsonKeys($0.value) }
        }
        if let array = value as? [Any] {
            return array.flatMap { jsonKeys($0) }
        }
        return []
    }

    func testResumeDecodes() {
        let resume = Fixture.decode(ResumeResponseDTO.self, "resume")
        XCTAssertEqual(resume.status, "open")
        XCTAssertEqual(resume.messages?.count, 2)
        XCTAssertEqual(resume.hasMore, false)
        XCTAssertNotNil(resume.conversationId)
        XCTAssertNotNil(resume.sessionToken)
    }

    func testHistoryDecodes() {
        let history = Fixture.decode(HistoryResponseDTO.self, "history-page")
        XCTAssertEqual(history.messages?.count, 2)
        XCTAssertEqual(history.hasMore, true)
        XCTAssertNotNil(history.oldestMessageId)
    }

    func testUploadDecodes() {
        let upload = Fixture.decode(ChatAttachmentDTO.self, "upload-response")
        XCTAssertEqual(upload.contentType, "image/png")
        XCTAssertEqual(upload.size, 184320)
    }

    func testWsEventFixturesDecode() {
        for name in ["message-event-new", "message-event-typing", "message-event-status"] {
            let text = String(data: Fixture.data(name), encoding: .utf8)!
            let event = RealtimeProtocol.decode(text, subscribedConversationId: "a1c4e7b2-5d38-4f6a-9e10-3b7c2d5f8a90")
            XCTAssertNotNil(event, "event \(name) should decode")
        }
    }

    func testNewMessageEventCarriesAuthor() {
        let text = String(data: Fixture.data("message-event-new"), encoding: .utf8)!
        guard case .newMessage(let dto)? = RealtimeProtocol.decode(text, subscribedConversationId: "a1c4e7b2-5d38-4f6a-9e10-3b7c2d5f8a90") else {
            return XCTFail("expected new_message")
        }
        XCTAssertEqual(dto.authorName, "Анна")
        XCTAssertEqual(dto.role, "assistant")
    }

    /// Плоская форма ошибки: `error` строкой, верхнеуровневые `code` и `message`.
    func testBackendErrorFlatDecodes() {
        let body = Fixture.decode(BackendError.self, "error-flat")
        XCTAssertEqual(body, BackendError(error: "invalid agent_id", code: "BAD_REQUEST", message: "invalid agent_id"))
    }

    /// Вложенная форма (`ErrorHandler`): объект в `error` больше не роняет
    /// decode, `error` — его `message`.
    func testBackendErrorNestedDecodes() throws {
        let body = try JSONDecoder().decode(BackendError.self, from: Fixture.data("error-nested"))
        XCTAssertEqual(body.code, "NOT_FOUND")
        XCTAssertEqual(body.error, "Resource not found")
        XCTAssertEqual(body.message, "Resource not found")
    }

    /// Тело старого бэкенда без `code`: decode не падает, код — `nil`.
    func testBackendErrorLegacyHasNoCode() throws {
        let body = try JSONDecoder().decode(BackendError.self, from: Fixture.data("error-legacy"))
        XCTAssertEqual(body.error, "invalid agent_id")
        XCTAssertNil(body.code)
        XCTAssertNil(body.message)
    }

    /// `error` ни строкой, ни объектом — `nil`, а не ошибка decode.
    func testBackendErrorUnexpectedErrorTypeIsNil() throws {
        let body = try JSONDecoder().decode(BackendError.self, from: Data(#"{"error":42,"code":"BAD_REQUEST"}"#.utf8))
        XCTAssertNil(body.error)
        XCTAssertEqual(body.code, "BAD_REQUEST")
    }

    /// Не-2xx через `ensureOK` несёт статус, текст `error` и `code` тела.
    func testEnsureOKCarriesBackendCode() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/chat/history", status: 404,
                    json: String(data: Fixture.data("error-nested"), encoding: .utf8)!)
        let api = ApiClient(engine: engine, baseUrl: "https://api.respondo.ai")
        do {
            _ = try await api.history(conversationId: "c1", before: "m1", ownership: OwnershipParams())
            XCTFail("ожидался TransportError.backend")
        } catch let error as TransportError {
            XCTAssertEqual(error, .backend(status: 404, message: "Resource not found", code: "NOT_FOUND"))
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
    }

    /// Тело без `code` через `ensureOK` — `code: nil`.
    func testEnsureOKLegacyBodyHasNilCode() async {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/chat/history", status: 400,
                    json: String(data: Fixture.data("error-legacy"), encoding: .utf8)!)
        let api = ApiClient(engine: engine, baseUrl: "https://api.respondo.ai")
        do {
            _ = try await api.history(conversationId: "c1", before: "m1", ownership: OwnershipParams())
            XCTFail("ожидался TransportError.backend")
        } catch let error as TransportError {
            XCTAssertEqual(error, .backend(status: 400, message: "invalid agent_id", code: nil))
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
    }

    func testTypingEventDecodes() {
        let text = String(data: Fixture.data("message-event-typing"), encoding: .utf8)!
        guard case .typing(let author)? = RealtimeProtocol.decode(text, subscribedConversationId: "a1c4e7b2-5d38-4f6a-9e10-3b7c2d5f8a90") else {
            return XCTFail("expected typing")
        }
        XCTAssertEqual(author, "Анна")
    }
}
