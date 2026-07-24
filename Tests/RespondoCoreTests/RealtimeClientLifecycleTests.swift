import XCTest
@testable import RespondoCore

/// P2-2: терминальная защёлка `stopped` в `RealtimeClient`.
/// Если `tearDownRuntime` вызвал `stop()` в окне, пока `performInit` ещё не дошёл до
/// `realtime.start()`, повторный `start()` НЕ должен воскресить транспорт (WS не
/// поднимается). Движок создаёт новый клиент на каждый init/reset, поэтому защёлка
/// одноразовая и безопасная.
final class RealtimeClientLifecycleTests: XCTestCase {
    private let agentId = "7d3f9c2a-1e4b-4a6d-9f21-8c5b0e7a4d10"
    private let conversationId = "c1a2b3d4-5e6f-4a7b-8c9d-0e1f2a3b4c5d"

    private func makeClient() -> RealtimeClient {
        let api = ApiClient(engine: FakeHttpEngine(), baseUrl: "https://api.respondo.ai")
        return RealtimeClient(apiClient: api, agentId: agentId)
    }

    func testStartAfterStopDoesNotResurrect() async {
        let client = makeClient()
        await client.setConversation(id: conversationId, ownership: OwnershipParams(visitorId: "v_test"))
        await client.stop()   // teardown в окне до start
        await client.start()  // не должен поднимать транспорт
        let running = await client.isRunning
        XCTAssertFalse(running, "после stop() клиент терминален — start() не поднимает транспорт")
    }

    func testFreshClientStartsThenStops() async {
        let client = makeClient()
        await client.start()
        let running = await client.isRunning
        XCTAssertTrue(running, "свежий клиент стартует нормально")
        await client.stop()
        let stopped = await client.isRunning
        XCTAssertFalse(stopped, "stop() гасит клиент")
    }

    /// P2-2: lifecycle-хуки (kадры фон/форграунд) прокидываются в клиент и меняют
    /// фоновое состояние. Форграунд-хук снимает пометку фона.
    func testBackgroundForegroundTogglesState() async {
        let client = makeClient()
        await client.notifyBackground()
        let backgrounded = await client.isBackgrounded
        XCTAssertTrue(backgrounded, "фон помечен")
        await client.notifyForeground()
        let foregrounded = await client.isBackgrounded
        XCTAssertFalse(foregrounded, "возврат на передний план снимает пометку фона")
    }
}
