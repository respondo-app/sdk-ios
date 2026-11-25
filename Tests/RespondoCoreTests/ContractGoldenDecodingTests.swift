import Foundation
import XCTest
@testable import RespondoCore

/// Разбор golden-снимков legacy-контракта чата (`Fixtures/contract-*.json`) в DTO SDK.
/// Копии держатся идентичными `sdks/spec/fixtures/contract` тестом бэкенда
/// `TestChatContractFixtureCopiesInSync`.
final class ContractGoldenDecodingTests: XCTestCase {

    private func golden(_ name: String) -> [String: Any] {
        let object = try! JSONSerialization.jsonObject(with: Fixture.data("contract-\(name)"))
        return object as! [String: Any]
    }

    private func decode<T: Decodable>(_ type: T.Type, _ part: Any?) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(part))
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func assertChat(_ dto: ChatResponseDTO, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse((dto.conversationId ?? "").isEmpty, file: file, line: line)
        if let message = dto.message {
            XCTAssertFalse(message.role.isEmpty, file: file, line: line)
        }
    }

    private func frameTexts(_ name: String, type: String) -> [String] {
        let frames = golden(name)["frames"] as! [[String: Any]]
        return frames.filter { $0["type"] as? String == type }.map {
            String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)!
        }
    }

    func testSyncAiFirstDecodes() throws {
        let dto = try decode(ChatResponseDTO.self, golden("sync-ai-first")["body"])
        assertChat(dto)
        XCTAssertNotNil(dto.message)
    }

    func testSyncAiProductsDecodes() throws {
        let dto = try decode(ChatResponseDTO.self, golden("sync-ai-products")["body"])
        assertChat(dto)
        XCTAssertNotNil(dto.message)
    }

    func testSyncAiHandoverDecodes() throws {
        let dto = try decode(ChatResponseDTO.self, golden("sync-ai-handover")["body"])
        assertChat(dto)
        XCTAssertEqual(dto.humanHandover, true)
    }

    func testSyncHumansOnlyDecodes() throws {
        let dto = try decode(ChatResponseDTO.self, golden("sync-humans-only")["body"])
        assertChat(dto)
        XCTAssertEqual(dto.humanHandover, true)
    }

    func testUploadAttachmentChatPartDecodes() throws {
        let chat = golden("upload-attachment")["chat"] as? [String: Any]
        assertChat(try decode(ChatResponseDTO.self, chat?["body"]))
    }

    func testUploadAttachmentUploadBodyDecodes() throws {
        let upload = golden("upload-attachment")["upload"] as? [String: Any]
        let dto = try decode(ChatAttachmentDTO.self, upload?["body"])
        XCTAssertFalse(dto.id.isEmpty)
        XCTAssertFalse(dto.filename.isEmpty)
        XCTAssertFalse(dto.url.isEmpty)
    }

    func testTestChatDecodes() throws {
        let dto = try decode(ChatResponseDTO.self, golden("test-chat")["body"])
        assertChat(dto)
        XCTAssertNotNil(dto.message)
    }

    func testResumeDecodes() throws {
        let dto = try decode(ResumeResponseDTO.self, golden("resume")["body"])
        XCTAssertFalse((dto.messages ?? []).isEmpty)
    }

    func testHistoryDecodes() throws {
        let dto = try decode(HistoryResponseDTO.self, golden("history")["body"])
        XCTAssertFalse((dto.messages ?? []).isEmpty)
    }

    func testWsNewMessageFrameDecodes() {
        let texts = frameTexts("ws-new-message", type: "new_message")
        XCTAssertFalse(texts.isEmpty)
        for text in texts {
            guard case .newMessage? = RealtimeProtocol.decode(text, subscribedConversationId: nil) else {
                return XCTFail("expected new_message")
            }
        }
    }

    func testWsAckMessageUpdatedFrameDecodes() {
        let texts = frameTexts("ws-ack", type: "message_updated")
        XCTAssertFalse(texts.isEmpty)
        for text in texts {
            guard case .messageUpdated? = RealtimeProtocol.decode(text, subscribedConversationId: nil) else {
                return XCTFail("expected message_updated")
            }
        }
    }
}
