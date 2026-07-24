import Foundation

/// Цвет в модели sRGB без зависимости от UI-фреймворка.
/// UI-слой конвертирует его в нативный `Color`/`UIColor`.
public struct RespondoColor: Equatable, Sendable {
    /// Каналы в диапазоне 0…1.
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// Разбор строки `#RRGGBB` (или `RRGGBB`). Возвращает nil при некорректном формате.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    /// Целочисленные каналы 0…255 — удобно для отладки/сериализации.
    public var rgb255: (r: Int, g: Int, b: Int) {
        (Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// Относительная яркость по WCAG (sRGB relative luminance).
    /// Формула дословно повторяет `widget/src/brand-color.ts::linkInk`.
    public var relativeLuminance: Double {
        func lin(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }
}
