import Foundation

/// HTTP-метод.
enum HttpMethod: String {
    case get = "GET"
    case post = "POST"
    case delete = "DELETE"
}

/// Описание одного HTTP-запроса, независимое от движка.
struct HttpRequest {
    var method: HttpMethod
    var url: URL
    var headers: [String: String] = [:]
    var body: Data?
    /// Таймаут запроса в секундах (по умолчанию — из движка).
    var timeout: TimeInterval?
}

/// Ответ HTTP.
struct HttpResponse {
    let status: Int
    let data: Data
    let headers: [String: String]
}

/// Абстракция HTTP-движка. Боевая реализация — на URLSession; в тестах подменяется фейком.
protocol HttpEngine: Sendable {
    func send(_ request: HttpRequest) async throws -> HttpResponse
    /// Возвращает построчный поток тела ответа (для SSE `/stream`).
    func stream(_ request: HttpRequest) async throws -> (HttpResponse, AsyncThrowingStream<String, Error>)
}

/// Ошибки транспортного слоя.
enum TransportError: Error, Equatable {
    case invalidURL
    case timedOut
    case notConnected
    case cancelled
    /// Не-2xx ответ бэкенда с распознанным телом ошибки.
    case backend(status: Int, message: String?)
    case decoding(String)
    case unknown(String)
}

/// Боевая реализация на URLSession: обычные запросы (data),
/// стриминг (bytes) для SSE. WebSocket живёт отдельно в `WebSocketChannel`.
final class URLSessionHttpEngine: NSObject, HttpEngine, @unchecked Sendable {
    private let session: URLSession
    private let streamingSession: URLSession
    private let defaultTimeout: TimeInterval

    init(defaultTimeout: TimeInterval = 20) {
        self.defaultTimeout = defaultTimeout
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = defaultTimeout
        self.session = URLSession(configuration: configuration)

        // Отдельная сессия для SSE-стрима: heartbeat приходит раз в 15с, поэтому
        // таймаут ожидания данных берётся с большим запасом (не общий 20с, иначе
        // живой поток рвётся между heartbeat'ами), а общий таймаут ресурса снят.
        let streamingConfiguration = URLSessionConfiguration.default
        streamingConfiguration.waitsForConnectivity = false
        streamingConfiguration.timeoutIntervalForRequest = 120
        streamingConfiguration.timeoutIntervalForResource = TimeInterval(Int32.max)
        self.streamingSession = URLSession(configuration: streamingConfiguration)
        super.init()
    }

    func send(_ request: HttpRequest) async throws -> HttpResponse {
        let urlRequest = makeURLRequest(request, streaming: false)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            return try makeResponse(data: data, response: response)
        } catch let error as TransportError {
            throw error
        } catch let error as URLError {
            throw mapURLError(error)
        } catch {
            throw TransportError.unknown(String(describing: error))
        }
    }

    func stream(_ request: HttpRequest) async throws -> (HttpResponse, AsyncThrowingStream<String, Error>) {
        var urlRequest = makeURLRequest(request, streaming: true)
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await streamingSession.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.unknown("no http response")
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
            if let key = pair.key as? String, let value = pair.value as? String { acc[key] = value }
        }
        let meta = HttpResponse(status: http.statusCode, data: Data(), headers: headers)
        if !(200...299).contains(http.statusCode) {
            throw TransportError.backend(status: http.statusCode, message: nil)
        }
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch let error as URLError {
                    continuation.finish(throwing: mapURLError(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (meta, lines)
    }

    private func makeURLRequest(_ request: HttpRequest, streaming: Bool) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout ?? (streaming ? 3600 : defaultTimeout)
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        return urlRequest
    }

    private func makeResponse(data: Data, response: URLResponse) throws -> HttpResponse {
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.unknown("no http response")
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
            if let key = pair.key as? String, let value = pair.value as? String { acc[key] = value }
        }
        return HttpResponse(status: http.statusCode, data: data, headers: headers)
    }

    private func mapURLError(_ error: URLError) -> TransportError {
        switch error.code {
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .dataNotAllowed:
            return .notConnected
        default:
            return .unknown(error.localizedDescription)
        }
    }
}
