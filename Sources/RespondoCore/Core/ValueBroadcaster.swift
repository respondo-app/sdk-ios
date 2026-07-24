import Foundation

/// Мультиплексор значения: хранит текущее значение и раздаёт его нескольким
/// `AsyncStream`-подписчикам. Новый подписчик сразу получает текущее значение.
/// Работает на главном акторе — эмиссия на главном потоке (для обновления UI).
@MainActor
final class ValueBroadcaster<Value: Sendable> {
    private(set) var current: Value
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    init(_ initial: Value) {
        self.current = initial
    }

    /// Новый поток значений. Первым элементом идёт текущее значение.
    func makeStream() -> AsyncStream<Value> {
        AsyncStream<Value> { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    /// Публикует новое значение (только при изменении, если тип Equatable — см. перегрузку).
    func send(_ value: Value) {
        current = value
        for continuation in continuations.values {
            continuation.yield(value)
        }
    }

    func finishAll() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }
}

extension ValueBroadcaster where Value: Equatable {
    /// Публикует значение только если оно изменилось.
    func sendIfChanged(_ value: Value) {
        guard value != current else { return }
        send(value)
    }
}
