import Foundation

/// Обёртка над `URLSessionWebSocketTask`. Читает текстовые кадры в поток,
/// умеет отправлять кадры и закрываться. Pong на серверный Ping URLSession шлёт
/// автоматически (штатное поведение стека). Об открытии/закрытии сигналит колбэками.
/// Разделяемое состояние (`isClosed`/`continuation`/`task`/`session`) читается и
/// пишется из delegate-очереди, вызывающего потока и `onTermination` — доступ
/// сериализован `NSLock`; сетевые вызовы и `yield` выполняются вне замка.
final class WebSocketChannel: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<String>.Continuation?
    private var isClosed = false

    /// Вызывается, когда соединение фактически открылось (delegate didOpen).
    var onOpen: (@Sendable () -> Void)?

    init(url: URL) {
        self.url = url
        super.init()
    }

    /// Открывает соединение и возвращает поток входящих текстовых кадров.
    /// Поток завершается при закрытии/ошибке соединения.
    func connect() -> AsyncStream<String> {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)

        var request = URLRequest(url: url)
        request.setValue(SdkVersion.userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.webSocketTask(with: request)

        let stream = AsyncStream<String> { continuation in
            lock.withLock {
                self.session = session
                self.task = task
                self.continuation = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.close()
            }
        }
        task.resume()
        receiveLoop()
        return stream
    }

    /// Отправляет текстовый кадр. Ошибки логируются, соединение не рвётся вызывающим.
    func send(_ data: Data) {
        let currentTask: URLSessionWebSocketTask? = lock.withLock { isClosed ? nil : task }
        guard let currentTask else { return }
        let text = String(data: data, encoding: .utf8) ?? ""
        currentTask.send(.string(text)) { error in
            if let error {
                RespondoLog.debug("WS send failed: \(error.localizedDescription)")
            }
        }
    }

    func close() {
        let snapshot: (task: URLSessionWebSocketTask?, session: URLSession?, continuation: AsyncStream<String>.Continuation?)? = lock.withLock {
            guard !isClosed else { return nil }
            isClosed = true
            let captured = (task, session, continuation)
            task = nil
            session = nil
            continuation = nil
            return captured
        }
        guard let snapshot else { return }
        snapshot.task?.cancel(with: .goingAway, reason: nil)
        snapshot.session?.invalidateAndCancel()
        snapshot.continuation?.finish()
    }

    private func receiveLoop() {
        let currentTask: URLSessionWebSocketTask? = lock.withLock { task }
        guard let currentTask else { return }
        currentTask.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let continuation: AsyncStream<String>.Continuation? = self.lock.withLock { self.continuation }
                switch message {
                case .string(let text):
                    continuation?.yield(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        continuation?.yield(text)
                    }
                @unknown default:
                    break
                }
                let stillOpen = self.lock.withLock { !self.isClosed }
                if stillOpen { self.receiveLoop() }
            case .failure:
                // Обрыв соединения: завершаем поток — оркестратор решит про reconnect/фолбэк.
                let continuation: AsyncStream<String>.Continuation? = self.lock.withLock {
                    self.isClosed = true
                    let captured = self.continuation
                    self.continuation = nil
                    return captured
                }
                continuation?.finish()
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen?()
    }
}
