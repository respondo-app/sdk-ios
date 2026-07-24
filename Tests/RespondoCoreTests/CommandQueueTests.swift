import XCTest
@testable import RespondoCore

/// Проверяет FIFO-очередь команд, схлопывание identify и защиту от переполнения.
final class CommandQueueTests: XCTestCase {
    func testFifoOrderPreserved() {
        var queue = CommandQueue()
        queue.enqueue(.track(name: "a", properties: [:]))
        queue.enqueue(.open)
        queue.enqueue(.track(name: "b", properties: [:]))
        let replay = queue.replayOrder()
        XCTAssertEqual(replay.count, 3)
        if case .track(let name, _) = replay[0] { XCTAssertEqual(name, "a") } else { XCTFail() }
        if case .open = replay[1] {} else { XCTFail() }
        if case .track(let name, _) = replay[2] { XCTAssertEqual(name, "b") } else { XCTFail() }
    }

    func testIdentifyCollapsesToLast() {
        var queue = CommandQueue()
        queue.enqueue(.identify(RespondoIdentity(userId: "first")))
        queue.enqueue(.track(name: "evt", properties: [:]))
        queue.enqueue(.identify(RespondoIdentity(userId: "second")))
        let replay = queue.replayOrder()
        // identify должен остаться только один (последний), track сохраняется.
        let identifies = replay.compactMap { command -> String? in
            if case .identify(let identity) = command { return identity.userId }
            return nil
        }
        XCTAssertEqual(identifies, ["second"])
        XCTAssertEqual(replay.count, 2)
    }

    func testTrackNotCollapsed() {
        var queue = CommandQueue()
        queue.enqueue(.track(name: "x", properties: [:]))
        queue.enqueue(.track(name: "x", properties: [:]))
        XCTAssertEqual(queue.replayOrder().count, 2)
    }

    func testOverflowDropsOldestNonHandlePush() {
        var queue = CommandQueue()
        // Первым кладём handlePush — он не должен вытесняться.
        let payload = RespondoPushPayload(kind: .message, conversationId: "c", messageId: "m", title: nil, body: nil, raw: [:])
        queue.enqueue(.handlePush(payload))
        for index in 0..<CommandQueue.maxSize {
            queue.enqueue(.track(name: "n\(index)", properties: [:]))
        }
        // Размер не превышает максимум.
        XCTAssertLessThanOrEqual(queue.commands.count, CommandQueue.maxSize)
        // handlePush пережил переполнение.
        let hasHandlePush = queue.commands.contains { if case .handlePush = $0 { return true } else { return false } }
        XCTAssertTrue(hasHandlePush)
    }
}
