import Foundation

/// Разрешает итоговую тему по правилу `themeOverride → серверный конфиг → дефолт SDK`.
enum ThemeResolver {
    // Дефолты (совпадают с бэкендом `buildWidgetConfigResult` и вебом).
    static let defaultPrimary = RespondoColor(hex: "#2563EB")!
    static let inkDark = RespondoColor(hex: "#1F2937")!
    static let white = RespondoColor(hex: "#FFFFFF")!
    static let defaultTitle = "Support"
    static let defaultGreeting = "Hi! How can I help you today?"
    static let defaultBorderRadius: CGFloat = 12
    static let contrastThreshold = 0.62

    /// Контраст текста/иконки на заливке primary (правило 4 theming.md).
    static func onPrimary(_ color: RespondoColor) -> RespondoColor {
        color.relativeLuminance > contrastThreshold ? inkDark : white
    }

    /// Цвет ссылки на светлом пузыре ассистента (правило 5 theming.md).
    static func linkColor(_ color: RespondoColor) -> RespondoColor {
        color.relativeLuminance > contrastThreshold ? inkDark : color
    }

    /// Начальный и максимальный детенты по `chat_size`.
    static func detents(for size: RespondoChatSize) -> (initial: CGFloat, max: CGFloat) {
        switch size {
        case .compact: return (0.55, 0.92)
        case .default: return (0.75, 0.95)
        case .large: return (0.92, 0.98)
        }
    }

    static func chatSize(from raw: String?) -> RespondoChatSize {
        guard let raw, let size = RespondoChatSize(rawValue: raw) else { return .default }
        return size
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return isoFractional.date(from: raw) ?? iso.date(from: raw)
    }

    /// Основной резолвер. `config` — ответ бэкенда (может быть nil до загрузки),
    /// `override` — `RespondoConfig.themeOverride`.
    static func resolve(config: WidgetConfigDTO?, override: RespondoTheme?) -> ResolvedTheme {
        // primary_color: override → config → дефолт.
        let primary = override?.primaryColor
            ?? config?.primaryColor.flatMap { RespondoColor(hex: $0) }
            ?? defaultPrimary

        let title = override?.title
            ?? config?.title.flatMap { $0.isEmpty ? nil : $0 }
            ?? config?.name.flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultTitle

        let greeting = override?.greeting
            ?? config?.greeting.flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultGreeting

        let greetingEnabled = config?.greetingEnabled ?? true

        let sizeRaw = override?.chatSize?.rawValue ?? config?.chatSize
        let size = chatSize(from: sizeRaw)
        let (initial, maxFraction) = detents(for: size)

        let radiusValue = override?.cornerRadius
            ?? config?.borderRadius.map { CGFloat($0) }
            ?? defaultBorderRadius
        let radius = min(max(radiusValue, 0), 28)

        let logoURL = override?.logoURL ?? config?.logoURL.flatMap { URL(string: $0) }
        let avatarURL = override?.avatarURL ?? config?.avatarURL.flatMap { URL(string: $0) }

        var office: ResolvedOfficeHours?
        if let oh = config?.officeHours, let open = oh.open {
            office = ResolvedOfficeHours(
                open: open,
                replyTime: oh.replyTime,
                timezone: oh.timezone,
                nextOpenAt: parseDate(oh.nextOpenAt),
                nextCloseAt: parseDate(oh.nextCloseAt)
            )
        }

        return ResolvedTheme(
            primaryColor: primary,
            onPrimaryColor: onPrimary(primary),
            linkColor: linkColor(primary),
            title: title,
            agentName: config?.name.flatMap { $0.isEmpty ? nil : $0 },
            greeting: greeting,
            greetingEnabled: greetingEnabled,
            quickQuestions: config?.quickQuestions ?? [],
            suggestedQuestionsEnabled: config?.suggestedQuestionsEnabled ?? false,
            proactiveMessagesEnabled: config?.proactiveMessagesEnabled ?? false,
            proactiveDelaySeconds: config?.proactiveDelaySeconds ?? 5,
            identityVerificationEnabled: config?.identityVerificationEnabled ?? false,
            logoURL: logoURL,
            avatarURL: avatarURL,
            cornerRadius: radius,
            initialDetentFraction: initial,
            maxDetentFraction: maxFraction,
            officeHours: office
        )
    }
}
