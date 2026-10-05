import Foundation
import XCTest
@testable import RespondoCore

/// Загрузка JSON-фикстур из ресурсов тест-таргета.
enum Fixture {
    static func data(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            fatalError("fixture not found: \(name)")
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) -> T {
        try! JSONDecoder().decode(T.self, from: data(name))
    }
}

/// Фейковый HTTP-движок: отдаёт заранее заданные ответы по совпадению пути URL.
final class FakeHttpEngine: HttpEngine, @unchecked Sendable {
    struct Stub {
        let status: Int
        let json: String
    }

    /// path-substring → Stub. Первое совпадение по подстроке пути выигрывает.
    var stubs: [(match: String, stub: Stub)] = []
    /// Записанные запросы (для проверок).
    private(set) var sentRequests: [HttpRequest] = []
    /// Искусственная задержка ответа (для проверки гонок инициализации).
    var responseDelay: TimeInterval = 0
    /// Хук перед ответом (после задержки): действие, которое успевает между
    /// ответом сервера и его обработкой (например, `reset()` посреди запроса).
    var beforeResponse: (@Sendable (HttpRequest) async -> Void)?
    private let lock = NSLock()

    func stub(pathContains: String, status: Int = 200, json: String) {
        stubs.append((pathContains, Stub(status: status, json: json)))
    }

    func send(_ request: HttpRequest) async throws -> HttpResponse {
        lock.withLock { sentRequests.append(request) }
        if responseDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(responseDelay * 1_000_000_000))
        }
        await beforeResponse?(request)
        let path = request.url.absoluteString
        for entry in stubs where path.contains(entry.match) {
            return HttpResponse(status: entry.stub.status, data: Data(entry.stub.json.utf8), headers: [:])
        }
        // По умолчанию — 204 (нечего восстанавливать / пустой ответ).
        return HttpResponse(status: 204, data: Data(), headers: [:])
    }

    func stream(_ request: HttpRequest) async throws -> (HttpResponse, AsyncThrowingStream<String, Error>) {
        let stream = AsyncThrowingStream<String, Error> { $0.finish() }
        return (HttpResponse(status: 200, data: Data(), headers: [:]), stream)
    }

    /// Был ли отправлен запрос с указанной подстрокой пути.
    func requestSent(pathContains: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sentRequests.contains { $0.url.absoluteString.contains(pathContains) }
    }
}

/// Фейковый хост беседы — фиксирует вызовы моста.
@MainActor
final class FakeConversationHost: ConversationHost {
    var panelOpen = false
    var identity = RespondoIdentity()
    var sessionToken: String?
    var visitorId = "v_test"
    var unread = 0
    var lastConversationId: String?
    var lastSessionToken: String?
    var escalated = false
    var urlHandledByHost = false

    var isPanelOpen: Bool { panelOpen }
    func ownership() -> OwnershipParams { OwnershipParams(sessionToken: sessionToken, userHash: identity.userHash, visitorId: visitorId) }
    func currentIdentity() -> RespondoIdentity { identity }
    func autoMetadata() -> [String: String] { ["platform": "ios"] }
    /// Сколько раз движку сказали «беседа закрыта, реалтайм отпусти».
    var closeCount = 0
    func conversationDidChange(id: String?, sessionToken: String?) {
        lastConversationId = id
        if let sessionToken {
            lastSessionToken = sessionToken
            // Тот же контракт, что у движка: свежий токен пишется в хранилище.
            self.sessionToken = sessionToken
        }
    }
    func conversationDidClose(sessionToken: String?) {
        closeCount += 1
        // Тот же контракт, что у движка: свежий ключ сохраняется, имеющийся не стирается.
        if let sessionToken, !sessionToken.isEmpty {
            lastSessionToken = sessionToken
            self.sessionToken = sessionToken
        }
    }
    func escalationDidChange(_ escalated: Bool) { self.escalated = escalated }
    func bumpUnread(by count: Int) { unread += count }
    func resetUnread() { unread = 0 }
    func languageDidChange(_ lang: String) {}
    func requestOpenURL(_ url: URL) -> Bool { urlHandledByHost }
}

/// Собирает связку контроллера с фейковым транспортом (реалтайм не стартуется).
@MainActor
func makeController(engine: FakeHttpEngine = FakeHttpEngine()) -> (ConversationController, FakeConversationHost, FakeHttpEngine) {
    let api = ApiClient(engine: engine, baseUrl: "https://api.respondo.ai")
    let realtime = RealtimeClient(apiClient: api, agentId: "7d3f9c2a-1e4b-4a6d-9f21-8c5b0e7a4d10")
    let prefs = InMemoryPreferences()
    let secure = InMemorySecureStore()
    let cache = ConversationCache(prefs: prefs, agentId: "agent", channelId: nil)
    let store = IdentityStore(secure: secure, prefs: prefs)
    // Тема из фикстуры конфига: suggested_questions_enabled = true.
    let theme = ThemeResolver.resolve(config: Fixture.decode(WidgetConfigDTO.self, "config"), override: nil)
    let controller = ConversationController(
        apiClient: api, realtime: realtime, cache: cache, identityStore: store,
        agentId: "7d3f9c2a-1e4b-4a6d-9f21-8c5b0e7a4d10", channelId: nil, theme: theme, lang: "ru"
    )
    let host = FakeConversationHost()
    controller.host = host
    return (controller, host, engine)
}

/// Фейковый хост engagement — фиксирует открытые URL и отдаёт параметры контакта.
@MainActor
final class FakeEngagementHost: EngagementHost {
    var params = EngagementParams(
        agentId: "7d3f9c2a-1e4b-4a6d-9f21-8c5b0e7a4d10",
        channelId: "c1a2b3d4-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
        conversationId: nil, visitorId: "v_test", email: nil, userId: nil, userHash: nil
    )
    var visitorId = "v_test"
    var lang = "en"
    var screen: String? = "home"
    var chatOpen = false
    var openedURLs: [URL] = []
    var handleURL = true

    func engagementParams() -> EngagementParams { params }
    var engagementVisitorId: String { visitorId }
    var engagementLang: String { lang }
    var engagementScreen: String? { screen }
    var isChatOpen: Bool { chatOpen }
    func requestOpenURL(_ url: URL) -> Bool { openedURLs.append(url); return handleURL }
}

/// Окружение engagement-теста. Держит `host` сильной ссылкой (контроллер ссылается
/// на него слабо), чтобы он не деаллоцировался на время теста.
@MainActor
final class EngagementEnv {
    let controller: EngagementController
    let host: FakeEngagementHost
    let engine: FakeHttpEngine

    init(engine: FakeHttpEngine, prefs: Preferences) {
        self.engine = engine
        let api = ApiClient(engine: engine, baseUrl: "https://api.respondo.ai")
        let host = FakeEngagementHost()
        self.host = host
        self.controller = EngagementController(apiClient: api, host: host, prefs: prefs)
    }
}

/// Собирает окружение engagement с фейковым транспортом и хостом. Общий `prefs`
/// — то же хранилище после перезапуска приложения.
@MainActor
func makeEngagement(engine: FakeHttpEngine = FakeHttpEngine(), prefs: Preferences = InMemoryPreferences()) -> EngagementEnv {
    EngagementEnv(engine: engine, prefs: prefs)
}

/// Ждёт выполнения условия с таймаутом (для асинхронных Task внутри контроллеров).
@MainActor
func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { XCTFail("timeout ожидания условия"); return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
