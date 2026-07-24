import Foundation

/// Строит абсолютные URL REST/WS/SSE из baseUrl конфига.
/// Дефолт baseUrl → https://api.respondo.ai, WS-хост выводится по правилу веба
/// (`detectWsOrigin`): прод api.respondo.ai → wss.respondo.ai; иной host → тот же host со схемой wss/ws.
struct Endpoints {
    static let defaultBaseURL = "https://api.respondo.ai"

    let apiBase: URL
    let wsBase: URL

    init(baseUrl: String?) {
        let raw = (baseUrl?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? Endpoints.defaultBaseURL
        let normalized = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        self.apiBase = URL(string: normalized) ?? URL(string: Endpoints.defaultBaseURL)!
        self.wsBase = Endpoints.deriveWsBase(from: self.apiBase)
    }

    private static func deriveWsBase(from api: URL) -> URL {
        guard var components = URLComponents(url: api, resolvingAgainstBaseURL: false),
              let host = components.host else {
            return URL(string: "wss://wss.respondo.ai")!
        }
        let secure = (components.scheme ?? "https") == "https"
        // Прод: api.respondo.ai → wss.respondo.ai.
        if host == "api.respondo.ai" {
            return URL(string: "wss://wss.respondo.ai")!
        }
        components.scheme = secure ? "wss" : "ws"
        return components.url ?? URL(string: "wss://wss.respondo.ai")!
    }

    /// Собирает URL относительно API-базы с query-параметрами (пустые значения отбрасываются).
    func api(_ path: String, query: [String: String?] = [:]) -> URL {
        var components = URLComponents(url: apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let items = query.compactMap { key, value -> URLQueryItem? in
            guard let value, !value.isEmpty else { return nil }
            return URLQueryItem(name: key, value: value)
        }.sorted { $0.name < $1.name }
        if !items.isEmpty { components.queryItems = items }
        return components.url!
    }

    /// URL WebSocket подключения виджета.
    func websocket(agentId: String) -> URL {
        var components = URLComponents(url: wsBase.appendingPathComponent("/api/v1/chat/ws"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "agent_id", value: agentId)]
        return components.url!
    }
}
