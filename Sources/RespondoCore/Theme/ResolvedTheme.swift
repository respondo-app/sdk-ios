import Foundation

/// Плашка рабочих часов (нормализованная из `office_hours`).
public struct ResolvedOfficeHours: Sendable, Equatable {
    public let open: Bool
    public let replyTime: String?
    public let timezone: String?
    public let nextOpenAt: Date?
    public let nextCloseAt: Date?
}

/// Итоговая тема, применяемая UI. Собрана из ответа конфига, оверрайда и дефолтов;
/// контрастные цвета и детенты уже вычислены (см. `sdks/spec/theming.md`).
public struct ResolvedTheme: Sendable, Equatable {
    public let primaryColor: RespondoColor
    /// Контрастный цвет текста/иконки на заливке primary.
    public let onPrimaryColor: RespondoColor
    /// Цвет ссылки на светлом пузыре ассистента.
    public let linkColor: RespondoColor
    public let title: String
    public let agentName: String?
    public let greeting: String?
    public let greetingEnabled: Bool
    public let quickQuestions: [String]
    public let suggestedQuestionsEnabled: Bool
    public let proactiveMessagesEnabled: Bool
    public let proactiveDelaySeconds: Int
    public let identityVerificationEnabled: Bool
    public let logoURL: URL?
    public let avatarURL: URL?
    public let cornerRadius: CGFloat
    public let initialDetentFraction: CGFloat
    public let maxDetentFraction: CGFloat
    public let officeHours: ResolvedOfficeHours?

    /// Дефолтная тема до загрузки конфига (используется как безопасный фолбэк).
    public static let fallback = ThemeResolver.resolve(config: nil, override: nil)
}
