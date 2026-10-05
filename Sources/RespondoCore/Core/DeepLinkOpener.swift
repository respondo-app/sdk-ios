import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Открывает диплинк push-кампании так же, как Intercom iOS SDK:
/// - `https://` на домене из `RespondoUniversalLinkDomains` (Info.plist) — отдаётся самому
///   приложению как Universal Link (`NSUserActivity`, как это делает iOS при тапе по ссылке):
///   scene delegate `scene(_:continue:)` или app delegate `application(_:continue:restorationHandler:)`.
///   `UIApplication.open` с такой ссылкой из самого приложения открыл бы Safari.
/// - любая другая ссылка (`yourapp://orders/1` или обычный `https://`) — `UIApplication.open`:
///   своя схема возвращается в приложение (`application(_:open:options:)` / `onOpenURL`),
///   веб-ссылка открывается в Safari.
/// Возвращает false, если ссылку никто не принял — тогда host получает `respondoUnhandledDeepLink`.
enum DeepLinkOpener {
    /// Ключ Info.plist: массив доменов Universal Links приложения (`example.com`, `*.example.com`).
    static let universalLinkDomainsKey = "RespondoUniversalLinkDomains"

    /// Схемы, которые SDK не открывает никогда.
    private static let blockedSchemes: Set<String> = ["javascript", "data", "file", "about", "blob"]

    /// Разбор ссылки: nil — пустая, битая или запрещённая схема.
    static func url(from link: String) -> URL? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            !blockedSchemes.contains(scheme)
        else { return nil }
        return url
    }

    /// Совпадает ли хост ссылки с доменом из списка (`*.example.com` — любой поддомен и сам домен).
    static func isUniversalLink(_ url: URL, domains: [String]) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return domains.contains { raw in
            let domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if domain.hasPrefix("*.") {
                let base = String(domain.dropFirst(2))
                return host == base || host.hasSuffix("." + base)
            }
            return host == domain
        }
    }

    #if canImport(UIKit)
    @MainActor
    static func open(_ link: String) async -> Bool {
        guard let url = url(from: link) else {
            RespondoLog.warn("диплинк пуша отклонён: \(link)")
            return false
        }
        let domains = Bundle.main.object(forInfoDictionaryKey: universalLinkDomainsKey) as? [String] ?? []
        if isUniversalLink(url, domains: domains), continueAsUserActivity(url) {
            return true
        }
        let opened = await UIApplication.shared.open(url, options: [:])
        if !opened {
            RespondoLog.warn("диплинк пуша никто не принял: \(link) — зарегистрируйте схему или добавьте домен в \(universalLinkDomainsKey)")
        }
        return opened
    }

    /// Доставляет Universal Link приложению тем же путём, что и iOS при тапе по ссылке.
    @MainActor
    private static func continueAsUserActivity(_ url: URL) -> Bool {
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        let scenes = UIApplication.shared.connectedScenes
            .sorted { rank($0.activationState) < rank($1.activationState) }
        for scene in scenes {
            if scene.delegate?.scene?(scene, continue: activity) != nil {
                return true
            }
        }
        let app = UIApplication.shared
        return app.delegate?.application?(app, continue: activity, restorationHandler: { _ in }) ?? false
    }

    private static func rank(_ state: UIScene.ActivationState) -> Int {
        switch state {
        case .foregroundActive: return 0
        case .foregroundInactive: return 1
        case .background: return 2
        default: return 3
        }
    }
    #else
    @MainActor
    static func open(_ link: String) async -> Bool { false }
    #endif
}
