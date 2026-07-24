import Foundation

/// Сигнал SSE-потока для оркестратора.
enum SseSignal {
    case connected
    case event(RealtimeEvent)
    /// Бэкенд закрыл поток `event: timeout` — нужно переподключиться.
    case timeout
    /// Поток недоступен (503 / нет NATS) — деградация к поллингу.
    case unavailable
    /// Поток закрылся (сеть/ошибка).
    case closed
}

/// Читает SSE-поток событий беседы (`/chat/conversations/{id}/stream`).
/// Формат: строки `data: <JSON ConversationEvent>`, comment-heartbeat `: heartbeat`,
/// `event: timeout` → переподключение.
final class SseChannel: @unchecked Sendable {
    private let apiClient: ApiClient
    private var task: Task<Void, Never>?

    init(apiClient: ApiClient) {
        self.apiClient = apiClient
    }

    func connect(conversationId: String, ownership: OwnershipParams) -> AsyncStream<SseSignal> {
        AsyncStream<SseSignal> { continuation in
            let task = Task {
                do {
                    let (_, lines) = try await apiClient.streamEvents(conversationId: conversationId, ownership: ownership)
                    continuation.yield(.connected)
                    var pendingEvent: String?
                    for try await line in lines {
                        if Task.isCancelled { break }
                        if line.hasPrefix(":") {
                            continue // heartbeat/комментарий
                        }
                        if line.hasPrefix("event:") {
                            pendingEvent = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
                            continue
                        }
                        if line.hasPrefix("data:") {
                            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                            if pendingEvent == "timeout" {
                                continuation.yield(.timeout)
                                pendingEvent = nil
                                continue
                            }
                            if let event = RealtimeProtocol.decode(payload, subscribedConversationId: conversationId) {
                                continuation.yield(.event(event))
                            }
                            pendingEvent = nil
                        }
                    }
                    continuation.yield(.closed)
                    continuation.finish()
                } catch let error as TransportError {
                    if case .backend(let status, _) = error, status == 503 {
                        continuation.yield(.unavailable)
                    } else {
                        continuation.yield(.closed)
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.closed)
                    continuation.finish()
                }
            }
            self.task = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func close() {
        task?.cancel()
        task = nil
    }
}
