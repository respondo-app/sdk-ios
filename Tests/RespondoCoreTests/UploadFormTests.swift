import XCTest
@testable import RespondoCore

/// Форма `/chat/upload`: агент всегда, беседа и ключи владения — только при ключе владения.
final class UploadFormTests: XCTestCase {
    private func upload(conversationId: String?, ownership: OwnershipParams) async throws -> String {
        let engine = FakeHttpEngine()
        let json = String(decoding: Fixture.data("upload-response"), as: UTF8.self)
        engine.stub(pathContains: "/chat/upload", json: json)
        let api = ApiClient(engine: engine, baseUrl: "https://api.respondo.ai")
        _ = try await api.upload(
            fileName: "a.png", mimeType: "image/png", data: Data([1, 2, 3]),
            agentId: "agent-1", conversationId: conversationId, ownership: ownership
        )
        let body = try XCTUnwrap(engine.sentRequests.last?.body)
        return String(decoding: body, as: UTF8.self)
    }

    private func part(_ name: String, _ value: String) -> String {
        "name=\"\(name)\"\r\n\r\n\(value)"
    }

    private func assertFields(_ body: String, present: [String: String], absent: [String],
                              file: StaticString = #filePath, line: UInt = #line) {
        for (name, value) in present {
            XCTAssertTrue(body.contains(part(name, value)), "нет поля \(name)", file: file, line: line)
        }
        for name in absent {
            XCTAssertFalse(body.contains("name=\"\(name)\""), "лишнее поле \(name)", file: file, line: line)
        }
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"a.png\""), file: file, line: line)
    }

    func testWithoutConversationSendsAgentOnly() async throws {
        let body = try await upload(conversationId: nil, ownership: OwnershipParams(visitorId: "v_1"))
        assertFields(body, present: ["agent_id": "agent-1"],
                     absent: ["conversation_id", "session_token", "user_hash", "visitor_id"])
    }

    func testConversationWithTokenSendsConvCreds() async throws {
        let body = try await upload(
            conversationId: "conv-1",
            ownership: OwnershipParams(sessionToken: "tok", userHash: nil, visitorId: "v_1"))
        assertFields(body,
                     present: ["agent_id": "agent-1", "conversation_id": "conv-1",
                               "session_token": "tok", "visitor_id": "v_1"],
                     absent: ["user_hash"])
    }

    func testConversationWithoutOwnershipKeyDropsConversation() async throws {
        let body = try await upload(
            conversationId: "conv-1",
            ownership: OwnershipParams(sessionToken: "", userHash: "", visitorId: "v_1"))
        assertFields(body, present: ["agent_id": "agent-1"],
                     absent: ["conversation_id", "session_token", "user_hash", "visitor_id"])
    }

    func testSignedIdentityWithoutTokenSendsUserHash() async throws {
        let body = try await upload(
            conversationId: "conv-1",
            ownership: OwnershipParams(sessionToken: nil, userHash: "h", visitorId: "v_1"))
        assertFields(body,
                     present: ["agent_id": "agent-1", "conversation_id": "conv-1",
                               "user_hash": "h", "visitor_id": "v_1"],
                     absent: ["session_token"])
    }

    func testEmptyConversationIdDropsConversation() async throws {
        let body = try await upload(
            conversationId: "",
            ownership: OwnershipParams(sessionToken: "tok", userHash: nil, visitorId: "v_1"))
        assertFields(body, present: ["agent_id": "agent-1"],
                     absent: ["conversation_id", "session_token", "visitor_id"])
    }

    func testAgentIdPrecedesFilePart() async throws {
        let body = try await upload(
            conversationId: "conv-1",
            ownership: OwnershipParams(sessionToken: "tok", userHash: nil, visitorId: "v_1"))
        let agent = try XCTUnwrap(body.range(of: "name=\"agent_id\""))
        let file = try XCTUnwrap(body.range(of: "name=\"file\""))
        XCTAssertLessThan(agent.lowerBound, file.lowerBound)
        let visitor = try XCTUnwrap(body.range(of: "name=\"visitor_id\""))
        XCTAssertLessThan(visitor.lowerBound, file.lowerBound)
    }
}
