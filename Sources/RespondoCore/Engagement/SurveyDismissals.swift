import Foundation

/// Доставки опросов, которые посетитель закрыл, — в хранилище SDK, как
/// `respondo_survey_seen_*` веб-виджета. Без этого опрос с доставкой (он
/// продолжается на любом экране) после перезапуска возвращался на первом же
/// экране, хотя его закрыли (sdks/spec/api-surface.md §3.3). Хранятся последние
/// `limit`; `reset()` стирает их вместе с остальным хранилищем (`StorageKeys.resetPrefix`).
@MainActor
final class SurveyDismissals {
    private static let limit = 100
    private let prefs: Preferences
    private var ids: [String]

    init(prefs: Preferences) {
        self.prefs = prefs
        if let data = prefs.data(forKey: StorageKeys.surveyDismissed),
           let stored = try? JSONDecoder().decode([String].self, from: data) {
            ids = stored
        } else {
            ids = []
        }
    }

    func contains(_ deliveryId: String) -> Bool {
        !deliveryId.isEmpty && ids.contains(deliveryId)
    }

    func add(_ deliveryId: String) {
        guard !deliveryId.isEmpty else { return }
        ids.removeAll { $0 == deliveryId }
        ids.append(deliveryId)
        if ids.count > Self.limit { ids.removeFirst(ids.count - Self.limit) }
        save()
    }

    func remove(_ deliveryId: String) {
        guard ids.contains(deliveryId) else { return }
        ids.removeAll { $0 == deliveryId }
        save()
    }

    private func save() {
        if ids.isEmpty {
            prefs.removeValue(forKey: StorageKeys.surveyDismissed)
        } else if let data = try? JSONEncoder().encode(ids) {
            prefs.set(data, forKey: StorageKeys.surveyDismissed)
        }
    }
}
