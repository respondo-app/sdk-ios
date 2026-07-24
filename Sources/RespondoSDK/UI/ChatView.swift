#if canImport(UIKit)
import SwiftUI
import RespondoCore

/// Тред чата: шапка, плашка рабочих часов, лента сообщений, композер.
public struct ChatView: View {
    @ObservedObject var controller: ConversationController
    let engagement: EngagementController?
    let onClose: () -> Void

    @State private var lightboxURL: URL?

    private var strings: UIStrings { UIStrings(lang: controller.lang) }
    private var theme: ResolvedTheme { controller.theme }

    public init(controller: ConversationController, engagement: EngagementController? = nil, onClose: @escaping () -> Void) {
        self.controller = controller
        self.engagement = engagement
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if let officeText = controller.officeHoursText {
                OfficeHoursBar(text: officeText, online: theme.officeHours?.open ?? false)
                Divider()
            }
            if controller.isEscalated {
                EscalationBanner(
                    agentHasReplied: controller.agentHasReplied,
                    theme: theme,
                    strings: strings,
                    onContinueWithAI: { Task { await controller.continueWithAI() } }
                )
            }
            messagesList
            if controller.needsEmail {
                EmailCollectorView(theme: theme, strings: strings) { controller.submitEmail($0) }
                    .padding(.bottom, 8)
            }
            if !controller.suggestedQuestions.isEmpty {
                QuestionChips(questions: controller.suggestedQuestions, theme: theme) { controller.sendSuggested($0) }
                    .padding(.vertical, 8)
            }
            ComposerView(controller: controller, theme: theme, strings: strings) { hasText in
                engagement?.setComposerHasText(hasText)
            }
        }
        .background(RespondoPalette.background)
        .environment(\.colorScheme, .light) // веб не имеет тёмной темы — форсируем светлую
        .fullScreenCover(item: Binding(get: { lightboxURL.map { LightboxItem(url: $0) } }, set: { lightboxURL = $0?.url })) { item in
            LightboxView(url: item.url, strings: strings) { lightboxURL = nil }
        }
        .onChange(of: lightboxURL) { url in engagement?.setLightboxOpen(url != nil) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let logo = theme.logoURL {
                RemoteImageView(url: logo, fallbackInitials: String(theme.title.prefix(1)), size: 28, tint: theme.primaryColor.swiftUIColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(theme.title).font(.system(size: 16, weight: .semibold)).foregroundColor(RespondoPalette.ink)
            }
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

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if controller.historyHasMore {
                        Button { Task { await controller.loadOlder() } } label: {
                            Text(strings("loadingHistory")).font(.system(size: 12)).foregroundColor(RespondoPalette.subtleInk)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                    }
                    if controller.messages.isEmpty && !theme.quickQuestions.isEmpty {
                        QuestionChips(questions: theme.quickQuestions, theme: theme) { controller.sendSuggested($0) }
                            .padding(.top, 8)
                    }
                    ForEach(controller.messages) { message in
                        MessageBubbleView(
                            message: message,
                            theme: theme,
                            strings: strings,
                            onImageTap: { attachment in lightboxURL = URL(string: attachment.url) },
                            onSourceTap: { controller.openURL($0) },
                            onRetry: { controller.retry(messageId: $0) }
                        )
                        .id(message.id)
                    }
                    if let author = controller.typingAuthor {
                        TypingIndicatorView(author: author, strings: strings).id("typing")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .onChange(of: controller.messages.count) { _ in
                if let last = controller.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onChange(of: controller.typingAuthor) { author in
                if author != nil { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
            }
        }
    }
}

private struct LightboxItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Контейнер поверхностей модалки: тред / новости / чеклисты + engagement-оверлеи
/// (survey/banner) поверх треда по решению арбитра.
public struct ChatContainerView: View {
    @ObservedObject var controller: ConversationController
    @ObservedObject var engagement: EngagementController
    let surface: ChatSurface
    let onClose: () -> Void

    private var strings: UIStrings { UIStrings(lang: controller.lang) }
    private var theme: ResolvedTheme { controller.theme }

    public init(controller: ConversationController, engagement: EngagementController, surface: ChatSurface, onClose: @escaping () -> Void) {
        self.controller = controller
        self.engagement = engagement
        self.surface = surface
        self.onClose = onClose
    }

    public var body: some View {
        switch surface {
        case .thread:
            threadWithOverlays
        case .news:
            NewsView(engagement: engagement, theme: theme, strings: strings, onClose: onClose)
        case .checklists:
            ChecklistsView(engagement: engagement, theme: theme, strings: strings, onClose: onClose)
        }
    }

    private var threadWithOverlays: some View {
        ZStack {
            VStack(spacing: 0) {
                if case .banner(let banner) = engagement.activeOverlay, banner.position == .top {
                    BannerBarView(engagement: engagement, banner: banner, theme: theme, strings: strings)
                }
                ChatView(controller: controller, engagement: engagement, onClose: onClose)
                if case .banner(let banner) = engagement.activeOverlay, banner.position == .bottom {
                    BannerBarView(engagement: engagement, banner: banner, theme: theme, strings: strings)
                }
            }
            if case .survey(let survey) = engagement.activeOverlay {
                SurveyOverlayView(engagement: engagement, survey: survey, theme: theme, strings: strings)
            }
        }
    }
}
#endif
