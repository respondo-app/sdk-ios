import XCTest
@testable import RespondoCore

/// Проверяет каскад выбора транспорта WS → SSE → поллинг и интервалы поллинга.
final class RealtimeStateMachineTests: XCTestCase {
    func testWsHealthyPrefersWebsocket() {
        var machine = RealtimeStateMachine()
        machine.wsHealthy = true
        machine.conversationPresent = true
        XCTAssertEqual(machine.desiredTransport, .websocket)
    }

    func testFallsBackToSseWhenWsDown() {
        var machine = RealtimeStateMachine()
        machine.wsHealthy = false
        machine.sseHealthy = true
        machine.conversationPresent = true
        XCTAssertEqual(machine.desiredTransport, .sse)
    }

    func testFallsBackToPollingWhenSseUnavailable() {
        var machine = RealtimeStateMachine()
        machine.wsHealthy = false
        machine.sseHealthy = false
        machine.conversationPresent = true
        XCTAssertEqual(machine.desiredTransport, .polling)
    }

    func testIdleWithoutConversation() {
        var machine = RealtimeStateMachine()
        machine.wsHealthy = false
        machine.conversationPresent = false
        XCTAssertEqual(machine.desiredTransport, .idle)
    }

    func testPollingIntervals() {
        var machine = RealtimeStateMachine()
        machine.panelOpen = true
        machine.escalated = false
        XCTAssertEqual(machine.pollingIntervalSeconds, 3.0)
        machine.escalated = true
        XCTAssertEqual(machine.pollingIntervalSeconds, 2.0)
        machine.panelOpen = false
        XCTAssertEqual(machine.pollingIntervalSeconds, 10.0)
    }

    func testFirstPollDelay() {
        var machine = RealtimeStateMachine()
        machine.panelOpen = true
        XCTAssertEqual(machine.firstPollDelaySeconds, 0.5)
        machine.panelOpen = false
        XCTAssertEqual(machine.firstPollDelaySeconds, 10.0)
    }

    func testConstants() {
        XCTAssertEqual(RealtimeStateMachine.wsReconnectSeconds, 3.0)
        XCTAssertEqual(RealtimeStateMachine.sseHeartbeatSeconds, 15.0)
        XCTAssertEqual(RealtimeStateMachine.sseTimeoutSeconds, 300.0)
    }
}
