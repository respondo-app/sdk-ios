import XCTest
@testable import RespondoSDK

/// P2-1: `Relay.makeStream()` выдаёт снимок текущего значения под тем же замком,
/// что и `send()`. Подписчик, созданный конкурентно с публикацией нового значения,
/// никогда не наблюдает «новое → устаревший снимок» (`[1, 0]` — подтверждено ревью
/// на прежней версии) и не залипает на устаревшем значении: он видит либо `[0, 1]`,
/// либо только `[1]`.
final class RelaySerializationTests: XCTestCase {
    func testMakeStreamSnapshotSerializedWithSend() async {
        // Много итераций: гонка регистрации подписчика и публикации проявляла баг
        // недетерминированно; на исправленной версии инвариант держится всегда.
        for _ in 0..<500 {
            let relay = Relay<Int>(0)

            // Подписка и публикация стартуют конкурентно.
            async let observed: [Int] = firstValues(relay.makeStream(), limit: 2, within: 3_000_000)
            async let published: Void = Task.detached { relay.send(1) }.value

            let values = await observed
            _ = await published

            XCTAssertFalse(values.isEmpty, "подписчик обязан получить хотя бы одно значение")
            if values.count >= 2 {
                XCTAssertLessThanOrEqual(
                    values[0], values[1],
                    "последовательность не должна убывать (запрещено [1, 0]): \(values)"
                )
            }
            XCTAssertEqual(values.last, 1, "финальное наблюдаемое значение — актуальное (1): \(values)")
        }
    }

    /// Собирает до `limit` значений из потока, но не дольше `within` наносекунд —
    /// поток `Relay` не финиширует, поэтому ветку «пришло меньше значений» ограничиваем
    /// по времени, отменяя сборщик.
    private func firstValues(_ stream: AsyncStream<Int>, limit: Int, within nanoseconds: UInt64) async -> [Int] {
        let collector = Task { () -> [Int] in
            var result: [Int] = []
            for await value in stream {
                result.append(value)
                if result.count >= limit { break }
            }
            return result
        }
        let deadline = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            collector.cancel()
        }
        let result = await collector.value
        deadline.cancel()
        return result
    }
}
