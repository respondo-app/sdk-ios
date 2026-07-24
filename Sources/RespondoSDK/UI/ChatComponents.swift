#if canImport(UIKit)
import SwiftUI
import RespondoCore

/// Пузырь одного сообщения треда.
struct MessageBubbleView: View {
    let message: ChatMessage
    let theme: ResolvedTheme
    let strings: UIStrings
    let onImageTap: (ChatAttachment) -> Void
    let onSourceTap: (URL) -> Void
    let onRetry: (String) -> Void

    private var isUser: Bool { message.role == .user }

    var body: some View {
        if message.role == .system {
            systemBubble
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if isUser { Spacer(minLength: 40) }
                if !isUser {
                    RemoteImageView(url: URL(string: message.authorAvatarURL ?? ""), fallbackInitials: initials, size: 26, tint: theme.primaryColor.swiftUIColor)
                }
                VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                    if !isUser, let author = message.authorName, !author.isEmpty {
                        Text(author)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(RespondoPalette.subtleInk)
                    }
                    bubbleContent
                    attachmentsView
                    sourcesView
                    if isUser { deliveryStatusView }
                }
                if !isUser { Spacer(minLength: 40) }
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        // Пузырь пользователя — его собственный текст, без markdown-разбора.
        // Пузыри ассистента рендерят markdown (bold/italic/code/списки/ссылки http(s)).
        Group {
            if isUser {
                Text(message.content)
            } else {
                Text(Markdown.attributedString(from: message.content))
                    .tint(theme.linkColor.swiftUIColor)
                    .environment(\.openURL, OpenURLAction { url in
                        onSourceTap(url)
                        return .handled
                    })
            }
        }
        .font(.system(size: 15))
        .foregroundColor(isUser ? theme.onPrimaryColor.swiftUIColor : RespondoPalette.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isUser ? theme.primaryColor.swiftUIColor : RespondoPalette.assistantBubble)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var attachmentsView: some View {
        if !message.attachments.isEmpty {
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                ForEach(message.attachments) { attachment in
                    if attachment.isImage, let url = URL(string: attachment.url) {
                        Button { onImageTap(attachment) } label: {
                            RemoteImageThumb(url: url)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Label(attachment.filename, systemImage: "doc")
                            .font(.system(size: 13))
                            .foregroundColor(RespondoPalette.ink)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sourcesView: some View {
        if !message.sources.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(strings("sourcesLabel"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(RespondoPalette.subtleInk)
                ForEach(message.sources) { source in
                    Button { if let url = URL(string: source.url) { onSourceTap(url) } } label: {
                        Text(source.title)
                            .font(.system(size: 13))
                            .foregroundColor(theme.linkColor.swiftUIColor)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var deliveryStatusView: some View {
        switch message.deliveryStatus {
        case .sending:
            Text("•••").font(.system(size: 11)).foregroundColor(RespondoPalette.subtleInk)
        case .sent:
            Image(systemName: "checkmark").font(.system(size: 10)).foregroundColor(RespondoPalette.subtleInk)
        case .failed:
            Button { onRetry(message.id) } label: {
                Label(strings("sendRetry"), systemImage: "arrow.clockwise")
                    .font(.system(size: 11)).foregroundColor(.red)
            }
            .buttonStyle(.plain)
        case .none:
            EmptyView()
        }
    }

    private var systemBubble: some View {
        Text(Markdown.attributedString(from: message.content))
            .tint(theme.linkColor.swiftUIColor)
            .environment(\.openURL, OpenURLAction { url in
                onSourceTap(url)
                return .handled
            })
            .font(.system(size: 12))
            .foregroundColor(RespondoPalette.subtleInk)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private var initials: String {
        let name = message.authorName ?? theme.agentName ?? "AI"
        return String(name.prefix(1)).uppercased()
    }
}

/// Миниатюра изображения-вложения.
struct RemoteImageThumb: View {
    let url: URL
    @StateObject private var loader = ImageLoader()
    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                RespondoPalette.assistantBubble
            }
        }
        .frame(width: 160, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { loader.load(url) }
    }
}

/// Индикатор набора оператором.
struct TypingIndicatorView: View {
    let author: String
    let strings: UIStrings
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(RespondoPalette.subtleInk)
                        .frame(width: 6, height: 6)
                        .opacity(phase == Double(index) ? 1 : 0.3)
                }
            }
            Text(author.isEmpty ? strings("typingIndicator") : "\(author) \(strings("typingIndicator"))")
                .font(.system(size: 12))
                .foregroundColor(RespondoPalette.subtleInk)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever()) { phase = 2 }
        }
    }
}

/// Плашка рабочих часов под шапкой.
struct OfficeHoursBar: View {
    let text: String
    let online: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(online ? RespondoPalette.dotOnline : RespondoPalette.dotOffline).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12)).foregroundColor(RespondoPalette.subtleInk)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(RespondoPalette.background)
    }
}

/// Баннер эскалации с кнопкой возврата к AI.
struct EscalationBanner: View {
    let agentHasReplied: Bool
    let theme: ResolvedTheme
    let strings: UIStrings
    let onContinueWithAI: () -> Void
    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(RespondoPalette.dotOnline).frame(width: 7, height: 7)
                Text(agentHasReplied ? strings("agentIsHere") : strings("waitingForAgent"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(RespondoPalette.ink)
            }
            Spacer()
            Button(action: onContinueWithAI) {
                Text(strings("continueWithAI"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryColor.swiftUIColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(RespondoPalette.assistantBubble)
    }
}

/// Инлайн-сбор email перед ответом (email_collector кампания).
struct EmailCollectorView: View {
    let theme: ResolvedTheme
    let strings: UIStrings
    let onSubmit: (String) -> Void
    @State private var email = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(strings("emailCollectorPrompt")).font(.system(size: 13)).foregroundColor(RespondoPalette.ink)
            HStack {
                TextField(strings("emailCollectorPlaceholder"), text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .font(.system(size: 15))
                Button(strings("emailSubmit")) {
                    if ConversationController.isValidEmail(email.trimmingCharacters(in: .whitespaces)) {
                        onSubmit(email); invalid = false
                    } else { invalid = true }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryColor.swiftUIColor)
            }
            if invalid {
                Text(strings("emailInvalid")).font(.system(size: 11)).foregroundColor(.red)
            }
        }
        .padding(12)
        .background(RespondoPalette.assistantBubble)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }
}

/// Чипы быстрых/предложенных вопросов.
struct QuestionChips: View {
    let questions: [String]
    let theme: ResolvedTheme
    let onTap: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(questions, id: \.self) { question in
                    Button { onTap(question) } label: {
                        Text(question)
                            .font(.system(size: 13))
                            .foregroundColor(theme.primaryColor.swiftUIColor)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(theme.primaryColor.swiftUIColor.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}
#endif
