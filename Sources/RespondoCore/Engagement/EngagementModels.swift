import Foundation

// MARK: - News

/// Элемент ленты «Что нового».
public struct RespondoNewsItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let body: String
    public let imageURL: URL?
    public let labels: [String]
    public let publishedAt: Date?
    public internal(set) var seen: Bool

    public init(id: String, title: String, body: String, imageURL: URL?, labels: [String], publishedAt: Date?, seen: Bool) {
        self.id = id
        self.title = title
        self.body = body
        self.imageURL = imageURL
        self.labels = labels
        self.publishedAt = publishedAt
        self.seen = seen
    }
}

// MARK: - Sender

/// Отправитель (оператор), показываемый в опросе/баннере.
public struct RespondoSender: Sendable, Equatable {
    public let name: String
    public let avatarURL: URL?

    public init(name: String, avatarURL: URL?) {
        self.name = name
        self.avatarURL = avatarURL
    }
}

// MARK: - Survey

/// Формат опроса: оверлей (модалка) или in-thread.
public enum RespondoSurveyFormat: String, Sendable, Equatable {
    case inModal = "in_modal"
    case inWidget = "in_widget"
}

/// Тип вопроса опроса.
public enum RespondoQuestionType: String, Sendable, Equatable {
    case text
    case choice
    case scale
    case nps
    case csat
}

/// Вопрос опроса.
public struct RespondoQuestion: Sendable, Equatable, Identifiable {
    public let id: String
    public let type: RespondoQuestionType
    public let title: String
    public let options: [String]
    public let required: Bool

    public init(id: String, type: RespondoQuestionType, title: String, options: [String], required: Bool) {
        self.id = id
        self.type = type
        self.title = title
        self.options = options
        self.required = required
    }
}

/// Оверлей-опрос (NPS/CSAT и др.), доставленный посетителю.
public struct RespondoSurvey: Sendable, Equatable, Identifiable {
    public let campaignId: String
    public let deliveryId: String
    public let name: String
    public let format: RespondoSurveyFormat
    public let intro: String?
    public let thanks: String?
    public let showIntroScreen: Bool
    public let showProgress: Bool
    public let showDismiss: Bool
    /// Группы id вопросов по шагам (если заданы); иначе шаг = один вопрос.
    public let steps: [[String]]
    public let questions: [RespondoQuestion]
    public let sender: RespondoSender?

    public var id: String { deliveryId }

    public init(
        campaignId: String, deliveryId: String, name: String, format: RespondoSurveyFormat,
        intro: String?, thanks: String?, showIntroScreen: Bool, showProgress: Bool, showDismiss: Bool,
        steps: [[String]], questions: [RespondoQuestion], sender: RespondoSender?
    ) {
        self.campaignId = campaignId
        self.deliveryId = deliveryId
        self.name = name
        self.format = format
        self.intro = intro
        self.thanks = thanks
        self.showIntroScreen = showIntroScreen
        self.showProgress = showProgress
        self.showDismiss = showDismiss
        self.steps = steps
        self.questions = questions
        self.sender = sender
    }
}

/// Ответ пользователя на вопрос опроса (публичный тип, не раскрывает внутренний JSON).
public enum RespondoSurveyAnswer: Sendable, Equatable {
    case text(String)
    case number(Double)
    case choice(String)
    case multiChoice([String])
}

// MARK: - Banner

/// Раскладка баннера.
public enum RespondoBannerLayout: String, Sendable, Equatable {
    case inline
    case floating
}

/// Позиция баннера.
public enum RespondoBannerPosition: String, Sendable, Equatable {
    case top
    case bottom
}

/// Действие баннера при клике.
public enum RespondoBannerAction: String, Sendable, Equatable {
    case none
    case url
    case button
    case reactions
    case email
    case tour
}

/// Page-level баннер (Banner Redesign).
public struct RespondoBanner: Sendable, Equatable, Identifiable {
    public let campaignId: String
    public let deliveryId: String
    public let name: String
    public let body: String
    public let layout: RespondoBannerLayout
    public let position: RespondoBannerPosition
    public let action: RespondoBannerAction
    public let url: URL?
    public let linkLabel: String?
    public let reactions: [String]
    public let openNewTab: Bool
    public let backgroundHex: String?
    public let foregroundHex: String?
    public let buttonBackgroundHex: String?
    public let buttonForegroundHex: String?
    public let dismissAfterAction: Bool
    public let showDismiss: Bool
    public let sender: RespondoSender?

    public var id: String { deliveryId }

    public init(
        campaignId: String, deliveryId: String, name: String, body: String,
        layout: RespondoBannerLayout, position: RespondoBannerPosition, action: RespondoBannerAction,
        url: URL?, linkLabel: String?, reactions: [String], openNewTab: Bool,
        backgroundHex: String?, foregroundHex: String?, buttonBackgroundHex: String?, buttonForegroundHex: String?,
        dismissAfterAction: Bool, showDismiss: Bool, sender: RespondoSender?
    ) {
        self.campaignId = campaignId
        self.deliveryId = deliveryId
        self.name = name
        self.body = body
        self.layout = layout
        self.position = position
        self.action = action
        self.url = url
        self.linkLabel = linkLabel
        self.reactions = reactions
        self.openNewTab = openNewTab
        self.backgroundHex = backgroundHex
        self.foregroundHex = foregroundHex
        self.buttonBackgroundHex = buttonBackgroundHex
        self.buttonForegroundHex = buttonForegroundHex
        self.dismissAfterAction = dismissAfterAction
        self.showDismiss = showDismiss
        self.sender = sender
    }
}

// MARK: - Checklist

/// Действие задачи чек-листа.
public enum RespondoChecklistAction: Sendable, Equatable {
    case url(url: URL, newTab: Bool)
    case manual
    case tour(tourId: String?)
}

/// Задача чек-листа.
public struct RespondoChecklistTask: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let body: String?
    public let action: RespondoChecklistAction

    public init(id: String, title: String, body: String?, action: RespondoChecklistAction) {
        self.id = id
        self.title = title
        self.body = body
        self.action = action
    }
}

/// Онбординг-чек-лист.
public struct RespondoChecklist: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let body: String?
    public let dismissible: Bool
    public let tasks: [RespondoChecklistTask]
    public internal(set) var status: String
    public internal(set) var doneTaskIds: Set<String>

    public init(id: String, title: String, body: String?, dismissible: Bool, tasks: [RespondoChecklistTask], status: String, doneTaskIds: Set<String>) {
        self.id = id
        self.title = title
        self.body = body
        self.dismissible = dismissible
        self.tasks = tasks
        self.status = status
        self.doneTaskIds = doneTaskIds
    }

    /// Видимые (не tour) задачи — tour-задачи скрываются в мобильном контексте.
    public var visibleTasks: [RespondoChecklistTask] {
        tasks.filter { if case .tour = $0.action { return false } else { return true } }
    }

    /// Прогресс по видимым задачам: (выполнено, всего).
    public var progress: (done: Int, total: Int) {
        let visible = visibleTasks
        let done = visible.filter { doneTaskIds.contains($0.id) }.count
        return (done, visible.count)
    }
}

// MARK: - Proactive

/// Проактивное сообщение под текущий экран.
public struct RespondoProactiveMessage: Sendable, Equatable {
    public let text: String
    public let pagePath: String?

    public init(text: String, pagePath: String?) {
        self.text = text
        self.pagePath = pagePath
    }
}
