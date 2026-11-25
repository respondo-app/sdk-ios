import Foundation
import XCTest
@testable import RespondoCore

final class MessageDateFormatterTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testDayKeyAndCompactClockUseCalendarAndLocale() {
        let date = ISO8601DateFormatter().date(from: "2026-10-07T21:30:00Z")!
        XCTAssertEqual(MessageDateFormatter.dayKey(date, calendar: utc), "2026-10-07")
        XCTAssertEqual(MessageDateFormatter.timeLabel(date, lang: "en", calendar: utc), "9:30 PM")
        XCTAssertEqual(MessageDateFormatter.timeLabel(date, lang: "ru", calendar: utc), "21:30")
    }

    func testDayLabelUsesTodayOnlyForTheSameLocalDay() {
        let date = ISO8601DateFormatter().date(from: "2026-10-07T21:30:00Z")!
        let previous = date.addingTimeInterval(-24 * 60 * 60)
        XCTAssertEqual(MessageDateFormatter.dayLabel(date, lang: "en", now: date, calendar: utc), "TODAY")
        XCTAssertEqual(MessageDateFormatter.dayLabel(date, lang: "en", now: previous, calendar: utc), "10/07/2026")
    }
}
