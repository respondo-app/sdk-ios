#if canImport(UIKit)
import SwiftUI
import RespondoCore

// MARK: - Хелперы цвета

private func hexColor(_ hex: String?) -> Color? {
    guard let hex, let color = RespondoColor(hex: hex) else { return nil }
    return color.swiftUIColor
}

// MARK: - Заголовок engagement-экрана

private struct EngagementHeader: View {
    let title: String
    let strings: UIStrings
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(RespondoPalette.ink)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundColor(RespondoPalette.subtleInk)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(strings("close"))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RespondoPalette.background)
        .overlay(Rectangle().fill(RespondoPalette.hairline).frame(height: 0.5), alignment: .bottom)
    }
}

// MARK: - News

/// Экран «Что нового»: лента карточек. Отметка seen при появлении карточки.
struct NewsView: View {
    @ObservedObject var engagement: EngagementController
    let theme: ResolvedTheme
    let strings: UIStrings
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            EngagementHeader(title: strings("newsTitle"), strings: strings, onClose: onClose)
            if engagement.news.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(engagement.news) { item in
                            NewsCard(item: item, theme: theme)
                                .onAppear { engagement.markNewsSeen(item.id) }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(RespondoPalette.background)
        .environment(\.colorScheme, .light)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(strings("newsEmpty")).font(.system(size: 14)).foregroundColor(RespondoPalette.subtleInk)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct NewsCard: View {
    let item: RespondoNewsItem
    let theme: ResolvedTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = item.imageURL {
                RemoteImageView(url: url, fallbackInitials: "", size: 0, tint: theme.primaryColor.swiftUIColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if !item.labels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.labels, id: \.self) { label in
                        Text(label)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(theme.primaryColor.swiftUIColor.opacity(0.12))
                            .foregroundColor(theme.primaryColor.swiftUIColor)
                            .clipShape(Capsule())
                    }
                }
            }
            Text(item.title).font(.system(size: 16, weight: .semibold)).foregroundColor(RespondoPalette.ink)
            Text(item.body).font(.system(size: 14)).foregroundColor(RespondoPalette.subtleInk)
                .fixedSize(horizontal: false, vertical: true)
            if !item.seen {
                Circle().fill(theme.primaryColor.swiftUIColor).frame(width: 8, height: 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RespondoPalette.background)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(RespondoPalette.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Checklists

/// Экран онбординг-чек-листов: задачи с чекбоксами/CTA, прогресс, скрытие.
struct ChecklistsView: View {
    @ObservedObject var engagement: EngagementController
    let theme: ResolvedTheme
    let strings: UIStrings
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            EngagementHeader(title: strings("checklistsTitle"), strings: strings, onClose: onClose)
            if engagement.checklists.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(engagement.checklists) { checklist in
                            ChecklistCard(checklist: checklist, engagement: engagement, theme: theme, strings: strings)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(RespondoPalette.background)
        .environment(\.colorScheme, .light)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(strings("checklistsEmpty")).font(.system(size: 14)).foregroundColor(RespondoPalette.subtleInk)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ChecklistCard: View {
    let checklist: RespondoChecklist
    @ObservedObject var engagement: EngagementController
    let theme: ResolvedTheme
    let strings: UIStrings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(checklist.title).font(.system(size: 16, weight: .semibold)).foregroundColor(RespondoPalette.ink)
                Spacer()
                if checklist.dismissible {
                    Button { engagement.dismissChecklist(checklist.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 13)).foregroundColor(RespondoPalette.subtleInk)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(strings("close"))
                }
            }
            if let body = checklist.body {
                Text(body).font(.system(size: 13)).foregroundColor(RespondoPalette.subtleInk)
            }
            progressBar
            ForEach(checklist.visibleTasks) { task in
                ChecklistRow(
                    task: task,
                    done: checklist.doneTaskIds.contains(task.id),
                    theme: theme,
                    strings: strings,
                    onTap: { engagement.performTask(checklistId: checklist.id, taskId: task.id) }
                )
            }
        }
        .padding(14)
        .background(RespondoPalette.background)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(RespondoPalette.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var progressBar: some View {
        let progress = checklist.progress
        let fraction = progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total)
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(RespondoPalette.hairline).frame(height: 6)
                    Capsule().fill(theme.primaryColor.swiftUIColor).frame(width: geo.size.width * fraction, height: 6)
                }
            }
            .frame(height: 6)
            Text("\(progress.done)/\(progress.total)")
                .font(.system(size: 11, weight: .medium)).foregroundColor(RespondoPalette.subtleInk)
        }
    }
}

private struct ChecklistRow: View {
    let task: RespondoChecklistTask
    let done: Bool
    let theme: ResolvedTheme
    let strings: UIStrings
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(done ? theme.primaryColor.swiftUIColor : RespondoPalette.subtleInk)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(RespondoPalette.ink)
                        .strikethrough(done)
                    if let body = task.body {
                        Text(body).font(.system(size: 12)).foregroundColor(RespondoPalette.subtleInk)
                    }
                }
                Spacer()
                if case .url = task.action {
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(RespondoPalette.subtleInk)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Survey overlay

/// Оверлей-опрос (NPS/CSAT и др.) поверх треда.
struct SurveyOverlayView: View {
    @ObservedObject var engagement: EngagementController
    let survey: RespondoSurvey
    let theme: ResolvedTheme
    let strings: UIStrings

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                header
                if engagement.surveyFinished {
                    finishedState
                } else {
                    ForEach(engagement.currentStepQuestions(survey)) { question in
                        SurveyQuestionView(question: question, engagement: engagement, survey: survey, theme: theme)
                    }
                    advanceButton
                }
            }
            .padding(20)
            .background(RespondoPalette.background)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(24)
        }
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if let intro = survey.intro {
                    Text(intro).font(.system(size: 14)).foregroundColor(RespondoPalette.subtleInk)
                }
                if survey.showProgress {
                    Text("\(min(engagement.surveyStepIndex + 1, survey.steps.count))/\(survey.steps.count)")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(RespondoPalette.subtleInk)
                }
            }
            Spacer()
            if survey.showDismiss {
                Button { engagement.dismissSurvey(survey.deliveryId) } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundColor(RespondoPalette.subtleInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(strings("close"))
            }
        }
    }

    private var finishedState: some View {
        VStack(spacing: 12) {
            Text(survey.thanks ?? strings("surveyThanks"))
                .font(.system(size: 15, weight: .medium)).foregroundColor(RespondoPalette.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Button { engagement.dismissSurvey(survey.deliveryId) } label: {
                Text(strings("close"))
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(theme.onPrimaryColor.swiftUIColor)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(theme.primaryColor.swiftUIColor)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var advanceButton: some View {
        let isLast = engagement.surveyStepIndex + 1 >= survey.steps.count
        return Button { engagement.advanceSurvey(survey) } label: {
            Text(isLast ? strings("surveySubmit") : strings("surveyNext"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.onPrimaryColor.swiftUIColor)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(engagement.canAdvance(survey) ? theme.primaryColor.swiftUIColor : RespondoPalette.subtleInk.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!engagement.canAdvance(survey))
    }
}

private struct SurveyQuestionView: View {
    let question: RespondoQuestion
    @ObservedObject var engagement: EngagementController
    let survey: RespondoSurvey
    let theme: ResolvedTheme
    @State private var textValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.title).font(.system(size: 15, weight: .medium)).foregroundColor(RespondoPalette.ink)
            switch question.type {
            case .nps:
                scaleRow(range: 0...10)
            case .csat, .scale:
                scaleRow(range: 1...5)
            case .choice:
                choiceList
            case .text:
                textField
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scaleRow(range: ClosedRange<Int>) -> some View {
        let selected = selectedNumber
        return HStack(spacing: 6) {
            ForEach(Array(range), id: \.self) { value in
                Button {
                    engagement.answerQuestion(survey, questionId: question.id, answer: .number(Double(value)))
                } label: {
                    Text("\(value)")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 34)
                        .background(selected == Double(value) ? theme.primaryColor.swiftUIColor : theme.primaryColor.swiftUIColor.opacity(0.1))
                        .foregroundColor(selected == Double(value) ? theme.onPrimaryColor.swiftUIColor : theme.primaryColor.swiftUIColor)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var choiceList: some View {
        VStack(spacing: 6) {
            ForEach(question.options, id: \.self) { option in
                Button {
                    engagement.answerQuestion(survey, questionId: question.id, answer: .choice(option))
                } label: {
                    HStack {
                        Text(option).font(.system(size: 14)).foregroundColor(RespondoPalette.ink)
                        Spacer()
                        if selectedChoice == option {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundColor(theme.primaryColor.swiftUIColor)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RespondoPalette.assistantBubble)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selectedChoice == option ? theme.primaryColor.swiftUIColor : Color.clear, lineWidth: 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var textField: some View {
        TextField("", text: $textValue)
            .font(.system(size: 14))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RespondoPalette.assistantBubble)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onChange(of: textValue) { newValue in
                if newValue.isEmpty {
                    return
                }
                engagement.answerQuestion(survey, questionId: question.id, answer: .text(newValue))
            }
    }

    private var selectedNumber: Double? {
        if case .number(let value)? = engagement.answeredValue(question.id) { return value }
        return nil
    }

    private var selectedChoice: String? {
        if case .choice(let value)? = engagement.answeredValue(question.id) { return value }
        return nil
    }
}

// MARK: - Banner bar

/// Плашка-баннер (top/bottom) внутри Respondo-экранов.
struct BannerBarView: View {
    @ObservedObject var engagement: EngagementController
    let banner: RespondoBanner
    let theme: ResolvedTheme
    let strings: UIStrings

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(banner.body).font(.system(size: 13)).foregroundColor(foreground)
                if banner.action == .url, let label = banner.linkLabel {
                    Button { engagement.bannerOpenURL(banner) } label: {
                        Text(label).font(.system(size: 13, weight: .semibold)).foregroundColor(buttonForeground)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(buttonBackground)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if banner.action == .reactions, !banner.reactions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(banner.reactions, id: \.self) { emoji in
                            Button { engagement.bannerReaction(banner, emoji: emoji) } label: {
                                Text(emoji).font(.system(size: 20))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer()
            if banner.showDismiss {
                Button { engagement.dismissBanner(banner.deliveryId) } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundColor(foreground.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(strings("close"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(background)
    }

    private var background: Color { hexColor(banner.backgroundHex) ?? theme.primaryColor.swiftUIColor.opacity(0.1) }
    private var foreground: Color { hexColor(banner.foregroundHex) ?? RespondoPalette.ink }
    private var buttonBackground: Color { hexColor(banner.buttonBackgroundHex) ?? theme.primaryColor.swiftUIColor }
    private var buttonForeground: Color { hexColor(banner.buttonForegroundHex) ?? theme.onPrimaryColor.swiftUIColor }
}
#endif
