import Foundation

/// «Когда и где» оверлей-опроса в приложении — чистая часть (без UI и сети).
///
/// Зеркало веб-модуля `widget/src/survey-targeting.ts`, с экраном вместо адреса
/// страницы (контракт: `sdks/spec/api-surface.md`, backend
/// `outbound/survey_targeting.go`):
///   - правила экрана сравниваются с именем из `setCurrentScreen`: exact /
///     contains / starts_with / ends_with по ИЛИ, not_contains обязательны
///     всегда; нет правил — любой экран. Правила адреса страницы
///     (`survey_url_rules`) в приложении не действуют никогда;
///   - платформа (`survey_platform`): опрос «только сайт» в приложении не
///     показывается никогда (каталог его и не отдаёт — SDK шлёт platform=app);
///   - задержка — секунды на подходящем экране (после события, если оно задано);
///   - событие — `Respondo.track(<event>)` в этой сессии приложения: оно живёт
///     `eventTTL` (смена экрана его не забывает) и расходуется опросом, который
///     открыло.
/// Опрос, уже показанный на экране, остаётся при смене экрана, а опрос, у
/// которого есть доставка (его уже открывали этому посетителю, в т.ч. до
/// перезапуска приложения), открывается на любом экране без повторного
/// ожидания: правила решают, где посетителя ПРИГЛАШАЮТ, а не где начатый опрос
/// может продолжиться (`sdks/spec/api-surface.md` §3.3, как и в веб-виджете).
enum SurveyTargeting {
    /// Возможность, которую SDK объявляет каталогу (`features`) и WS-кадру identify.
    static let feature = "survey_targeting"
    /// Платформа, которой SDK называет себя каталогу и кадру identify.
    static let clientPlatform = "app"
    static let delayMax = 600
    /// Сколько событие-триггер может открыть опрос: полчаса, длина сессии.
    static let eventTTL: TimeInterval = 30 * 60

    /// События сессии, ещё способные открыть опрос (не старше `eventTTL`).
    static func freshEvents(_ events: [String: Date], now: Date) -> [String: Date] {
        events.filter { _, firedAt in firedAt <= now && now.timeIntervalSince(firedAt) <= eventTTL }
    }

    /// «Show on» (`survey_platform`) пускает опрос в приложение — всё, кроме `web`. Без учёта
    /// регистра и пробелов по краям, как `outbound.surveyPlatform` на сервере.
    static func showsInApps(_ platform: String?) -> Bool {
        platform?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "web"
    }

    /// Канон имени события — зеркало `outbound.NormalizeEventName`.
    static func normalizeEventName(_ name: String) -> String {
        name.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "_")
    }

    static func clampDelay(_ seconds: Int?) -> Int {
        guard let seconds, seconds > 0 else { return 0 }
        return min(delayMax, seconds)
    }

    /// Подходит ли экран под правила (пусто — любой экран; nil-экран подходит
    /// только под пустой набор и наборы из одних исключений).
    static func screenMatches(_ rules: [RespondoScreenRule], screen: String?) -> Bool {
        if rules.isEmpty { return true }
        let name = (screen ?? "").trimmingCharacters(in: .whitespaces)
        var positives = 0
        var hits = 0
        for rule in rules {
            let value = rule.value.trimmingCharacters(in: .whitespaces)
            if rule.op == "not_contains" {
                if !value.isEmpty, name.contains(value) { return false }
                continue
            }
            positives += 1
            guard !value.isEmpty, !name.isEmpty else { continue }
            let hit: Bool
            switch rule.op {
            case "exact": hit = name == value
            case "contains": hit = name.contains(value)
            case "starts_with": hit = name.hasPrefix(value)
            case "ends_with": hit = name.hasSuffix(value)
            default: hit = false
            }
            if hit { hits += 1 }
        }
        return positives == 0 || hits > 0
    }

    enum Readiness: Equatable {
        /// Показать сейчас.
        case ready
        /// На нужном экране, ждём задержку: спросить снова через `seconds`.
        case delay(seconds: TimeInterval)
        /// На нужном экране, ждём событие.
        case event
        /// Не тот экран.
        case elsewhere
    }

    /// Готов ли опрос открыться в момент `now`. `resumed` — у опроса есть
    /// доставка (его уже открывали посетителю): он открывается где угодно.
    static func readiness(
        _ targeting: RespondoSurveyTargeting,
        screen: String?,
        screenSince: Date,
        events: [String: Date],
        now: Date,
        resumed: Bool = false
    ) -> Readiness {
        guard targeting.showsInApps else { return .elsewhere }
        if resumed { return .ready }
        guard screenMatches(targeting.screenRules, screen: screen) else { return .elsewhere }
        var since = screenSince
        if let trigger = targeting.triggerEvent, !trigger.isEmpty {
            guard let firedAt = events[trigger] else { return .event }
            // Задержка — время на подходящем экране ПОСЛЕ события: от события,
            // если оно случилось здесь, от прихода на экран — если раньше.
            since = max(screenSince, firedAt)
        }
        let left = since.addingTimeInterval(TimeInterval(targeting.delaySeconds)).timeIntervalSince(now)
        return left > 0 ? .delay(seconds: left) : .ready
    }
}
