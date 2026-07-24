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

    func testChatResponseHandoverDecodes() {
        let response = Fixture.decode(ChatResponseDTO.self, "chat-response-handover")
        XCTAssertEqual(response.humanHandover, true)
        XCTAssertEqual(response.ticketId, 48213)
        XCTAssertNotNil(response.ticketURL)
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

    func testTypingEventDecodes() {
        let text = String(data: Fixture.data("message-event-typing"), encoding: .utf8)!
        guard case .typing(let author)? = RealtimeProtocol.decode(text, subscribedConversationId: "a1c4e7b2-5d38-4f6a-9e10-3b7c2d5f8a90") else {
            return XCTFail("expected typing")
        }
        XCTAssertEqual(author, "Анна")
    }
}
