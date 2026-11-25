import XCTest
@testable import RespondoCore

/// Оценка беседы и отзыв (behavior.md §12, test-plan «Оценка беседы и отзыв»):
/// блок только под закрытой беседой, чьё закрытие просило оценку; отзыв —
/// одна запись и одна правка; тело POST несёт `client=ios`.
@MainActor
final class ConversationRatingTests: XCTestCase {
    func testVisibleOnlyForAskedClose() {
        let asked = ConversationRating.none.next("c1", requested: true)
        XCTAssertTrue(asked.visible(for: "c1", closed: true))
        XCTAssertFalse(asked.visible(for: "c1", closed: false))
        XCTAssertFalse(asked.visible(for: "c2", closed: true))
        XCTAssertFalse(ConversationRating.none.next("c1", requested: false).visible(for: "c1", closed: true))
    }

    func testRemarkStepsOneEdit() {
        var r = ConversationRating.none.next("c1", requested: true)
        r.value = 2
        XCTAssertEqual(r.remarkStep, .open)
        XCTAssertTrue(r.remarkVisible)
        r = r.saved("  slow ", editable: true)
        XCTAssertEqual(r.remark, "slow")
        XCTAssertEqual(r.remarkStep, .sent)
        r = r.edit()
        XCTAssertEqual(r.remarkStep, .editing)
        // Ушёл из поля без изменений — назад к строке, правка цела.
        r = r.cancelEdit()
        XCTAssertEqual(r.remarkStep, .sent)
        XCTAssertTrue(r.remarkEditable)
        XCTAssertEqual(r.cancelEdit(), r)
        r = r.edit()
        // Опрос во время правки её не сбивает.
        r = r.next("c1", requested: true, value: 2, remark: ("slow", true))
        XCTAssertEqual(r.remarkStep, .editing)
        r = r.saved("slow, fixed", editable: false)
        XCTAssertEqual(r.edit(), r)
        XCTAssertFalse(r.locked().remarkEditable)
    }

    func testNewCloseStartsEmpty() {
        let rated = ConversationRating.none.next("c1", requested: true, value: 2, remark: ("waited", false))
        XCTAssertEqual(rated.remarkStep, .sent)
        XCTAssertEqual(rated.next("c1", requested: false).remark, "")
        XCTAssertEqual(rated.next("c2", requested: true).value, 0)
        XCTAssertNil(serverRemark(nil, nil))
    }

    func testRateAndRemarkPostClientIos() async throws {
        let engine = FakeHttpEngine()
        engine.stub(pathContains: "/rating", json: #"{"ok":true,"score":2,"remark":"too slow","remark_editable":false}"#)
        let (controller, _, _) = makeController(engine: engine)
        let resume = try JSONDecoder().decode(ResumeResponseDTO.self, from: Data(#"""
        {"conversation_id":"c1","session_token":"tok","status":"resolved","rating_requested":true,
         "rating_remark":"","rating_remark_editable":true,
         "status_texts":{"rating_question":"Wie war Ihre Erfahrung?"},"messages":[]}
        """#.utf8))
        controller.bootstrap(cacheBlob: nil, resume: resume)
        XCTAssertTrue(controller.ratingVisible)
        XCTAssertEqual(controller.ratingLabel("ratingQuestion"), "Wie war Ihre Erfahrung?")

        let ok = await controller.sendRemark("too slow")
        XCTAssertFalse(ok, "без оценки отзыв не отправляется")
        await controller.rate(2)
        XCTAssertEqual(controller.rating.value, 2)
        let sent = await controller.sendRemark("  too slow ")
        XCTAssertTrue(sent)
        XCTAssertEqual(controller.rating.remark, "too slow")
        XCTAssertFalse(controller.rating.remarkEditable)

        let bodies = engine.sentRequests.filter { $0.url.absoluteString.contains("/rating") }.compactMap { $0.body }
        let last = try XCTUnwrap(bodies.last)
        let decoded = try JSONDecoder().decode(RatingRequestDTO.self, from: last)
        XCTAssertEqual(decoded, RatingRequestDTO(score: 2, remark: "too slow", client: "ios"))
    }
}
