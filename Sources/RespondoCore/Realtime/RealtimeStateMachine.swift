import Foundation

/// Активный транспорт реалтайма.
enum RealtimeTransport: Equatable {
    case websocket
    case sse
    case polling
    /// Реалтайм не нужен (нет беседы и панель закрыта — только WS для оверлеев/адопции).
    case idle
}

/// Чистая стейт-машина каскада WS → SSE → REST-поллинг.
/// Не делает сети — только решает, какой транспорт должен быть активен и с каким интервалом
/// опрашивать при поллинге. Правила из `behavior.md` §3.
struct RealtimeStateMachine: Equatable {
    /// WS-соединение установлено и держится (аналог `wsActiveRef`).
    var wsHealthy = false
    /// SSE-поток установлен.
    var sseHealthy = false
    /// Есть активная беседа (subscribe возможен).
    var conversationPresent = false
    /// Панель чата открыта.
    var panelOpen = false
    /// Беседа эскалирована (учащённый поллинг).
    var escalated = false

    /// Желаемый транспорт по текущему состоянию.
    var desiredTransport: RealtimeTransport {
        // WS активен — он основной и покрывает всё (сообщения, оверлеи, адопцию кампаний).
        if wsHealthy { return .websocket }
        // Без WS живая доставка событий беседы возможна только при наличии беседы.
        guard conversationPresent else { return .idle }
        if sseHealthy { return .sse }
        return .polling
    }

    /// Интервал поллинга (сек). При открытой панели — 3с (2с при эскалации);
    /// при закрытой — фоновый статус-поллинг 10с.
    var pollingIntervalSeconds: Double {
        if panelOpen {
            return escalated ? 2.0 : 3.0
        }
        return 10.0
    }

    /// Задержка первого тика поллинга при открытой панели — 500мс.
    var firstPollDelaySeconds: Double {
        panelOpen ? 0.5 : pollingIntervalSeconds
    }

    /// Фиксированная задержка переподключения WS — 3с (без backoff), как в вебе.
    static let wsReconnectSeconds: Double = 3.0
    /// Heartbeat SSE — 15с; таймаут потока — 300с.
    static let sseHeartbeatSeconds: Double = 15.0
    static let sseTimeoutSeconds: Double = 300.0
}
