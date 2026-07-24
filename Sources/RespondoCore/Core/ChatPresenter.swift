import Foundation

/// Абстракция показа/скрытия UI чата. Реализуется UI-слоем (iOS, SwiftUI/UIKit),
/// что позволяет ядру управлять модалкой, не завися от конкретного фреймворка.
@MainActor
public protocol ChatPresenter: AnyObject {
    /// Показать лист чата. `surface` — какую поверхность открыть (тред / новости / чеклисты).
    func present(surface: ChatSurface)
    /// Скрыть лист чата.
    func dismiss()
    /// Открыт ли лист сейчас.
    var isPresented: Bool { get }
}

/// Поверхность, открываемая в модалке.
public enum ChatSurface: Sendable, Equatable {
    case thread
    case news
    case checklists
}
