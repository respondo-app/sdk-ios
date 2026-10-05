import Foundation

/// Окружение APNs, в котором действителен токен ЭТОЙ сборки.
///
/// Apple выдаёт токен, живущий ровно в одном окружении: сборка, подписанная
/// development-профилем, получает sandbox-токен, TestFlight и App Store —
/// production. Ключ `.p8` один и тот же, отличается только хост, куда уходит
/// пуш (`api.sandbox.push.apple.com` против `api.push.apple.com`).
///
/// Раньше это было настройкой канала в панели: интегратор, чтобы поймать пуш на
/// сборке из Xcode, переключал канал в Sandbox — и тем самым уводил в неверный
/// хост токены всех живых пользователей. Значение переехало к токену, и
/// сообщает его тот, кто единственный знает наверняка, — сама сборка.
///
/// Ответ здесь — подсказка, а не приговор: бэкенд, получив от APNs
/// `BadDeviceToken`, пробует второй хост и записывает найденное окружение к
/// токену. То есть ошибка определения стоит одной лишней попытки при первой
/// доставке, а не потерянного пуша.
enum ApnsEnvironment {
    /// `production` | `sandbox` | `nil`, если определить не удалось.
    ///
    /// `nil` отправляется как отсутствующее поле — бэкенд трактует пустое
    /// значение как «выяснить при доставке», и это всегда безопасно.
    static var current: String? {
        if let fromProfile = fromProvisioningProfile() {
            return fromProfile
        }
        #if targetEnvironment(simulator)
        // Симулятор (iOS 16+ умеет удалённые пуши) профиля не несёт вовсе.
        return "sandbox"
        #elseif DEBUG
        return "sandbox"
        #else
        // Release без профиля — это App Store: система срезает
        // `embedded.mobileprovision` при установке из магазина.
        return "production"
        #endif
    }

    /// Читает `aps-environment` из встроенного provisioning-профиля.
    ///
    /// Профиль — CMS-подписанный контейнер, внутри которого лежит обычный
    /// XML-plist. Подпись не проверяем и не можем: нам нужно одно поле для
    /// собственной телеметрии, а не доверие к содержимому. Поэтому вырезаем
    /// участок между `<?xml` и `</plist>` и разбираем его как plist.
    ///
    /// Профиля нет у сборок из App Store — там ветка выше даёт `production`,
    /// что и есть правда для магазинной установки.
    private static func fromProvisioningProfile() -> String? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        guard let open = raw.range(of: Data("<?xml".utf8)),
              let close = raw.range(of: Data("</plist>".utf8), options: [], in: open.upperBound..<raw.endIndex) else {
            return nil
        }
        let plistData = raw[open.lowerBound..<close.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil
        ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let aps = entitlements["aps-environment"] as? String else {
            return nil
        }
        // Apple пишет `development`; на проводе у нас `sandbox` — то же слово,
        // которым это окружение называет сам APNs.
        return aps == "development" ? "sandbox" : "production"
    }
}
