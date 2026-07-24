import Foundation

/// Императивные колбэки SDK (альтернатива реактивным потокам). Слабая ссылка.
/// Все методы опциональны (есть дефолтные реализации). Вызываются на главном потоке.
public protocol RespondoDelegate: AnyObject {
    /// Изменилось число непрочитанных (для бейджа на иконке host-приложения).
    func respondoUnreadChanged(_ count: Int)
    /// Модалка чата открылась.
    func respondoChatOpened()
    /// Модалка чата закрылась.
    func respondoChatClosed()
    /// Пользователь тапнул ссылку/CTA. Вернуть `true`, если host сам открыл URL
    /// (SDK не будет открывать); `false` — SDK откроет во внешнем браузере.
    func respondoUrlRequested(_ url: URL) -> Bool
    /// Тап по пушу/диплинку, который SDK распознал, но не смог отобразить.
    func respondoUnhandledDeepLink(_ payload: RespondoPushPayload)
    /// Пришло проактивное сообщение под текущий экран (чат закрыт). Host может показать
    /// тизер у своей кнопки чата; тап → `Respondo.open()` внесёт текст в тред.
    func respondoProactiveMessage(_ message: RespondoProactiveMessage)
}

public extension RespondoDelegate {
    func respondoUnreadChanged(_ count: Int) {}
    func respondoChatOpened() {}
    func respondoChatClosed() {}
    func respondoUrlRequested(_ url: URL) -> Bool { false }
    func respondoUnhandledDeepLink(_ payload: RespondoPushPayload) {}
    func respondoProactiveMessage(_ message: RespondoProactiveMessage) {}
}
