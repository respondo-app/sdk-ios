import Foundation

/// Локализованные строки чат-UI. Источники: bundled `strings.json` (8 локалей, 13 ключей
/// веб-словаря) + `ui-strings-new.json` (те же 8 локалей, новые ключи мобильного SDK).
/// Фолбэк по локали — всегда `en`.
public final class LocalizedStrings: @unchecked Sendable {
    public static let supportedLocales = ["ru", "uk", "de", "fr", "es", "pt", "pl", "en"]

    /// Общий разделяемый экземпляр, читающий ресурсы из бандла SDK.
    public static let shared = LocalizedStrings()

    private let core: [String: [String: String]]
    private let extra: [String: [String: String]]

    init(core: [String: [String: String]]? = nil, extra: [String: [String: String]]? = nil) {
        self.core = core ?? Self.loadBundled("strings")
        self.extra = extra ?? Self.loadBundled("ui-strings-new")
    }

    private static func loadBundled(_ name: String) -> [String: [String: String]] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result: [String: [String: String]] = [:]
        for (locale, value) in json where locale != "_meta" {
            if let dict = value as? [String: Any] {
                result[locale] = dict.compactMapValues { $0 as? String }
            }
        }
        return result
    }

    /// Значение ключа для локали с фолбэком на `en` и затем на сам ключ.
    public func string(_ key: String, lang: String) -> String {
        let base = Self.baseCode(lang)
        if let value = core[base]?[key] ?? extra[base]?[key], !value.isEmpty {
            return value
        }
        if let value = core["en"]?[key] ?? extra["en"]?[key], !value.isEmpty {
            return value
        }
        return key
    }

    /// Базовый код локали (`ru-RU` → `ru`).
    public static func baseCode(_ locale: String) -> String {
        let lower = locale.lowercased()
        if let dash = lower.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            return String(lower[..<dash])
        }
        return lower
    }

    /// Нормализует произвольную локаль к поддерживаемой UI-локали (иначе `en`).
    public static func normalize(_ locale: String?) -> String {
        guard let locale else { return "en" }
        let base = baseCode(locale)
        return supportedLocales.contains(base) ? base : "en"
    }

    /// Детект локали по тексту первого пользовательского сообщения
    /// (украинские `іїєІЇЄ` → uk; иная кириллица → ru; иначе — nil).
    public static func detectFromText(_ text: String) -> String? {
        let ukrainian = CharacterSet(charactersIn: "іїєґІЇЄҐ")
        let cyrillic = CharacterSet(charactersIn: "абвгдежзийклмнопрстуфхцчшщъыьэюяАБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ")
        let scalars = text.unicodeScalars
        if scalars.contains(where: { ukrainian.contains($0) }) { return "uk" }
        if scalars.contains(where: { cyrillic.contains($0) }) { return "ru" }
        return nil
    }
}
