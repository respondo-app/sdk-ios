#if canImport(UIKit)
import SwiftUI
import RespondoCore

extension RespondoColor {
    /// Конвертация в SwiftUI Color (непрозрачная альфа).
    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue)
    }
}

/// Нейтральные токены светлой темы (веб не имеет тёмной темы — SDK всегда светлый).
enum RespondoPalette {
    static let background = Color.white
    static let assistantBubble = Color(red: 0xF3 / 255, green: 0xF4 / 255, blue: 0xF6 / 255)
    static let ink = Color(red: 0x1F / 255, green: 0x29 / 255, blue: 0x37 / 255)
    static let subtleInk = Color(red: 0x6B / 255, green: 0x72 / 255, blue: 0x80 / 255)
    static let hairline = Color(red: 0xE5 / 255, green: 0xE7 / 255, blue: 0xEB / 255)
    static let dotOnline = Color(red: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255)
    static let dotOffline = Color(red: 0x9C / 255, green: 0xA3 / 255, blue: 0xAF / 255)
}

/// Локализованные строки для UI (обёртка над ядром).
struct UIStrings {
    let lang: String
    private let source = LocalizedStrings.shared
    func callAsFunction(_ key: String) -> String { source.string(key, lang: lang) }
}
#endif
