import Foundation

/// Правило сессии приложения — как у Intercom: «if an app is backgrounded for
/// more than 20 seconds and then resumed we treat that as a new session»
/// (ответ поддержки Intercom о мобильных SDK); Mobile SDK FAQ: открытия ближе
/// 20 секунд друг к другу не считаются.
///
/// SDK сообщает сессию (`POST /widget/app-session`):
///  1. на запуске — `Respondo.initialize`, не дожидаясь конфига (`launched()`),
///     ОДИН раз на процесс: повторный `initialize` (после `destroy`, смена
///     конфига) — не новое открытие, сколько бы времени ни прошло. Только при
///     настоящем открытии: процесс, поднятый в фоне (silent push, background
///     fetch), сообщает запуск при первом `willEnterForeground` /
///     `didBecomeActive` (движок, `pendingLaunch`);
///  2. на возврате из фона (`cameForeground()`) — только если приложение пробыло
///     в фоне не меньше 20 с: время считается от ПЕРВОГО ухода в фон этого
///     эпизода (`wentBackground()`, повторный сигнал фона момент не сдвигает) до
///     `willEnterForeground`; возврат без замеченного фона сессией не считается;
///  3. сразу, без порога, когда `identify()` переключает на другого
///     идентифицированного контакта (`contactChanged()`): у Intercom счётчик
///     растёт при первой регистрации пользователя.
/// На `reset()` сессия не сообщается. Сервер держит своё правило по строке
/// (контакт × приложение × платформа) — отметки ближе 20 секунд одна сессия, —
/// поэтому лишний отчёт счётчик не раздувает.
///
/// Время прошлого отчёта, ухода в фон и отметка «запуск уже сообщён» — общие на
/// процесс (`shared` у боевого движка; тестовый движок без инъекции получает
/// свой трекер).
final class AppSessionTracker: @unchecked Sendable {
    /// Трекер боевого движка — один на процесс.
    static let shared = AppSessionTracker()

    /// Порог Intercom: минимальное время в фоне (и между отчётами о запуске).
    static let minGap: TimeInterval = 20

    /// Фича WS-кадра `identify`: SDK сам сообщает сессии приложения
    /// (`/widget/app-session`), и сервер не считает его identify активностью.
    static let wsFeature = "app_sessions"

    private let clock: () -> Date
    private let lock = NSLock()
    private var lastReportedAt: Date?
    private var backgroundAt: Date?
    /// Запуск этого процесса уже решён (сообщён или влит в отчёт ближе 20 с):
    /// повторный `initialize` запуском не считается.
    private var launchDecided = false

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Момент последнего отчёта (nil — отчётов ещё не было).
    var lastReported: Date? {
        lock.lock(); defer { lock.unlock() }
        return lastReportedAt
    }

    /// Запуск этого процесса уже решён — следующий `launched()` вернёт false.
    var launchAlreadyDecided: Bool {
        lock.lock(); defer { lock.unlock() }
        return launchDecided
    }

    /// Запуск (настоящее открытие на переднем плане): true — сообщить сессию (и
    /// она отмечена). Один раз на процесс: после первого вызова всегда false.
    /// Первый вызов тоже отбрасывается, если отчёт был меньше 20 с назад
    /// (вход пользователя прямо перед открытием — та же сессия). Отметка фона
    /// снимается всегда (как у Android): открытие — это и есть возврат, и
    /// устаревший уход в фон не должен дать сессию на следующем возврате.
    func launched() -> Bool {
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        backgroundAt = nil
        if launchDecided { return false }
        launchDecided = true
        if let last = lastReportedAt, now.timeIntervalSince(last) < Self.minGap { return false }
        lastReportedAt = now
        return true
    }

    /// Сбрасывает отметку «запуск сообщён» (тесты, которым нужен общий трекер).
    func resetLaunchForTesting() {
        lock.lock(); defer { lock.unlock() }
        launchDecided = false
        lastReportedAt = nil
        backgroundAt = nil
    }

    /// Приложение ушло в фон: запоминается ПЕРВЫЙ момент ухода этого эпизода —
    /// повторный сигнал фона (сцены, двойные уведомления) его не сдвигает;
    /// снимает отметку возврат (`cameForeground`) или `discardBackground`.
    func wentBackground() {
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        if backgroundAt == nil { backgroundAt = now }
    }

    /// Отметка фона снимается без сессии. Правило: событие переднего плана
    /// всегда решает отметку — её либо потребляет `cameForeground()`, либо
    /// снимает этот вызов (возврат, при котором трекер не спрашивали: движок
    /// ещё не инициализирован, идёт init, после `destroy`, нет канала,
    /// отложенный запуск).
    func discardBackground() {
        lock.lock(); defer { lock.unlock() }
        backgroundAt = nil
    }

    /// Возврат на передний план: true — сессия (фон был и длился ≥ 20 с; она
    /// отмечена). Отметка фона снимается в любом случае.
    func cameForeground() -> Bool {
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        guard let since = backgroundAt else { return false }
        backgroundAt = nil
        guard now.timeIntervalSince(since) >= Self.minGap else { return false }
        lastReportedAt = now
        return true
    }

    /// Смена контакта на другого известного: сессия сразу, без порога.
    func contactChanged() -> Bool {
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        lastReportedAt = now
        return true
    }
}

/// Дедуп `POST /widget/identify` — как `lastIdentifySent` веб-виджета: то же
/// тело второй раз не отправляется; неудачная отправка снимает отметку, и
/// следующий `identify()` с теми же данными уйдёт снова.
struct IdentitySync {
    /// Последнее отправленное тело (ключи отсортированы — сравнение стабильно).
    private(set) var lastSent: Data?

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// true — тело новое: отправлять (и оно отмечено отправленным).
    mutating func claim(_ body: IdentifyRequestDTO) -> Bool {
        guard let data = try? Self.encoder.encode(body) else { return false }
        if data == lastSent { return false }
        lastSent = data
        return true
    }

    /// Отправка не удалась: отметка снимается, если с тех пор не ушло другое тело.
    mutating func failed(_ body: IdentifyRequestDTO) {
        guard let data = try? Self.encoder.encode(body), data == lastSent else { return }
        lastSent = nil
    }
}
