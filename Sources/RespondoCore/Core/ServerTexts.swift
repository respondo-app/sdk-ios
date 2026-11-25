import Foundation

/// Системные карточки чата на языке КЛИЕНТА: «передано человеку», «вернулся к
/// ИИ», «чат завершён», ответ и отказ «Talk to a person». Сервер отдаёт их
/// текстами каталога на языке беседы (`handover_card_text`, `status_texts`,
/// `message` ответа `/escalate`); строки локали SDK — только фолбэк (офлайн,
/// старый бэкенд). UI-локаль приложения — не язык клиента: китайский клиент
/// английского приложения после китайского разговора получал английские
/// карточки.
struct StatusTexts: Equatable {
    var backToAI: String?
    var resolved: String?
    /// Блок оценки беседы (behavior.md §12) — пока закрытие просит оценку.
    var ratingQuestion: String?
    var ratingThanks: String?
    var ratingRemarkPrompt: String?
    var ratingRemarkPlaceholder: String?
    var ratingSend: String?
    var ratingEdit: String?

    /// Новые тексты поверх прежних: пустое поле известный текст не затирает.
    func merging(_ next: StatusTextsDTO?) -> StatusTexts {
        guard let next else { return self }
        return StatusTexts(
            backToAI: ServerTexts.nonBlank(next.backToAI) ?? backToAI,
            resolved: ServerTexts.nonBlank(next.resolved) ?? resolved,
            ratingQuestion: ServerTexts.nonBlank(next.ratingQuestion) ?? ratingQuestion,
            ratingThanks: ServerTexts.nonBlank(next.ratingThanks) ?? ratingThanks,
            ratingRemarkPrompt: ServerTexts.nonBlank(next.ratingRemarkPrompt) ?? ratingRemarkPrompt,
            ratingRemarkPlaceholder: ServerTexts.nonBlank(next.ratingRemarkPlaceholder) ?? ratingRemarkPlaceholder,
            ratingSend: ServerTexts.nonBlank(next.ratingSend) ?? ratingSend,
            ratingEdit: ServerTexts.nonBlank(next.ratingEdit) ?? ratingEdit
        )
    }
}

enum ServerTexts {
    /// Непустая строка с обрезанными пробелами или nil.
    static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Серверный текст на языке клиента, иначе строка SDK.
    static func or(_ server: String?, _ fallback: String) -> String {
        nonBlank(server) ?? fallback
    }

    /// Стандартное уведомление о передаче (`metadata.handover_canned`): оно само —
    /// карточка передачи, вторую рядом не рисуют.
    static func isCannedHandover(_ notice: MessageDTO?) -> Bool {
        notice?.metadata?.handoverCanned == true
    }

    /// Текст карточки «передано человеку» под ответом `/chat`: `handover_card_text`
    /// ответа (сервер заполняет его на каждой ветке с `human_handover`), иначе
    /// `metadata.handover_card_text` уведомления, иначе строка SDK.
    static func handoverCardText(response: String?, notice: MessageDTO?, fallback: String) -> String {
        nonBlank(response) ?? nonBlank(notice?.metadata?.handoverCardText) ?? fallback
    }
}

/// Отказ `/escalate`: `customerMessage` — текст для клиента на его языке
/// («передать человеку не вышло»), если сервер его дал.
struct EscalationRefused: Error, Equatable {
    let status: Int
    let customerMessage: String?
}
