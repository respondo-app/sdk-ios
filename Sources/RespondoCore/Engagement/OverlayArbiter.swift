import Foundation

/// Решение арбитра: какой единственный оверлей показать сейчас.
public enum OverlayDecision: Equatable {
    case none
    case survey(RespondoSurvey)
    case banner(RespondoBanner)
}

/// Вход арбитра оверлеев.
struct OverlayArbiterInput: Equatable {
    var surveys: [RespondoSurvey]
    var banners: [RespondoBanner]
    /// delivery_id уже показанных/закрытых/отвеченных элементов.
    var dismissed: Set<String>
    /// Открыт лайтбокс изображения — оверлеи подавляются.
    var lightboxOpen: Bool
    /// В композере есть набранный текст — оверлеи подавляются.
    var composerHasText: Bool
}

/// Чистый арбитр оверлеев: один за раз, приоритет survey > banner,
/// подавление при открытом лайтбоксе или непустом композере.
enum OverlayArbiter {
    static func decide(_ input: OverlayArbiterInput) -> OverlayDecision {
        guard !input.lightboxOpen, !input.composerHasText else { return .none }
        if let survey = input.surveys.first(where: { !input.dismissed.contains($0.deliveryId) }) {
            return .survey(survey)
        }
        if let banner = input.banners.first(where: { !input.dismissed.contains($0.deliveryId) }) {
            return .banner(banner)
        }
        return .none
    }
}
