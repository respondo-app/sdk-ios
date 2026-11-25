import Foundation

/// Compact calendar/day labels used by the native message thread.
///
/// API `created_at` values are instants. The customer sees them in the device
/// timezone, so day separators follow the same local calendar as the host app.
public enum MessageDateFormatter {
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Localized “today” or a short date for older days.
    public static func dayLabel(
        _ date: Date,
        lang: String,
        strings: LocalizedStrings = .shared,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return strings.string("today", lang: lang).uppercased(with: Locale(identifier: lang))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: lang)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = LocalizedStrings.baseCode(lang) == "en" ? "MM/dd/yyyy" : "dd.MM.yyyy"
        return formatter.string(from: date)
    }

    /// Compact wall-clock label matching the Flutter/Android SDKs.
    public static func timeLabel(_ date: Date, lang: String, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: lang)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = LocalizedStrings.baseCode(lang) == "en" ? "h:mm a" : "HH:mm"
        return formatter.string(from: date)
    }
}
