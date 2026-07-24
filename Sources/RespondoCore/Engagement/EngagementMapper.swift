import Foundation

/// Преобразование engagement-DTO бэкенда в публичные доменные модели.
enum EngagementMapper {
    // MARK: - News

    static func toNews(_ dto: NewsItemDTO) -> RespondoNewsItem {
        RespondoNewsItem(
            id: dto.id,
            title: dto.title ?? "",
            body: dto.body ?? "",
            imageURL: nonEmptyURL(dto.imageURL),
            labels: dto.labels ?? [],
            publishedAt: MessageMapper.parseDateOptional(dto.publishedAt),
            seen: dto.seen ?? false
        )
    }

    // MARK: - Survey

    static func toSurvey(_ dto: SurveyCatalogItemDTO) -> RespondoSurvey {
        let content = dto.content
        let questions = (content.questions ?? []).map { toQuestion($0) }
        let steps: [[String]]
        if let raw = content.surveySteps, !raw.isEmpty {
            steps = raw
        } else {
            steps = questions.map { [$0.id] } // по умолчанию — один вопрос на шаг
        }
        return RespondoSurvey(
            campaignId: dto.campaignId,
            deliveryId: dto.deliveryId,
            name: dto.name ?? "",
            format: RespondoSurveyFormat(rawValue: content.surveyFormat ?? "") ?? .inModal,
            intro: nonEmpty(content.intro),
            thanks: nonEmpty(content.thanks),
            showIntroScreen: content.showIntroScreen ?? false,
            showProgress: content.showProgress ?? false,
            showDismiss: content.showDismiss ?? true,
            steps: steps,
            questions: questions,
            sender: toSender(dto.fromSender)
        )
    }

    static func toQuestion(_ dto: QuestionDTO) -> RespondoQuestion {
        RespondoQuestion(
            id: dto.id,
            type: RespondoQuestionType(rawValue: dto.type) ?? .text,
            title: dto.title ?? "",
            options: dto.options ?? [],
            required: dto.required ?? false
        )
    }

    // MARK: - Banner

    static func toBanner(_ dto: BannerCatalogItemDTO) -> RespondoBanner {
        let content = dto.content
        return RespondoBanner(
            campaignId: dto.campaignId,
            deliveryId: dto.deliveryId,
            name: dto.name ?? "",
            body: content.body ?? "",
            layout: RespondoBannerLayout(rawValue: content.bannerLayout ?? "") ?? .floating,
            position: RespondoBannerPosition(rawValue: content.bannerPosition ?? "") ?? .bottom,
            action: RespondoBannerAction(rawValue: content.bannerAction ?? "") ?? .none,
            url: nonEmptyURL(content.bannerURL),
            linkLabel: nonEmpty(content.bannerLinkLabel),
            reactions: content.bannerReactions ?? [],
            openNewTab: content.bannerOpenNewTab ?? false,
            backgroundHex: nonEmpty(content.bannerBg),
            foregroundHex: nonEmpty(content.bannerFg),
            buttonBackgroundHex: nonEmpty(content.bannerBtnBg),
            buttonForegroundHex: nonEmpty(content.bannerBtnFg),
            dismissAfterAction: content.bannerDismissAfterAction ?? false,
            showDismiss: content.showDismiss ?? true,
            sender: toSender(dto.fromSender)
        )
    }

    // MARK: - Checklist

    static func toChecklist(_ dto: ChecklistCatalogItemDTO) -> RespondoChecklist {
        let tasks = (dto.tasks ?? []).map { toChecklistTask($0) }
        return RespondoChecklist(
            id: dto.id,
            title: dto.title ?? "",
            body: nonEmpty(dto.body),
            dismissible: dto.dismissible ?? false,
            tasks: tasks,
            status: dto.progress?.status ?? "",
            doneTaskIds: Set(dto.progress?.doneTaskIds ?? [])
        )
    }

    static func toChecklistTask(_ dto: ChecklistTaskDTO) -> RespondoChecklistTask {
        RespondoChecklistTask(
            id: dto.id,
            title: dto.title ?? "",
            body: nonEmpty(dto.body),
            action: toChecklistAction(dto.action)
        )
    }

    static func toChecklistAction(_ dto: ChecklistTaskActionDTO) -> RespondoChecklistAction {
        switch dto.type {
        case "url":
            if let raw = dto.url, let url = URL(string: raw) {
                return .url(url: url, newTab: dto.newTab ?? false)
            }
            return .manual
        case "tour":
            return .tour(tourId: dto.tourId)
        default:
            return .manual
        }
    }

    // MARK: - Общее

    static func toSender(_ dto: SenderDTO?) -> RespondoSender? {
        guard let dto, let name = nonEmpty(dto.name) else { return nil }
        return RespondoSender(name: name, avatarURL: nonEmptyURL(dto.avatarURL))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func nonEmptyURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        return URL(string: value)
    }
}
