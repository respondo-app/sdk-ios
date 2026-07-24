import Foundation

// MARK: - News

/// Ответ `GET /api/v1/widget/news`.
struct NewsListResponseDTO: Codable, Equatable {
    let items: [NewsItemDTO]?
    let unread: Int?
}

struct NewsItemDTO: Codable, Equatable {
    let id: String
    let title: String?
    let body: String?
    let imageURL: String?
    let labels: [String]?
    let publishedAt: String?
    let seen: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, body, labels, seen
        case imageURL = "image_url"
        case publishedAt = "published_at"
    }
}

// MARK: - Отправитель

struct SenderDTO: Codable, Equatable {
    let name: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case name
        case avatarURL = "avatar_url"
    }
}

// MARK: - Вопрос опроса

struct QuestionDTO: Codable, Equatable {
    let id: String
    let type: String
    let title: String?
    let options: [String]?
    let required: Bool?
}

// MARK: - OutboundContent (подмножество для survey/banner)

struct OutboundContentDTO: Codable, Equatable {
    let body: String?
    let intro: String?
    let questions: [QuestionDTO]?
    let thanks: String?
    let surveyFormat: String?
    let surveySteps: [[String]]?
    let showIntroScreen: Bool?
    let showDismiss: Bool?
    let showProgress: Bool?
    let bannerLinkLabel: String?
    let bannerBg: String?
    let bannerFg: String?
    let bannerBtnBg: String?
    let bannerBtnFg: String?
    let bannerLayout: String?
    let bannerPosition: String?
    let bannerAction: String?
    let bannerURL: String?
    let bannerReactions: [String]?
    let bannerOpenNewTab: Bool?
    let bannerDismissAfterAction: Bool?
    let title: String?
    let imageURL: String?
    let dismissible: Bool?

    enum CodingKeys: String, CodingKey {
        case body, intro, questions, thanks, title
        case surveyFormat = "survey_format"
        case surveySteps = "survey_steps"
        case showIntroScreen = "show_intro_screen"
        case showDismiss = "show_dismiss"
        case showProgress = "show_progress"
        case bannerLinkLabel = "banner_link_label"
        case bannerBg = "banner_bg"
        case bannerFg = "banner_fg"
        case bannerBtnBg = "banner_btn_bg"
        case bannerBtnFg = "banner_btn_fg"
        case bannerLayout = "banner_layout"
        case bannerPosition = "banner_position"
        case bannerAction = "banner_action"
        case bannerURL = "banner_url"
        case bannerReactions = "banner_reactions"
        case bannerOpenNewTab = "banner_open_new_tab"
        case bannerDismissAfterAction = "banner_dismiss_after_action"
        case imageURL = "image_url"
        case dismissible
    }
}

// MARK: - Каталоги survey/banner

struct SurveyCatalogItemDTO: Codable, Equatable {
    let campaignId: String
    let deliveryId: String
    let name: String?
    let content: OutboundContentDTO
    let fromSender: SenderDTO?

    enum CodingKeys: String, CodingKey {
        case name, content
        case campaignId = "campaign_id"
        case deliveryId = "delivery_id"
        case fromSender = "from_sender"
    }
}

struct SurveysCatalogResponseDTO: Codable, Equatable {
    let surveys: [SurveyCatalogItemDTO]?
}

struct BannerCatalogItemDTO: Codable, Equatable {
    let campaignId: String
    let deliveryId: String
    let name: String?
    let content: OutboundContentDTO
    let fromSender: SenderDTO?

    enum CodingKeys: String, CodingKey {
        case name, content
        case campaignId = "campaign_id"
        case deliveryId = "delivery_id"
        case fromSender = "from_sender"
    }
}

struct BannersCatalogResponseDTO: Codable, Equatable {
    let banners: [BannerCatalogItemDTO]?
}

// MARK: - Чек-листы

struct ChecklistTaskActionDTO: Codable, Equatable {
    let type: String
    let tourId: String?
    let url: String?
    let newTab: Bool?

    enum CodingKeys: String, CodingKey {
        case type, url
        case tourId = "tour_id"
        case newTab = "new_tab"
    }
}

struct ChecklistTaskDTO: Codable, Equatable {
    let id: String
    let title: String?
    let body: String?
    let action: ChecklistTaskActionDTO
}

struct ChecklistProgressStateDTO: Codable, Equatable {
    let status: String?
    let doneTaskIds: [String]?

    enum CodingKeys: String, CodingKey {
        case status
        case doneTaskIds = "done_task_ids"
    }
}

struct ChecklistCatalogItemDTO: Codable, Equatable {
    let id: String
    let title: String?
    let body: String?
    let dismissible: Bool?
    let tasks: [ChecklistTaskDTO]?
    let progress: ChecklistProgressStateDTO?
}

struct ChecklistsCatalogResponseDTO: Codable, Equatable {
    let checklists: [ChecklistCatalogItemDTO]?
}

// MARK: - Проактив

struct ProactiveResponseDTO: Codable, Equatable {
    let message: String?
    let pagePath: String?

    enum CodingKeys: String, CodingKey {
        case message
        case pagePath = "page_path"
    }
}

// MARK: - Тела запросов

struct SubmitAnswerRequestDTO: Codable, Equatable {
    let deliveryId: String
    let visitorId: String
    let questionId: String
    let value: JSONValue?

    enum CodingKeys: String, CodingKey {
        case value
        case deliveryId = "delivery_id"
        case visitorId = "visitor_id"
        case questionId = "question_id"
    }
}

struct SubmitSurveyRequestDTO: Codable, Equatable {
    let deliveryId: String
    let visitorId: String
    let answers: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case answers
        case deliveryId = "delivery_id"
        case visitorId = "visitor_id"
    }
}

struct SurveyAnswerResultDTO: Codable, Equatable {
    let ok: Bool?
    let done: Bool?
    let alreadyAnswered: Bool?
    let alreadyAnsweredQuestion: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, done
        case alreadyAnswered = "already_answered"
        case alreadyAnsweredQuestion = "already_answered_question"
    }
}

struct BannerResponseRequestDTO: Codable, Equatable {
    let deliveryId: String
    let visitorId: String
    let kind: String
    let value: String

    enum CodingKeys: String, CodingKey {
        case kind, value
        case deliveryId = "delivery_id"
        case visitorId = "visitor_id"
    }
}

struct ChecklistProgressRequestDTO: Codable, Equatable {
    let agentId: String?
    let channelId: String?
    let visitorId: String?
    let email: String?
    let userId: String?
    let userHash: String?
    let event: String
    let taskId: String?

    enum CodingKeys: String, CodingKey {
        case event
        case agentId = "agent_id"
        case channelId = "channel_id"
        case visitorId = "visitor_id"
        case email
        case userId = "user_id"
        case userHash = "user_hash"
        case taskId = "task_id"
    }
}

/// Ответ-подтверждение `{ok:true}`.
struct OkResponseDTO: Codable, Equatable {
    let ok: Bool?
    let done: Bool?
}
