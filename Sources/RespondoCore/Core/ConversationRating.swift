import Foundation

/// Шаг отзыва после оценки («Tell us more», модель Intercom; behavior.md §12):
/// open — оценка выбрана, отзыва нет: поле + Send; sent — отзыв сохранён:
/// строка + Edit, пока правка доступна; editing — нажали Edit. Пропуск — не
/// писать: оценка уже сохранена, кнопки Skip нет.
public enum RemarkStep: Equatable, Sendable {
    case open, sent, editing
}

/// Оценка беседы (CSAT 1–5) и отзыв — для ОДНОЙ беседы: продолжение беседы
/// не наследует ни запрос, ни оценку, ни отзыв (зеркало widget/src/rating-ask.ts).
public struct ConversationRating: Equatable, Sendable {
    public var conversationId: String?
    public var requested = false
    /// 1–5, 0 — не оценено.
    public var value = 0
    public var remark = ""
    public var remarkEditable = true
    public var remarkStep: RemarkStep = .open

    public static let none = ConversationRating()

    /// Блок виден под беседой на экране, когда она закрыта и её закрытие
    /// попросило оценку.
    public func visible(for cid: String?, closed: Bool) -> Bool {
        cid != nil && closed && requested && conversationId == cid
    }

    /// Шаг отзыва — после оценки, пока есть что показать или можно написать.
    public var remarkVisible: Bool { value > 0 && (!remark.isEmpty || remarkEditable) }

    private static func step(_ prev: RemarkStep, _ remark: String, _ editable: Bool) -> RemarkStep {
        if remark.isEmpty { return .open }
        return prev == .editing && editable ? .editing : .sent
    }

    /// Ответ сервера (resume, опрос). `value` nil — выбранная цифра остаётся;
    /// `remark` nil — отзыв остаётся. Нет запроса — нет ни оценки, ни отзыва.
    func next(_ cid: String?, requested: Bool, value: Int? = nil, remark: (text: String, editable: Bool)? = nil) -> ConversationRating {
        guard let cid else { return .none }
        let same = conversationId == cid
        let keep = same && requested
        var out = ConversationRating(conversationId: cid, requested: requested)
        out.value = !requested ? 0 : (value ?? (same ? self.value : 0))
        out.remark = !requested ? "" : (remark?.text ?? (keep ? self.remark : ""))
        out.remarkEditable = !requested ? true : (remark?.editable ?? (keep ? remarkEditable : true))
        out.remarkStep = Self.step(keep ? remarkStep : .open, out.remark, out.remarkEditable)
        return out
    }

    func edit() -> ConversationRating {
        guard remarkEditable, !remark.isEmpty else { return self }
        var out = self
        out.remarkStep = .editing
        return out
    }

    /// Поле правки покинули без изменений — назад к сохранённой строке; правка остаётся.
    func cancelEdit() -> ConversationRating {
        guard remarkStep == .editing, !remark.isEmpty else { return self }
        var out = self
        out.remarkStep = .sent
        return out
    }

    func saved(_ text: String, editable: Bool) -> ConversationRating {
        var out = self
        out.remark = text.trimmingCharacters(in: .whitespacesAndNewlines)
        out.remarkEditable = editable
        out.remarkStep = out.remark.isEmpty ? .open : .sent
        return out
    }

    func locked() -> ConversationRating {
        var out = self
        out.remarkEditable = false
        out.remarkStep = remark.isEmpty ? .open : .sent
        return out
    }
}

/// Отзыв из ответа сервера: `rating_remark*` resume/опроса.
func serverRemark(_ text: String?, _ editable: Bool?) -> (text: String, editable: Bool)? {
    if text == nil && editable == nil { return nil }
    return ((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines), editable ?? true)
}
