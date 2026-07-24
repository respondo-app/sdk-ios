import XCTest
@testable import RespondoCore

final class I18nTests: XCTestCase {
    func testBundledStringsLoadForAllLocales() {
        let strings = LocalizedStrings.shared
        for locale in LocalizedStrings.supportedLocales {
            let value = strings.string("inputPlaceholder", lang: locale)
            XCTAssertFalse(value.isEmpty)
            XCTAssertNotEqual(value, "inputPlaceholder", "ключ должен резолвиться для \(locale)")
        }
    }

    func testRussianStrings() {
        let strings = LocalizedStrings.shared
        XCTAssertEqual(strings.string("waitingForAgent", lang: "ru"), "Ожидание оператора")
        XCTAssertEqual(strings.string("continueWithAI", lang: "ru"), "Вернуть в AI")
    }

    func testFallbackToEnglish() {
        let strings = LocalizedStrings.shared
        // Неизвестная локаль → английский.
        XCTAssertEqual(strings.string("agentIsHere", lang: "zz"), strings.string("agentIsHere", lang: "en"))
    }

    func testNewUiStringsFromExtraFile() {
        let strings = LocalizedStrings.shared
        // Ключ из ui-strings-new.json.
        XCTAssertEqual(strings.string("send", lang: "en"), "Send")
        XCTAssertFalse(strings.string("networkError", lang: "ru").isEmpty)
    }

    func testDetectFromText() {
        XCTAssertEqual(LocalizedStrings.detectFromText("Здравствуйте"), "ru")
        XCTAssertEqual(LocalizedStrings.detectFromText("Привіт, як справи"), "uk")
        XCTAssertNil(LocalizedStrings.detectFromText("Hello there"))
    }

    func testNormalize() {
        XCTAssertEqual(LocalizedStrings.normalize("ru-RU"), "ru")
        XCTAssertEqual(LocalizedStrings.normalize("en_US"), "en")
        XCTAssertEqual(LocalizedStrings.normalize("xx"), "en")
        XCTAssertEqual(LocalizedStrings.normalize(nil), "en")
    }

    func testOfficeHoursOnline() {
        let office = ResolvedOfficeHours(open: true, replyTime: "Отвечаем быстро", timezone: "Europe/Moscow", nextOpenAt: nil, nextCloseAt: nil)
        let text = OfficeHoursFormatter.availabilityText(office: office, lang: "ru")
        XCTAssertEqual(text, "Отвечаем быстро")
    }

    func testOfficeHoursOfflineFormatsReturnTime() {
        let now = Date()
        let inTwoHours = now.addingTimeInterval(2 * 3600)
        let office = ResolvedOfficeHours(open: false, replyTime: nil, timezone: "UTC", nextOpenAt: inTwoHours, nextCloseAt: nil)
        let text = OfficeHoursFormatter.availabilityText(office: office, lang: "ru", now: now)
        XCTAssertTrue(text.contains("Мы офлайн"), "офлайн-плашка: \(text)")
    }
}
