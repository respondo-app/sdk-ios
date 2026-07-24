import Foundation
import Combine

/// Чат-ядро одного канала: тред сообщений, оптимистичная отправка, история, unread,
/// эскалация, спец-сообщения. `@MainActor` + `ObservableObject` — UI-слой (SwiftUI)
/// подписывается напрямую, эмиссия на главном потоке.
@MainActor
public final class ConversationController: ObservableObject {
    // MARK: - Публичное состояние (для UI)

    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var typingAuthor: String?
    @Published public private(set) var isEscalated = false
    @Published public private(set) var agentHasReplied = false
    @Published public private(set) var suggestedQuestions: [String] = []
    @Published public private(set) var theme: ResolvedTheme
    @Published public private(set) var lang: String
    @Published public private(set) var officeHoursText: String?
    @Published public private(set) var needsEmail = false
    @Published public private(set) var pendingFiles: [ChatAttachment] = []
    @Published public private(set) var historyHasMore = false

    /// Максимальная длина исходящего сообщения. Серверный контракт `POST /api/v1/chat`
    /// валидирует `message` как `min=1,max=750` (chat_dto.go). Go считает длину в РУНАХ
    /// (`utf8.RuneCountInString` = code points), поэтому SDK обрезает по Unicode-скалярам,
    /// а не по символам-графемам (иначе один составной эмодзи-кластер = много рун → 400).
    public static let maxMessageLength = 750

    /// Обрезает текст до `maxMessageLength` Unicode-скаляров (рун), не разрывая ни один
    /// скаляр (суррогатные пары остаются целыми). Составной грапемный кластер может быть
    /// усечён на границе скаляра — это валидный Unicode и соответствует счёту рун в Go.
    static func clampedMessage(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > maxMessageLength else { return text }
        return String(String.UnicodeScalarView(scalars.prefix(maxMessageLength)))
    }

    // MARK: - Зависимости

    private let apiClient: ApiClient
    private let realtime: RealtimeClient
    private let cache: ConversationCache
    private let identityStore: IdentityStore
    private let agentId: String
    private let channelId: String?
    weak var host: ConversationHost?

    // MARK: - Внутреннее состояние

    private(set) var conversationId: String?
    private var historyConversationId: String?
    private var oldestMessageId: String?
    private var lastBackendMessageId: String?

    /// Последний серверный id восстановленной беседы — движок засевает им курс
    /// поллинга, чтобы фолбэк WS→поллинг не перечитывал уже показанные сообщения.
    var lastRestoredBackendMessageId: String? { lastBackendMessageId }
    private var collectedEmail: String?
    private var typingResetTask: Task<Void, Never>?
    private var readDebounceTask: Task<Void, Never>?
    private var resolveResetTask: Task<Void, Never>?
    /// Тикает ли уже таймер сброса беседы после `resolved`. Повторные resolved-события
    /// (WS + поллинг для одной беседы) не перепланируют таймер, иначе сброс уезжает.
    private var resolveResetPending = false
    /// Сколько раз реально был взведён таймер сброса (диагностика P3-2 «не перепланируем»).
    private(set) var resolveResetScheduleCount = 0
    private let strings = LocalizedStrings.shared

    init(
        apiClient: ApiClient,
        realtime: RealtimeClient,
        cache: ConversationCache,
        identityStore: IdentityStore,
        agentId: String,
        channelId: String?,
        theme: ResolvedTheme,
        lang: String
    ) {
        self.apiClient = apiClient
        self.realtime = realtime
        self.cache = cache
        self.identityStore = identityStore
        self.agentId = agentId
        self.channelId = channelId
        self.theme = theme
        self.lang = lang
        self.collectedEmail = identityStore.collectedEmail()
        refreshOfficeHours()
    }

    // MARK: - Применение темы/конфига

    func applyTheme(_ theme: ResolvedTheme) {
        self.theme = theme
        refreshOfficeHours()
    }

    private func refreshOfficeHours() {
        guard let office = theme.officeHours else { officeHoursText = nil; return }
        officeHoursText = OfficeHoursFormatter.availabilityText(office: office, lang: lang, strings: strings)
    }

    // MARK: - Стартовое восстановление

    /// Заполняет тред из кэша (быстрый старт), затем — из resume (источник правды).
    func bootstrap(cacheBlob: ConversationBlob?, resume: ResumeResponseDTO?) {
        if let blob = cacheBlob {
            conversationId = blob.conversationId
            isEscalated = blob.escalated
            messages = blob.messages
            lastBackendMessageId = blob.messages.last(where: { !$0.isLocal && $0.id.contains("-") })?.id
        }
        // resume сам сообщает host свежий session_token (источник правды); без resume
        // отдаём восстановленный из кэша id с ранее сохранённым токеном.
        if let resume {
            applyResume(resume)
        } else {
            host?.conversationDidChange(id: conversationId, sessionToken: host?.ownership().sessionToken)
        }
        if messages.isEmpty, theme.greetingEnabled, let greeting = theme.greeting, !greeting.isEmpty {
            // Приветственный пузырь ассистента (welcome). Не серверное сообщение — локальный id.
            messages = [ChatMessage(
                id: "greeting",
                role: .assistant,
                content: greeting,
                authorName: theme.agentName,
                authorAvatarURL: theme.avatarURL?.absoluteString,
                createdAt: Date(),
                isLocal: true
            )]
        }
        persist()
    }

    private func applyResume(_ resume: ResumeResponseDTO) {
        historyConversationId = resume.historyConversationId ?? resume.conversationId
        oldestMessageId = resume.oldestMessageId
        historyHasMore = resume.hasMore ?? false
        let restored = (resume.messages ?? []).map(MessageMapper.toChatMessage)
        if !restored.isEmpty {
            messages = restored.sorted { $0.createdAt < $1.createdAt }
            lastBackendMessageId = messages.last?.id
        }
        // Живой id/токен только для open/snoozed; иначе тред read-only.
        conversationId = resume.conversationId
        isEscalated = (resume.status == "escalated")
        // Свежий session_token из resume — источник правды: пробрасываем его в host,
        // чтобы он записался в хранилище ДО subscribe/history. Хранимый токен НЕ
        // затирает свежий; для живой беседы без токена в resume сохраняем прежний,
        // а для закрытой (conversationId == nil) отдаём nil — токен очистится.
        let freshToken: String?
        if let token = resume.sessionToken, !token.isEmpty {
            freshToken = token
        } else if conversationId != nil {
            freshToken = host?.ownership().sessionToken
        } else {
            freshToken = nil
        }
        host?.conversationDidChange(id: conversationId, sessionToken: freshToken)
    }

    // MARK: - Отправка

    /// Можно ли отправлять сейчас (email-collector блокирует до валидного email).
    public var canSend: Bool { !needsEmail || (collectedEmail?.isEmpty == false) }

    /// Оптимистичная отправка текстового сообщения (+ прикреплённые файлы).
    public func send(text rawText: String) {
        // Обрезаем до серверного лимита 750 рун (иначе бэкенд ответит 400).
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = Self.clampedMessage(trimmed)
        let files = pendingFiles
        guard !text.isEmpty || !files.isEmpty else { return }
        guard canSend else { return }

        // Контент пузыря: текст, либо перечисление имён файлов, если текста нет.
        let localId = String(Int(Date().timeIntervalSince1970 * 1000)) // без дефиса — признак локального id
        let bubbleContent = text.isEmpty ? files.map { $0.filename }.joined(separator: "\n") : text
        let apiMessage = text.isEmpty ? strings.string("fileSentPlaceholder", lang: lang) : text

        let optimistic = ChatMessage(
            id: localId,
            role: .user,
            content: bubbleContent,
            attachments: files,
            deliveryStatus: .sending,
            createdAt: Date(),
            isLocal: true
        )
        messages.append(optimistic)
        pendingFiles = []
        suggestedQuestions = []
        isLoading = true

        // Детект локали по тексту пользователя.
        if let detected = LocalizedStrings.detectFromText(text) { switchLang(detected) }

        Task { await performSend(localId: localId, apiMessage: apiMessage, attachments: files) }
    }

    /// Повтор отправки ранее упавшего сообщения.
    public func retry(messageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              messages[index].role == .user else { return }
        messages[index].deliveryStatus = .sending
        isLoading = true
        let content = messages[index].content
        let files = messages[index].attachments
        let apiMessage = content.isEmpty ? strings.string("fileSentPlaceholder", lang: lang) : content
        Task { await performSend(localId: messageId, apiMessage: apiMessage, attachments: files) }
    }

    private func performSend(localId: String, apiMessage: String, attachments: [ChatAttachment]) async {
        let identity = host?.currentIdentity() ?? RespondoIdentity()
        let auto = host?.autoMetadata() ?? [:]
        var metadata = auto
        for (key, value) in identity.metadata { metadata[key] = value } // host-значения приоритетнее

        let email = identity.email ?? collectedEmail
        let body = ChatRequestDTO(
            agentId: agentId,
            channelId: channelId,
            conversationId: conversationId,
            message: apiMessage,
            userEmail: email,
            source: SdkVersion.source,
            attachments: attachments.isEmpty ? nil : attachments.map {
                ChatAttachmentDTO(id: $0.id, filename: $0.filename, contentType: $0.contentType, size: $0.size, url: $0.url)
            },
            identity: ChatIdentityDTO(
                email: identity.email,
                name: identity.name,
                userId: identity.userId,
                userHash: identity.userHash,
                visitorId: identityStore.visitorId(),
                metadata: metadata,
                properties: identity.properties.isEmpty ? nil : identity.properties
            ),
            sessionToken: host?.ownership().sessionToken
        )

        do {
            let response = try await apiClient.chat(body)
            applyChatResponse(response, localId: localId)
        } catch {
            markFailed(localId: localId)
        }
        isLoading = false
    }

    private func applyChatResponse(_ response: ChatResponseDTO, localId: String) {
        // Пометить оптимистичное сообщение доставленным.
        if let index = messages.firstIndex(where: { $0.id == localId }) {
            messages[index].deliveryStatus = .sent
        }
        // Скользящее обновление беседы/токена.
        if let cid = response.conversationId, cid != conversationId {
            conversationId = cid
        }
        host?.conversationDidChange(id: response.conversationId ?? conversationId, sessionToken: response.sessionToken)

        let handover = response.humanHandover ?? false
        if handover {
            if !isEscalated {
                appendSystem(id: "escalation-\(localId)", content: strings.string("escalatedMessage", lang: lang))
                setEscalated(true)
            }
        }
        if let dto = response.message {
            let message = withDocLinks(MessageMapper.toChatMessage(dto), docLinks: response.docLinks)
            upsert(message)
            if message.isFromHumanAgent { agentHasReplied = true }
        }
        if theme.suggestedQuestionsEnabled, let questions = response.suggestedQuestions {
            suggestedQuestions = Array(questions.prefix(3))
        }
        // email-collector: если у последнего ответа reply_type=email_collector и email неизвестен.
        if let dto = response.message, dto.metadata?.replyType == "email_collector", (host?.currentIdentity().email ?? collectedEmail)?.isEmpty != false {
            needsEmail = true
        }
        persist()
    }

    private func withDocLinks(_ message: ChatMessage, docLinks: [DocLinkDTO]?) -> ChatMessage {
        guard let docLinks, !docLinks.isEmpty else { return message }
        var updated = message
        let extra = docLinks.compactMap { link -> ChatSource? in
            guard let title = link.title, let url = link.url,
                  let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return ChatSource(title: title, url: url)
        }
        updated.sources = (updated.sources + extra).reduced()
        return updated
    }

    private func markFailed(localId: String) {
        if let index = messages.firstIndex(where: { $0.id == localId }) {
            messages[index].deliveryStatus = .failed
        }
        // Веб-паритет: добавляем ассистентское сообщение об ошибке.
        appendSystem(id: "send-error-\(localId)", content: strings.string("networkError", lang: lang))
        persist()
    }

    // MARK: - Email-collector

    public func submitEmail(_ email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard Self.isValidEmail(trimmed) else { return }
        collectedEmail = trimmed
        identityStore.setCollectedEmail(trimmed)
        needsEmail = false
    }

    public static func isValidEmail(_ email: String) -> Bool {
        let pattern = "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$"
        return email.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Вложения

    /// Загружает файл и кладёт в pendingFiles (лимит 20 МБ проверяется вызывающим/бэкендом).
    public func attach(fileName: String, mimeType: String, data: Data) async -> Bool {
        guard data.count <= 20 * 1024 * 1024 else {
            RespondoLog.warn(strings.string("attachmentTooLarge", lang: lang))
            return false
        }
        do {
            let dto = try await apiClient.upload(fileName: fileName, mimeType: mimeType, data: data)
            pendingFiles.append(ChatAttachment(id: dto.id, filename: dto.filename, contentType: dto.contentType, size: dto.size, url: dto.url))
            return true
        } catch {
            RespondoLog.warn("upload failed: \(String(describing: error))")
            return false
        }
    }

    public func removePendingFile(id: String) {
        pendingFiles.removeAll { $0.id == id }
    }

    // MARK: - Suggested / quick questions

    public func sendSuggested(_ question: String) {
        send(text: question)
    }

    // MARK: - Эскалация

    public func escalate() async {
        guard let cid = conversationId, !isEscalated else { return }
        do {
            let response = try await apiClient.escalate(conversationId: cid, ownership: ownershipParams())
            var content = strings.string("escalatedMessage", lang: lang)
            if let ticket = response.ticketURL { content += "\n\(ticket)" }
            appendSystem(id: "handover-\(cid)", content: content)
            setEscalated(true)
            suggestedQuestions = []
        } catch {
            appendSystem(id: "escalate-error-\(cid)", content: strings.string("networkError", lang: lang))
        }
    }

    public func continueWithAI() async {
        guard let cid = conversationId else { return }
        // Даже при ошибке запроса переход разрешаем локально.
        try? await apiClient.continueWithAI(conversationId: cid, ownership: ownershipParams())
        setEscalated(false)
        agentHasReplied = false
        appendSystem(id: "back-to-ai-\(cid)", content: strings.string("backToAI", lang: lang))
    }

    // MARK: - История (пагинация вверх)

    public func loadOlder() async {
        guard historyHasMore, let cid = historyConversationId ?? conversationId, let before = oldestMessageId else { return }
        do {
            let page = try await apiClient.history(conversationId: cid, before: before, ownership: ownershipParams())
            let older = (page.messages ?? []).map(MessageMapper.toChatMessage)
            let existing = Set(messages.map(\.id))
            let deduped = older.filter { !existing.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
            if deduped.isEmpty {
                historyHasMore = false
            } else {
                messages.insert(contentsOf: deduped, at: 0)
                oldestMessageId = page.oldestMessageId ?? deduped.first?.id
                historyHasMore = page.hasMore ?? false
            }
        } catch let error as TransportError {
            if case .backend(let status, _) = error, status == 403 || status == 404 {
                historyHasMore = false // перестаём листать
            }
        } catch {
            // прочие ошибки — оставляем как есть, повторим позже
        }
    }

    /// Показывает проактив-тизер как первое сообщение ассистента (если тред пуст).
    public func showProactiveTeaser(_ text: String) {
        guard messages.isEmpty, !text.isEmpty else { return }
        messages.append(ChatMessage(id: "proactive-teaser", role: .assistant, content: text, createdAt: Date()))
    }

    // MARK: - Обработка реалтайм-событий

    func handle(_ event: RealtimeEvent) {
        switch event {
        case .newMessage(let dto):
            handleNewMessage(dto)
        case .messageUpdated(let patch):
            handleMessageUpdated(patch)
        case .statusChanged(let status):
            handleStatusChanged(status)
        case .typing(let author):
            handleTyping(author)
        case .conversationUpdated(_, let newLang):
            if let newLang { switchLang(newLang) }
        case .campaignConversation(let cid, let message):
            handleCampaign(conversationId: cid, message: message)
        case .subscribed:
            break
        case .overlayShow:
            break // обрабатывается engagement-слоем в движке
        case .error(let message):
            RespondoLog.warn("realtime error: \(message)")
        }
    }

    private func handleNewMessage(_ dto: MessageDTO) {
        // Фильтрация ролей user/visitor (уже отрисованы оптимистично), кроме survey-ответов.
        let role = dto.role
        let isSurveyAnswer = dto.metadata?.surveyStep != nil || dto.metadata?.surveyInline != nil
        if (role == "user" || role == "visitor") && !isSurveyAnswer { return }

        let message = MessageMapper.toChatMessage(dto)
        let isNew = upsert(message)
        if message.id.contains("-") { lastBackendMessageId = message.id }
        if message.isFromHumanAgent { agentHasReplied = true }
        isLoading = false
        clearTyping()
        if isNew, message.role != .user, host?.isPanelOpen != true {
            host?.bumpUnread(by: 1)
        }
        persist()
    }

    private func handleMessageUpdated(_ patch: MessagePatch) {
        guard let index = messages.firstIndex(where: { $0.id == patch.id }) else { return }
        if let status = patch.deliveryStatus, status == "failed" {
            messages[index].deliveryStatus = .failed
            if let error = patch.deliveryError, !error.isEmpty {
                RespondoLog.warn("доставка сообщения \(patch.id) не удалась: \(error)")
            }
        }
        persist()
    }

    private func handleStatusChanged(_ status: String) {
        switch status {
        case "escalated":
            setEscalated(true)
        case "agent", "bot":
            if isEscalated || status == "agent" {
                setEscalated(false)
                appendSystem(id: "back-to-ai-ws", content: strings.string("backToAI", lang: lang))
                agentHasReplied = false
            }
        case "resolved":
            appendSystem(id: "resolved-ws", content: strings.string("resolvedMessage", lang: lang))
            scheduleResolvedReset()
        default:
            break
        }
    }

    private func handleTyping(_ author: String?) {
        typingAuthor = author ?? theme.agentName ?? ""
        typingResetTask?.cancel()
        typingResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.clearTyping()
        }
    }

    private func clearTyping() {
        typingResetTask?.cancel(); typingResetTask = nil
        typingAuthor = nil
    }

    private func handleCampaign(conversationId cid: String, message: MessageDTO?) {
        // Адопция беседы, если своей ещё нет.
        if conversationId == nil {
            conversationId = cid
            host?.conversationDidChange(id: cid, sessionToken: host?.ownership().sessionToken)
        }
        if let message {
            // Unread учитывает сам handleNewMessage (новое сообщение не от пользователя
            // при закрытой панели → +1). Отдельный bump здесь давал двойной счёт.
            handleNewMessage(message)
        }
    }

    private func scheduleResolvedReset() {
        // Уже тикает для этого же resolved — не перевзводим (иначе сброс отодвигается).
        guard !resolveResetPending else { return }
        resolveResetPending = true
        resolveResetScheduleCount += 1
        resolveResetTask?.cancel()
        resolveResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            self.resolveResetPending = false
            self.resetConversationAfterResolve()
        }
    }

    private func resetConversationAfterResolve() {
        conversationId = nil
        isEscalated = false
        suggestedQuestions = []
        host?.conversationDidChange(id: nil, sessionToken: nil)
        host?.escalationDidChange(false)
        persist()
    }

    // MARK: - Read-квитанции

    /// Дебаунс 400мс: пачка входящих коллапсирует в один read-кадр.
    func scheduleRead() {
        guard host?.isPanelOpen == true, conversationId != nil else { return }
        readDebounceTask?.cancel()
        readDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self else { return }
            await self.realtime.sendRead()
        }
    }

    // MARK: - Открытие ссылок

    public func openURL(_ url: URL) {
        if host?.requestOpenURL(url) == true { return }
        #if canImport(UIKit)
        Task { @MainActor in
            await UIApplicationOpener.open(url)
        }
        #endif
    }

    // MARK: - Локаль

    private func switchLang(_ newLang: String) {
        let normalized = LocalizedStrings.normalize(newLang)
        guard normalized != lang else { return }
        lang = normalized
        identityStore.setLang(normalized)
        refreshOfficeHours()
        host?.languageDidChange(normalized)
    }

    // MARK: - Вспомогательное

    private func setEscalated(_ value: Bool) {
        isEscalated = value
        host?.escalationDidChange(value)
    }

    /// Вставляет или обновляет сообщение по id (дедуп). Возвращает true, если это новое сообщение.
    @discardableResult
    private func upsert(_ message: ChatMessage) -> Bool {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
            return false
        }
        // Новое сообщение: добавляем и восстанавливаем хронологический порядок по createdAt.
        // Оптимистичный пузырь пользователя не «схлопываем» по контенту — серверный
        // эквивалент с role=user/visitor отфильтрован в handleNewMessage.
        messages.append(message)
        messages.sort { $0.createdAt < $1.createdAt }
        return true
    }

    private func appendSystem(id: String, content: String) {
        guard !messages.contains(where: { $0.id == id }) else { return }
        messages.append(ChatMessage(id: id, role: .system, content: content, createdAt: Date(), isLocal: true))
    }

    private func ownershipParams() -> OwnershipParams {
        host?.ownership() ?? OwnershipParams()
    }

    private func persist() {
        cache.save(conversationId: conversationId, escalated: isEscalated, messages: messages)
    }

    /// Полностью очищает тред (при reset / повторном init).
    func clear() {
        typingResetTask?.cancel()
        readDebounceTask?.cancel()
        resolveResetTask?.cancel()
        resolveResetPending = false
        messages = []
        suggestedQuestions = []
        isLoading = false
        typingAuthor = nil
        isEscalated = false
        agentHasReplied = false
        needsEmail = false
        pendingFiles = []
        conversationId = nil
    }
}

private extension Array where Element == ChatSource {
    /// Дедуп источников по url с сохранением порядка.
    func reduced() -> [ChatSource] {
        var seen = Set<String>()
        return filter { seen.insert($0.url).inserted }
    }
}
