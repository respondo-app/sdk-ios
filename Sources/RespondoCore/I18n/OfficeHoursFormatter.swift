import Foundation

/// Форматирует строку доступности рабочих часов, повторяя веб-логику:
/// open=true → текст времени ответа (`reply_time`);
/// open=false → «Мы офлайн. Вернёмся {time}», где {time} = сегодня `HH:MM` /
/// завтра `HH:MM` / `<день недели> HH:MM` в локали устройства.
enum OfficeHoursFormatter {
    static func availabilityText(
        office: ResolvedOfficeHours,
        lang: String,
        strings: LocalizedStrings = .shared,
        now: Date = Date()
    ) -> String {
        if office.open {
            // Плашка «онлайн»: обещанное время ответа (серверный текст либо локализованный дефолт).
            if let replyTime = office.replyTime, !replyTime.isEmpty {
                return replyTime
            }
            return strings.string("replyTimeAsSoonAsPossible", lang: lang)
        }
        // Плашка «офлайн»: awayBack со временем возврата.
        let template = strings.string("awayBack", lang: lang)
        let timePart = office.nextOpenAt.map { formatReturnTime($0, lang: lang, strings: strings, now: now) } ?? ""
        return template.replacingOccurrences(of: "{time}", with: timePart).trimmingCharacters(in: .whitespaces)
    }

    static func formatReturnTime(
        _ date: Date,
        lang: String,
        strings: LocalizedStrings = .shared,
        now: Date = Date()
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: lang)

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: lang)
        timeFormatter.dateFormat = "HH:mm"
        let hhmm = timeFormatter.string(from: date)

        if calendar.isDate(date, inSameDayAs: now) {
            return hhmm
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "\(strings.string("tomorrow", lang: lang)) \(hhmm)"
        }
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale(identifier: lang)
        weekdayFormatter.dateFormat = "EEEE"
        return "\(weekdayFormatter.string(from: date)) \(hhmm)"
    }
}
