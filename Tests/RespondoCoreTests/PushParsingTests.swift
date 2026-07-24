import XCTest
@testable import RespondoCore

final class PushParsingTests: XCTestCase {
    private func userInfo(from fixture: String) -> [AnyHashable: Any] {
        try! JSONSerialization.jsonObject(with: Fixture.data(fixture)) as! [AnyHashable: Any]
    }

    func testParsesMessagePush() {
        let payload = RespondoPushPayload.from(userInfo(from: "push-payload-message"))
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.kind, .message)
        XCTAssertEqual(payload?.conversationId, "a1c4e7b2-5d38-4f6a-9e10-3b7c2d5f8a90")
        XCTAssertEqual(payload?.messageId, "e9a3c1f6-4b8d-4e0a-b5f3-1d7b2a4e9c63")
        XCTAssertEqual(payload?.title, "Анна из поддержки")
        XCTAssertEqual(payload?.authorName, "Анна")
    }

    func testParsesCampaignPush() {
        let payload = RespondoPushPayload.from(userInfo(from: "push-payload-campaign"))
        XCTAssertEqual(payload?.kind, .campaign)
        XCTAssertEqual(payload?.deliveryId, "9c5d7e1f-3a8b-4c2d-e4f6-7a9b1c3d5e8f")
        XCTAssertNotNil(payload?.deepLink)
    }

    func testNonRespondoPushReturnsNil() {
        XCTAssertNil(RespondoPushPayload.from(["aps": ["alert": "hi"]]))
        XCTAssertNil(RespondoPushPayload.from([:]))
    }

    func testFcmStringPayloadParses() {
        // FCM кладёт respondo как JSON-строку в data.
        let json = String(data: Fixture.data("push-payload-message"), encoding: .utf8)!
        let inner = try! JSONSerialization.jsonObject(with: Fixture.data("push-payload-message")) as! [String: Any]
        let respondoString = String(data: try! JSONSerialization.data(withJSONObject: inner["respondo"]!), encoding: .utf8)!
        let payload = RespondoPushPayload.from(["respondo": respondoString])
        XCTAssertEqual(payload?.kind, .message)
        XCTAssertFalse(json.isEmpty)
    }
}
