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
                        HStack(spacing: 6) {
                            Text(author)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(RespondoPalette.subtleInk)
                            Text(MessageDateFormatter.timeLabel(message.createdAt, lang: strings.lang))
                                .font(.system(size: 10))
                                .foregroundColor(RespondoPalette.subtleInk)
                        }
                    }
                    bubbleContent
                    attachmentsView
                    sourcesView
                    if isUser {
                        deliveryStatusView
                    } else if message.authorName?.isEmpty != false {
                        Text(MessageDateFormatter.timeLabel(message.createdAt, lang: strings.lang))
                            .font(.system(size: 10))
                            .foregroundColor(RespondoPalette.subtleInk)
                    }
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
                    Button {
                        if Markdown.isSafeLink(source.url), let url = URL(string: source.url) {
                            onSourceTap(url)
                        }
                    } label: {
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
        HStack(spacing: 6) {
            Text(MessageDateFormatter.timeLabel(message.createdAt, lang: strings.lang))
                .font(.system(size: 10))
                .foregroundColor(RespondoPalette.subtleInk)
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
    }

    /// Centered day marker used by ChatView between messages from different
    /// local calendar days.
    static func dateSeparator(_ message: ChatMessage, strings: UIStrings) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(RespondoPalette.hairline).frame(height: 1)
            Text(MessageDateFormatter.dayLabel(message.createdAt, lang: strings.lang))
                .font(.system(size: 11))
                .foregroundColor(RespondoPalette.subtleInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RespondoPalette.assistantBubble)
                .clipShape(Capsule())
            Rectangle().fill(RespondoPalette.hairline).frame(height: 1)
        }
        .padding(.vertical, 6)
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

/// Оценка беседы (behavior.md §12): «How was your experience?» и пять
/// кружков 1–5 в конце ленты закрытой беседы, выбранный — цветом бренда.
/// После выбора — «спасибо» и необязательный отзыв («Tell us more»): поле на
/// 3 строки и Send цветом бренда; без Skip — не написать и есть пропуск.
/// После отправки — отзыв одной строкой и Edit, пока правка доступна; Edit
/// ставит курсор в поле, уход из поля без изменений возвращает строку отзыва.
struct RatingBlockView: View {
    let rating: ConversationRating
    let theme: ResolvedTheme
    let saving: Bool
    let remarkSaving: Bool
    let label: (String) -> String
    let onRate: (Int) -> Void
    let onSendRemark: (String) async -> Bool
    let onEditRemark: () -> Void
    let onCancelEdit: () -> Void

    /// Потолок отзыва — как у сервера (conversation.MaxRemarkRunes).
    static let remarkMax = 1000

    @State private var draft = ""
    @FocusState private var remarkFocused: Bool

    private var typing: Bool { rating.remarkStep == .open || rating.remarkStep == .editing }
    private var canSend: Bool {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !remarkSaving && !t.isEmpty && t != rating.remark
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(label("ratingQuestion"))
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(RespondoPalette.ink)
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { n in
                    Button { onRate(n) } label: {
                        Text("\(n)")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 32, height: 32)
                            .foregroundColor(rating.value == n ? theme.onPrimaryColor.swiftUIColor : RespondoPalette.ink)
                            .background(Circle().fill(rating.value == n ? theme.primaryColor.swiftUIColor : Color.white))
                            .overlay(Circle().stroke(rating.value == n ? theme.primaryColor.swiftUIColor : Color(white: 0.85), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)
                    .accessibilityLabel("\(n) / 5")
                    .accessibilityAddTraits(rating.value == n ? .isSelected : [])
                }
            }
            if rating.value > 0 {
                Text(label("ratingThanks")).font(.system(size: 12)).foregroundColor(.secondary)
            }
            if rating.remarkVisible && typing && rating.remarkEditable {
                VStack(alignment: .leading, spacing: 6) {
                    Text(label("ratingRemarkPrompt")).font(.system(size: 12, weight: .medium)).foregroundColor(RespondoPalette.ink)
                    // TextEditor (iOS 15): поле на 3 строки, плейсхолдер — поверх.
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $draft)
                            .font(.system(size: 14))
                            .frame(height: 68)
                            .disabled(remarkSaving)
                            .focused($remarkFocused)
                        if draft.isEmpty {
                            Text(label("ratingRemarkPlaceholder"))
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.85), lineWidth: 1))
                        .onChange(of: draft) { value in
                            if value.unicodeScalars.count > Self.remarkMax {
                                draft = String(String.UnicodeScalarView(value.unicodeScalars.prefix(Self.remarkMax)))
                            }
                        }
                    HStack {
                        Spacer()
                        Button(label("ratingSend")) {
                            let text = draft
                            Task { if await onSendRemark(text) { draft = "" } }
                        }
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 14).frame(height: 32)
                        .foregroundColor(theme.onPrimaryColor.swiftUIColor)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.primaryColor.swiftUIColor))
                        .opacity(canSend ? 1 : 0.5)
                        .disabled(!canSend)
                    }
                }
                .frame(maxWidth: 320)
            }
            if rating.value > 0 && rating.remarkStep == .sent && !rating.remark.isEmpty {
                HStack(spacing: 8) {
                    Text(rating.remark).font(.system(size: 14)).lineLimit(1).truncationMode(.tail)
                        .foregroundColor(RespondoPalette.ink)
                    Spacer(minLength: 0)
                    if rating.remarkEditable {
                        Button(label("ratingEdit"), action: onEditRemark)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).frame(height: 28)
                            .foregroundColor(RespondoPalette.ink)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.85), lineWidth: 1))
                    }
                }
                .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onChange(of: rating.remarkStep) { step in
            // Правка начинается с сохранённого отзыва, курсор — в поле.
            if step == .editing {
                draft = rating.remark
                remarkFocused = true
            }
        }
        .onChange(of: remarkFocused) { focused in
            // Поле правки покинули без изменений — назад к строке отзыва.
            guard !focused, rating.remarkStep == .editing, !remarkSaving else { return }
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == rating.remark { onCancelEdit() }
        }
    }
}
#endif
