import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Автоконтекст устройства, домешиваемый в `identity.metadata` перед каждой отправкой.
/// Host-значения с тем же ключом приоритетнее (не перетираются).
struct DeviceContext {
    /// Имя текущего экрана host-приложения (задаётся `setCurrentScreen`).
    var currentScreen: String?
    /// Активная локаль (из конфига или системная).
    var locale: String

    init(locale: String, currentScreen: String? = nil) {
        self.locale = locale
        self.currentScreen = currentScreen
    }

    /// Собирает автополя. `app_version`, `os_version`, `device_model`, `timezone` — из системы.
    func autoMetadata() -> [String: String] {
        var meta: [String: String] = [
            "sdk_version": SdkVersion.current,
            "platform": SdkVersion.platform,
            "os_version": Self.osVersion,
            "device_model": Self.deviceModel,
            "locale": locale,
            "timezone": TimeZone.current.identifier,
        ]
        if let appVersion = Self.appVersion { meta["app_version"] = appVersion }
        if let screen = currentScreen, !screen.isEmpty { meta["screen"] = screen }
        return meta
    }

    static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(version.majorVersion).\(version.minorVersion)\(version.patchVersion > 0 ? ".\(version.patchVersion)" : "")"
        #if os(iOS)
        return "iOS \(number)"
        #elseif os(macOS)
        return "macOS \(number)"
        #else
        return number
        #endif
    }

    /// Идентификатор модели (напр. `iPhone15,3`) из `uname`.
    static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}
