import Foundation

/// Параметры владения беседой, реплеящиеся во все ownership-точки
/// (query REST-эндпоинтов, тело `/chat`, кадры WS).
struct OwnershipParams {
    var sessionToken: String?
    var userHash: String?
    var visitorId: String?

    var query: [String: String?] {
        [
            "session_token": sessionToken,
            "user_hash": userHash,
            "visitor_id": visitorId,
        ]
    }
}

/// Параметры резолва контакта для engagement-эндпоинтов (news/surveys/banners/checklists).
/// Разные ручки принимают разные подмножества — отсюда несколько срезов `query`.
struct EngagementParams {
    var agentId: String?
    var channelId: String?
    var conversationId: String?
    var visitorId: String?
    var email: String?
    var userId: String?
    var userHash: String?

    /// Для `/widget/news` и `/widget/news/:id/seen` (резолв по беседе ИЛИ агент+личность).
    var resolveQuery: [String: String?] {
        [
            "conversation_id": conversationId,
            "agent_id": agentId,
            "email": email,
            "user_id": userId,
            "user_hash": userHash,
            "visitor_id": visitorId,
        ]
    }

    /// Для `/widget/surveys` и `/widget/banners` (channel_id обязателен).
    var catalogQuery: [String: String?] {
        [
            "agent_id": agentId,
            "channel_id": channelId,
            "conversation_id": conversationId,
            "visitor_id": visitorId,
            "email": email,
            "user_id": userId,
        ]
    }

    /// Для `/widget/checklists` (channel_id обязателен, user_hash для identity_secret).
    var checklistQuery: [String: String?] {
        [
            "channel_id": channelId,
            "agent_id": agentId,
            "visitor_id": visitorId,
            "email": email,
            "user_id": userId,
            "user_hash": userHash,
        ]
    }
}

/// Тонкий REST-клиент поверх `HttpEngine` + `Endpoints`.
/// Кодирует/декодирует DTO, добавляет `User-Agent` и обрабатывает не-2xx в `TransportError`.
final class ApiClient: Sendable {
    private let engine: HttpEngine
    let endpoints: Endpoints

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    init(engine: HttpEngine, baseUrl: String?) {
        self.engine = engine
        self.endpoints = Endpoints(baseUrl: baseUrl)
    }

    // MARK: - Конфиг

    func widgetConfig(agentId: String, channelId: String?, lang: String, visitorId: String) async throws -> WidgetConfigDTO {
        let url = endpoints.api("/api/v1/widget/config/\(agentId)", query: [
            "channel_id": channelId,
            "lang": lang,
            "visitor_id": visitorId,
        ])
        return try await get(url)
    }

    func widgetConfigByChannel(channelId: String, lang: String, visitorId: String) async throws -> WidgetConfigDTO {
        let url = endpoints.api("/api/v1/widget/config-by-channel/\(channelId)", query: [
            "lang": lang,
            "visitor_id": visitorId,
        ])
        return try await get(url)
    }

    // MARK: - Чат

    func chat(_ body: ChatRequestDTO) async throws -> ChatResponseDTO {
        let url = endpoints.api("/api/v1/chat")
        return try await post(url, body: body, timeout: 20)
    }

    func upload(fileName: String, mimeType: String, data: Data) async throws -> ChatAttachmentDTO {
        let url = endpoints.api("/api/v1/chat/upload")
        let boundary = "respondo-\(UUID().uuidString)"
        var payload = Data()
        func append(_ string: String) { payload.append(string.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        payload.append(data)
        append("\r\n--\(boundary)--\r\n")

        var request = HttpRequest(method: .post, url: url, body: payload, timeout: 60)
        request.headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
        applyCommonHeaders(&request)
        let response = try await engine.send(request)
        try ensureOK(response)
        return try decode(response.data)
    }

    func resume(
        conversationId: String?,
        ownership: OwnershipParams,
        agentId: String?,
        channelId: String?,
        email: String?,
        userId: String?,
        limit: Int = 20
    ) async throws -> ResumeResponseDTO? {
        let url = endpoints.api("/api/v1/chat/resume", query: [
            "conversation_id": conversationId,
            "session_token": ownership.sessionToken,
            "user_hash": ownership.userHash,
            "visitor_id": ownership.visitorId,
            "agent_id": agentId,
            "channel_id": channelId,
            "email": email,
            "user_id": userId,
            "limit": String(limit),
        ])
        var request = HttpRequest(method: .get, url: url)
        applyCommonHeaders(&request)
        let response = try await engine.send(request)
        // 204 → восстанавливать нечего.
        if response.status == 204 { return nil }
        try ensureOK(response)
        return try decode(response.data)
    }

    func history(conversationId: String, before: String, ownership: OwnershipParams, limit: Int = 20) async throws -> HistoryResponseDTO {
        let url = endpoints.api("/api/v1/chat/history", query: [
            "conversation_id": conversationId,
            "before": before,
            "session_token": ownership.sessionToken,
            "user_hash": ownership.userHash,
            "visitor_id": ownership.visitorId,
            "limit": String(limit),
        ])
        return try await get(url)
    }

    func messages(conversationId: String, after: String?, ownership: OwnershipParams) async throws -> WidgetMessagesResponseDTO {
        var query = ownership.query
        query["after"] = after
        let url = endpoints.api("/api/v1/chat/conversations/\(conversationId)/messages", query: query)
        return try await get(url)
    }

    func escalate(conversationId: String, ownership: OwnershipParams) async throws -> EscalationResponseDTO {
        let url = endpoints.api("/api/v1/chat/conversations/\(conversationId)/escalate", query: ownership.query)
        return try await postEmpty(url)
    }

    func continueWithAI(conversationId: String, ownership: OwnershipParams) async throws {
        let url = endpoints.api("/api/v1/chat/conversations/\(conversationId)/continue", query: ownership.query)
        let _: EmptyResponse = try await postEmpty(url)
    }

    func revokeSession(conversationId: String, ownership: OwnershipParams) async throws {
        let url = endpoints.api("/api/v1/chat/conversations/\(conversationId)/revoke-session", query: ownership.query)
        let _: EmptyResponse = try await postEmpty(url)
    }

    // MARK: - SSE

    func streamEvents(conversationId: String, ownership: OwnershipParams) async throws -> (HttpResponse, AsyncThrowingStream<String, Error>) {
        let url = endpoints.api("/api/v1/chat/conversations/\(conversationId)/stream", query: ownership.query)
        var request = HttpRequest(method: .get, url: url)
        applyCommonHeaders(&request)
        return try await engine.stream(request)
    }

    // MARK: - Track / Push

    func track(_ body: TrackEventRequestDTO) async throws {
        let url = endpoints.api("/api/v1/widget/events")
        let _: EmptyResponse = try await post(url, body: body)
    }

    func pushRegister(_ body: PushRegisterRequestDTO) async throws {
        let url = endpoints.api("/api/v1/widget/push/register")
        let _: EmptyResponse = try await post(url, body: body)
    }

    func pushUnregister(_ body: PushUnregisterRequestDTO) async throws {
        let url = endpoints.api("/api/v1/widget/push/unregister")
        let _: EmptyResponse = try await post(url, body: body)
    }

    func pushOpened(_ body: PushOpenedRequestDTO) async throws {
        let url = endpoints.api("/api/v1/widget/push/opened")
        let _: EmptyResponse = try await post(url, body: body)
    }

    // MARK: - Engagement

    func widgetNews(_ params: EngagementParams) async throws -> NewsListResponseDTO {
        let url = endpoints.api("/api/v1/widget/news", query: params.resolveQuery)
        return try await get(url)
    }

    func widgetNewsSeen(id: String, params: EngagementParams) async throws {
        let url = endpoints.api("/api/v1/widget/news/\(id)/seen", query: params.resolveQuery)
        let _: OkResponseDTO = try await postEmpty(url)
    }

    func widgetSurveys(_ params: EngagementParams) async throws -> SurveysCatalogResponseDTO {
        let url = endpoints.api("/api/v1/widget/surveys", query: params.catalogQuery)
        return try await get(url)
    }

    func surveyAnswer(_ body: SubmitAnswerRequestDTO) async throws -> SurveyAnswerResultDTO {
        let url = endpoints.api("/api/v1/widget/survey/answer")
        return try await post(url, body: body)
    }

    func surveySubmit(_ body: SubmitSurveyRequestDTO) async throws -> SurveyAnswerResultDTO {
        let url = endpoints.api("/api/v1/widget/survey/submit")
        return try await post(url, body: body)
    }

    func widgetBanners(_ params: EngagementParams) async throws -> BannersCatalogResponseDTO {
        let url = endpoints.api("/api/v1/widget/banners", query: params.catalogQuery)
        return try await get(url)
    }

    func bannerResponse(_ body: BannerResponseRequestDTO) async throws {
        let url = endpoints.api("/api/v1/widget/banner/response")
        let _: OkResponseDTO = try await post(url, body: body)
    }

    func widgetChecklists(_ params: EngagementParams) async throws -> ChecklistsCatalogResponseDTO {
        let url = endpoints.api("/api/v1/widget/checklists", query: params.checklistQuery)
        return try await get(url)
    }

    func checklistProgress(id: String, body: ChecklistProgressRequestDTO) async throws {
        let url = endpoints.api("/api/v1/widget/checklists/\(id)/progress")
        let _: OkResponseDTO = try await post(url, body: body)
    }

    /// Проактивное сообщение под текущий экран. 204 → nil.
    func proactive(agentId: String, pageTitle: String?, pagePath: String?, pageDescription: String?, lang: String) async throws -> ProactiveResponseDTO? {
        let url = endpoints.api("/api/v1/widget/proactive/\(agentId)", query: [
            "page_title": pageTitle,
            "page_path": pagePath,
            "page_description": pageDescription,
            "lang": lang,
        ])
        var request = HttpRequest(method: .get, url: url)
        applyCommonHeaders(&request)
        let response = try await engine.send(request)
        if response.status == 204 { return nil }
        try ensureOK(response)
        return try decode(response.data)
    }

    // MARK: - Низкоуровневые помощники

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = HttpRequest(method: .get, url: url)
        applyCommonHeaders(&request)
        let response = try await engine.send(request)
        try ensureOK(response)
        return try decode(response.data)
    }

    private func post<Body: Encodable, T: Decodable>(_ url: URL, body: Body, timeout: TimeInterval? = nil) async throws -> T {
        var request = HttpRequest(method: .post, url: url, body: try Self.encoder.encode(body), timeout: timeout)
        request.headers["Content-Type"] = "application/json"
        applyCommonHeaders(&request)
        let response = try await engine.send(request)
        try ensureOK(response)
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        return try decode(response.data)
    }

    private func postEmpty<T: Decodable>(_ url: URL) async throws -> T {
        var request = HttpRequest(method: .post, url: url)
        request.headers["Content-Type"] = "application/json"
        applyCommonHeaders(&request)
        let response = try await engine.send(request)
        try ensureOK(response)
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        return try decode(response.data)
    }

    private func applyCommonHeaders(_ request: inout HttpRequest) {
        request.headers["User-Agent"] = SdkVersion.userAgent
        request.headers["Accept"] = request.headers["Accept"] ?? "application/json"
    }

    private func ensureOK(_ response: HttpResponse) throws {
        guard !(200...299).contains(response.status) else { return }
        let message = (try? Self.decoder.decode(BackendError.self, from: response.data))?.error
        throw TransportError.backend(status: response.status, message: message)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw TransportError.decoding(String(describing: error))
        }
    }
}

/// Пустой ответ — для эндпоинтов без тела, важного клиенту.
struct EmptyResponse: Decodable {}
