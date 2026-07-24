import Foundation

/// Потокобезопасный мультиплексор одного наблюдаемого значения: хранит текущее
/// значение под замком и раздаёт его нескольким `AsyncStream`-подписчикам.
/// Позволяет читать геттеры и создавать потоки с ЛЮБОГО потока без `MainActor`.
final class Relay<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    init(_ initial: Value) { self.value = initial }

    var current: Value { lock.withLock { value } }

    /// Новый поток значений. Первым элементом идёт текущее значение.
    func makeStream() -> AsyncStream<Value> {
        AsyncStream<Value> { continuation in
            let id = UUID()
            // Регистрация подписчика и выдача снимка — под одним замком, чтобы
            // сериализоваться с `send`: подписчик получит либо [снимок, новое],
            // либо только [новое], но никогда [новое, устаревший снимок]. Если
            // yield снимка вынести из-под замка, конкурентный send может доставить
            // новое значение раньше снимка — подписчик залипнет на устаревшем.
            lock.withLock {
                continuations[id] = continuation
                continuation.yield(value)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
            }
        }
    }

    /// Публикует новое значение всем подписчикам.
    func send(_ newValue: Value) {
        let targets: [AsyncStream<Value>.Continuation] = lock.withLock {
            value = newValue
            return Array(continuations.values)
        }
        for continuation in targets { continuation.yield(newValue) }
    }
}
