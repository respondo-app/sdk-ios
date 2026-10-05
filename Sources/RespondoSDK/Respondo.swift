import Foundation
@_exported import RespondoCore

/// Публичный фасад Respondo iOS SDK. Тонкая обёртка над `RespondoEngine`:
/// все действия форвардятся на главный актор, наблюдаемые читаются из потокобезопасного
/// зеркала. Безопасен к вызову из любого потока (api-surface §9).
public enum Respondo {
    /// Потокобезопасное зеркало наблюдаемых движка (для синхронных геттеров и потоков
    /// с любого потока). Каждое значение зеркалится из потока движка ровно один раз.
    private final class Mirror: @unchecked Sendable {
        let unread = Relay<Int>(0)
        let state = Relay<RespondoChatState>(.closed)
        let banners = Relay<[RespondoBanner]>([])
        let newsUnread = Relay<Int>(0)
        let proactive = Relay<RespondoProactiveMessage?>(nil)
        private var subscribed = false

        // Делегат читается и пишется из ЛЮБОГО потока (публичный `Respondo.delegate`),
        // поэтому доступ к weak-ссылке сериализуется отдельным замком — иначе гонка
        // чтения/записи weak-ссылки (data race на retain/release).
        private let delegateLock = NSLock()
        private weak var _delegate: RespondoDelegate?
        var delegate: RespondoDelegate? {
            get { delegateLock.withLock { _delegate } }
            set { delegateLock.withLock { _delegate = newValue } }
        }

        /// Однократно подписывается на потоки движка и зеркалит их значения.
        @MainActor
        func startMirroring() {
            guard !subscribed else { return }
            subscribed = true
            let engine = RespondoEngine.shared
            let unreadStream = engine.unreadStream()
            let stateStream = engine.chatStateStream()
            let bannersStream = engine.bannersStream()
            let newsStream = engine.newsUnreadStream()
            let proactiveStream = engine.proactiveStream()
            Task { for await value in unreadStream { self.unread.send(value) } }
            Task { for await value in stateStream { self.state.send(value) } }
            Task { for await value in bannersStream { self.banners.send(value) } }
            Task { for await value in newsStream { self.newsUnread.send(value) } }
            Task { for await value in proactiveStream { self.proactive.send(value) } }
        }
    }

    private static let mirror = Mirror()

    // MARK: - Жизненный цикл

    public static func initialize(_ config: RespondoConfig, identity: RespondoIdentity? = nil) {
        onMain {
            installPresenterIfNeeded()
            installLifecycleMonitorIfNeeded()
            mirror.startMirroring()
            RespondoEngine.shared.initialize(config: config, identity: identity)
        }
    }

    public static func identify(_ identity: RespondoIdentity) {
        onMain { RespondoEngine.shared.identify(identity) }
    }

    public static func reset() {
        onMain { RespondoEngine.shared.reset() }
    }

    public static func track(_ name: String, properties: [String: Any] = [:]) {
        onMain { RespondoEngine.shared.track(name, properties: properties) }
    }

    public static func open() {
        onMain { RespondoEngine.shared.open() }
    }

    public static func close() {
        onMain { RespondoEngine.shared.close() }
    }

    public static func openNews() {
        onMain { RespondoEngine.shared.openNews() }
    }

    public static func openChecklists() {
        onMain { RespondoEngine.shared.openChecklists() }
    }

    /// Открыть оверлей-опрос сейчас, на любом экране — id опроса из редактора
    /// («Additional ways to share»). Правила экранов, задержка, событие и аудитория
    /// не проверяются; опрос должен быть запущен, и отвеченный повторно не
    /// показывается. Вызов до `initialize` буферизуется.
    public static func startSurvey(_ surveyId: String) {
        onMain { RespondoEngine.shared.startSurvey(surveyId) }
    }

    public static func setPushToken(_ token: String) {
        onMain { RespondoEngine.shared.setPushToken(token) }
    }

    public static func clearPushToken() {
        onMain { RespondoEngine.shared.clearPushToken() }
    }

    /// Обработать входящий пуш. Возвращает `true`, если это пуш Respondo (payload уже
    /// распознан на этапе `RespondoPushPayload.from`); фактическое открытие — асинхронно.
    @discardableResult
    public static func handlePush(_ payload: RespondoPushPayload) -> Bool {
        onMain { _ = RespondoEngine.shared.handlePush(payload) }
        return true
    }

    /// Удобный вход из APNs: парсит userInfo и обрабатывает. Возвращает false для чужого пуша.
    @discardableResult
    public static func handlePush(userInfo: [AnyHashable: Any]) -> Bool {
        guard let payload = RespondoPushPayload.from(userInfo) else { return false }
        return handlePush(payload)
    }

    public static func destroy() {
        onMain { RespondoEngine.shared.destroy() }
    }

    public static func setCurrentScreen(_ name: String?) {
        onMain { RespondoEngine.shared.setCurrentScreen(name) }
    }

    // MARK: - Наблюдаемые

    public static var unreadCount: Int { mirror.unread.current }

    public static var unreadCountStream: AsyncStream<Int> { mirror.unread.makeStream() }

    public static var chatState: RespondoChatState { mirror.state.current }

    public static var chatStateStream: AsyncStream<RespondoChatState> { mirror.state.makeStream() }

    // MARK: - Engagement (для host-приложения)

    /// Актуальные баннеры (host может показать свои поверхности).
    public static var banners: [RespondoBanner] { mirror.banners.current }

    public static var bannersStream: AsyncStream<[RespondoBanner]> { mirror.banners.makeStream() }

    /// Число непрочитанных новостей.
    public static var newsUnreadCount: Int { mirror.newsUnread.current }

    public static var newsUnreadStream: AsyncStream<Int> { mirror.newsUnread.makeStream() }

    /// Поток проактивных сообщений (nil — сброшено).
    public static var proactiveMessageStream: AsyncStream<RespondoProactiveMessage?> { mirror.proactive.makeStream() }

    // MARK: - Делегат

    public static var delegate: RespondoDelegate? {
        get { mirror.delegate }
        set {
            mirror.delegate = newValue
            onMain { RespondoEngine.shared.delegate = newValue }
        }
    }

    // MARK: - Приватное

    private static func onMain(_ block: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(block)
        } else {
            Task { @MainActor in block() }
        }
    }

    @MainActor
    private static func installPresenterIfNeeded() {
        #if canImport(UIKit)
        RespondoPresenterInstaller.installIfNeeded()
        #endif
    }

    @MainActor
    private static func installLifecycleMonitorIfNeeded() {
        #if canImport(UIKit)
        RespondoLifecycleMonitor.shared.installIfNeeded()
        #endif
    }
}
