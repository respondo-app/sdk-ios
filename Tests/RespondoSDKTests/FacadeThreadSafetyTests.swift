import XCTest
import RespondoSDK

/// P1-2: публичные геттеры и потоки фасада читаются с ЛЮБОГО потока и не падают.
/// Раньше они форвардили в движок через `MainActor.assumeIsolated`, что аварийно
/// завершало процесс при вызове вне главного потока; теперь значения зеркалятся в
/// потокобезопасный Relay.
final class FacadeThreadSafetyTests: XCTestCase {
    func testObservablesReadableOffMainActor() {
        let done = expectation(description: "чтение вне главного потока завершилось без краха")
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread, "тело должно выполняться вне главного потока")
            // Синхронные геттеры.
            _ = Respondo.unreadCount
            _ = Respondo.chatState
            _ = Respondo.banners
            _ = Respondo.newsUnreadCount
            // Создание потоков.
            _ = Respondo.unreadCountStream
            _ = Respondo.chatStateStream
            _ = Respondo.bannersStream
            _ = Respondo.newsUnreadStream
            _ = Respondo.proactiveMessageStream
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testDefaultsBeforeInit() {
        XCTAssertEqual(Respondo.unreadCount, 0)
        XCTAssertEqual(Respondo.chatState, .closed)
        XCTAssertTrue(Respondo.banners.isEmpty)
        XCTAssertEqual(Respondo.newsUnreadCount, 0)
    }

    /// minor-2: `Respondo.delegate` читается и пишется из разных потоков; weak-ссылка
    /// сериализована отдельным замком в зеркале — конкурентный доступ не приводит к
    /// гонке на retain/release и не роняет процесс.
    func testDelegateConcurrentAccessIsSafe() {
        final class NoopDelegate: RespondoDelegate {}
        let delegate = NoopDelegate()
        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            if i % 2 == 0 {
                Respondo.delegate = delegate
            } else {
                _ = Respondo.delegate
            }
        }
        Respondo.delegate = nil
        XCTAssertNil(Respondo.delegate, "после сброса делегат читается как nil")
    }
}
