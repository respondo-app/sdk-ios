import XCTest
@testable import RespondoCore

final class IdentityStoreTests: XCTestCase {
    func testVisitorIdIsStableAndPersisted() {
        let secure = InMemorySecureStore()
        let store = IdentityStore(secure: secure, prefs: InMemoryPreferences())
        let first = store.visitorId()
        let second = store.visitorId()
        XCTAssertEqual(first, second, "visitor_id должен быть стабилен в рамках сессии")
        XCTAssertTrue(first.hasPrefix("v_"), "формат visitor_id — v_...")
        // Новый стор поверх того же secure — тот же id.
        let store2 = IdentityStore(secure: secure, prefs: InMemoryPreferences())
        XCTAssertEqual(store2.visitorId(), first)
    }

    func testSessionTokenRoundTrip() {
        let store = IdentityStore(secure: InMemorySecureStore(), prefs: InMemoryPreferences())
        store.setSessionToken("tok-123", agentId: "agent", channelId: "chan")
        XCTAssertEqual(store.sessionToken(agentId: "agent", channelId: "chan"), "tok-123")
        store.setSessionToken(nil, agentId: "agent", channelId: "chan")
        XCTAssertNil(store.sessionToken(agentId: "agent", channelId: "chan"))
    }

    func testWipeAllRegeneratesVisitor() {
        let secure = InMemorySecureStore()
        let prefs = InMemoryPreferences()
        let store = IdentityStore(secure: secure, prefs: prefs)
        let original = store.visitorId()
        store.setCollectedEmail("a@b.com")
        store.setSessionToken("tok", agentId: "agent", channelId: nil)
        store.wipeAll()
        XCTAssertNil(store.collectedEmail())
        XCTAssertNil(store.sessionToken(agentId: "agent", channelId: nil))
        let regenerated = store.visitorId()
        XCTAssertNotEqual(regenerated, original, "после wipe генерится новый анонимный visitor_id")
    }

    func testStorageKeysUseWebPrefix() {
        XCTAssertEqual(StorageKeys.visitorId, "respondoai_visitor_id")
        XCTAssertEqual(StorageKeys.conversationBlob(agentId: "a", channelId: "c"), "respondoai_a_c")
        XCTAssertEqual(StorageKeys.conversationBlob(agentId: "", channelId: nil), "respondoai_ch_default")
        XCTAssertTrue(StorageKeys.visitorId.hasPrefix(StorageKeys.resetPrefix))
    }
}
