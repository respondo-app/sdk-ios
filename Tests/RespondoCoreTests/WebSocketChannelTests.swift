import XCTest
@testable import RespondoCore

/// P2-5: разделяемое состояние `WebSocketChannel` сериализовано `NSLock` —
/// конкурентные send/close с нескольких потоков не приводят к гонке/крашу, а поток
/// корректно завершается ровно один раз.
final class WebSocketChannelTests: XCTestCase {
    func testConcurrentSendCloseIsSafe() async {
        // Несуществующий хост: соединение не установится, но send/close отрабатывают
        // по внутреннему состоянию — проверяем именно потокобезопасность доступа.
        let channel = WebSocketChannel(url: URL(string: "wss://respondo.invalid/ws")!)
        let stream = channel.connect()

        let drained = Task { for await _ in stream {} } // завершится, когда поток finish()

        DispatchQueue.concurrentPerform(iterations: 300) { i in
            if i % 4 == 0 {
                channel.close()
            } else {
                channel.send(Data("ping".utf8))
            }
        }
        channel.close() // идемпотентно

        // Поток обязан завершиться (без зависания/краша).
        await drained.value
    }
}
