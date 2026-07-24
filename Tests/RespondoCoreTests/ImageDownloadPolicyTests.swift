import XCTest
@testable import RespondoCore

/// P2-3: политика загрузки изображений — потолок размера и cost-лимит кэша.
final class ImageDownloadPolicyTests: XCTestCase {
    func testRejectsEmpty() {
        XCTAssertFalse(ImageDownloadPolicy.isAcceptable(byteCount: 0))
        XCTAssertFalse(ImageDownloadPolicy.isAcceptable(byteCount: -1))
    }

    func testAcceptsWithinLimit() {
        XCTAssertTrue(ImageDownloadPolicy.isAcceptable(byteCount: 1))
        XCTAssertTrue(ImageDownloadPolicy.isAcceptable(byteCount: ImageDownloadPolicy.maxBytes))
    }

    func testRejectsOverLimit() {
        XCTAssertFalse(ImageDownloadPolicy.isAcceptable(byteCount: ImageDownloadPolicy.maxBytes + 1))
    }

    func testLimitsAreSane() {
        XCTAssertEqual(ImageDownloadPolicy.maxBytes, 10 * 1024 * 1024, "потолок ответа 10 МБ")
        XCTAssertGreaterThan(ImageDownloadPolicy.cacheCostLimit, ImageDownloadPolicy.maxBytes)
    }
}
