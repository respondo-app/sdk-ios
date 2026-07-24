import XCTest
@testable import RespondoCore

final class ThemeTests: XCTestCase {
    func testHexParsing() {
        let color = RespondoColor(hex: "#2563EB")
        XCTAssertNotNil(color)
        XCTAssertEqual(color?.rgb255.r, 0x25)
        XCTAssertEqual(color?.rgb255.g, 0x63)
        XCTAssertEqual(color?.rgb255.b, 0xEB)
        XCTAssertNil(RespondoColor(hex: "not-a-color"))
    }

    func testContrastThreshold() {
        // Тёмный синий бренд → белый текст.
        let dark = RespondoColor(hex: "#2563EB")!
        XCTAssertEqual(ThemeResolver.onPrimary(dark), ThemeResolver.white)
        // Очень светлый бренд → тёмный ink.
        let light = RespondoColor(hex: "#FDE68A")!
        XCTAssertEqual(ThemeResolver.onPrimary(light), ThemeResolver.inkDark)
    }

    func testDetents() {
        XCTAssertEqual(ThemeResolver.detents(for: .compact).initial, 0.55)
        XCTAssertEqual(ThemeResolver.detents(for: .default).initial, 0.75)
        XCTAssertEqual(ThemeResolver.detents(for: .large).initial, 0.92)
        XCTAssertEqual(ThemeResolver.detents(for: .large).max, 0.98)
    }

    func testDefaultsWhenConfigNil() {
        let theme = ThemeResolver.resolve(config: nil, override: nil)
        XCTAssertEqual(theme.primaryColor, ThemeResolver.defaultPrimary)
        XCTAssertEqual(theme.title, "Support")
        XCTAssertEqual(theme.cornerRadius, 12)
        XCTAssertFalse(theme.suggestedQuestionsEnabled)
        XCTAssertEqual(theme.initialDetentFraction, 0.75)
    }

    func testRadiusClampedTo28() {
        let dto = try! JSONDecoder().decode(WidgetConfigDTO.self, from: Data(#"{"border_radius": 999}"#.utf8))
        let theme = ThemeResolver.resolve(config: dto, override: nil)
        XCTAssertEqual(theme.cornerRadius, 28)
    }

    func testOverridePrecedence() {
        let config = Fixture.decode(WidgetConfigDTO.self, "config")
        let override = RespondoTheme(primaryColor: RespondoColor(hex: "#FF0000"), title: "Custom")
        let theme = ThemeResolver.resolve(config: config, override: override)
        XCTAssertEqual(theme.primaryColor, RespondoColor(hex: "#FF0000"))
        XCTAssertEqual(theme.title, "Custom")
        // Не переопределённые поля берутся из конфига.
        XCTAssertTrue(theme.suggestedQuestionsEnabled)
    }

    func testConfigFixtureResolves() {
        let config = Fixture.decode(WidgetConfigDTO.self, "config")
        let theme = ThemeResolver.resolve(config: config, override: nil)
        XCTAssertEqual(theme.primaryColor, RespondoColor(hex: "#2563eb"))
        XCTAssertEqual(theme.quickQuestions.count, 3)
        XCTAssertNotNil(theme.officeHours)
        XCTAssertEqual(theme.officeHours?.open, true)
    }
}
