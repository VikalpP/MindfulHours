import Foundation

public enum LLMDialect: Sendable, Equatable {
    /// OpenAI Chat Completions, which most gateways and local servers expose.
    case chatCompletions
    /// Anthropic's Chat Completions compatibility layer: `reasoning_effort` is ignored there, so thinking is turned off with `thinking`.
    case anthropic
    /// OpenAI Responses API, the only API that accepts Sign in with ChatGPT tokens; it must stream and must not store.
    case responses
}

public struct LLMConfiguration: Sendable, Equatable {
    public var baseURL: URL
    public var apiKey: String
    public var model: String
    public var dialect: LLMDialect

    public init(baseURL: URL, apiKey: String, model: String, dialect: LLMDialect = .chatCompletions) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.dialect = dialect
    }
}

public enum LLMError: Error, LocalizedError {
    case notConfigured
    case http(status: Int, body: String)
    case emptyResponse
    case truncated
    case failed(String)
    case unparseableReply(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Choose an AI provider and model in Settings"
        case .http(let status, let body): "HTTP \(status): \(body.prefix(300))"
        case .emptyResponse: "Model returned no content"
        case .truncated: "Model hit max_tokens before answering"
        case .failed(let message): message
        case .unparseableReply(let reply): "Unparseable reply: \(reply.prefix(200))"
        }
    }
}

public struct LLMClient: Sendable {
    private static let relaxationsByEndpoint = RelaxationMemory()

    public var configuration: LLMConfiguration
    private let session: URLSession

    public init(configuration: LLMConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    /// `reasoningEffort: "none"` turns hidden reasoning off. Parameters a backend rejects are dropped, and remembered per model.
    public func complete(system: String, user: String, imageJPEG: Data? = nil, maxTokens: Int = 1024, reasoningEffort: String? = nil) async throws -> String {
        let endpoint = "\(configuration.baseURL.absoluteString) \(configuration.model)"
        var relaxations = await Self.relaxationsByEndpoint.relaxations(for: endpoint)
        let request = LLMRequestBody(dialect: configuration.dialect, model: configuration.model, system: system, user: user,
                                     imageJPEG: imageJPEG, maxTokens: maxTokens, reasoningEffort: reasoningEffort)

        // Each retry adds a different relaxation, so this ends after at most one attempt per relaxation.
        for _ in 0...ParameterRelaxation.allCases.count {
            let body = relaxations.reduce(request.fields) { $1.apply(to: $0) }
            do {
                return try await send(body)
            } catch LLMError.http(400, let message) {
                guard let relaxation = ParameterRelaxation.allCases.first(where: { !relaxations.contains($0) && $0.isRejected(in: body, message: message) }) else {
                    throw LLMError.http(status: 400, body: message)
                }
                relaxations.append(relaxation)
                await Self.relaxationsByEndpoint.remember(relaxations, for: endpoint)
            }
        }
        throw LLMError.emptyResponse
    }

    public func availableModels() async throws -> [String] {
        let data = try await data(for: authorizedRequest(path: "models"))
        return try ModelList.ids(from: data)
    }

    private func send(_ body: [String: Any]) async throws -> String {
        var request = authorizedRequest(path: configuration.dialect == .responses ? "responses" : "chat/completions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90

        guard configuration.dialect == .responses else {
            let choice = try JSONDecoder().decode(ChatCompletionResponse.self, from: try await data(for: request)).choices.first
            guard let content = choice?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
                throw choice?.finishReason == "length" ? LLMError.truncated : LLMError.emptyResponse
            }
            return content
        }

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var errorBody = Data()
            for try await byte in bytes { errorBody.append(byte) }
            throw LLMError.http(status: status, body: String(decoding: errorBody, as: UTF8.self))
        }
        var stream = ResponsesEventStream()
        for try await line in bytes.lines {
            if let text = try stream.consume(line) { return text }
        }
        throw LLMError.failed("The response stream ended before the model finished")
    }

    private func authorizedRequest(path: String) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        guard !configuration.apiKey.isEmpty else { return request }
        if configuration.dialect == .anthropic {
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

struct LLMRequestBody {
    let dialect: LLMDialect
    let model: String
    let system: String
    let user: String
    let imageJPEG: Data?
    let maxTokens: Int
    let reasoningEffort: String?

    var fields: [String: Any] {
        let imageURL = imageJPEG.map { "data:image/jpeg;base64,\($0.base64EncodedString())" }
        switch dialect {
        case .responses:
            var content: [[String: Any]] = [["type": "input_text", "text": user]]
            if let imageURL { content.append(["type": "input_image", "image_url": imageURL]) }
            // Sign in with ChatGPT rejects max_output_tokens and temperature, and requires store: false and stream: true.
            var fields: [String: Any] = [
                "model": model,
                "instructions": system,
                "input": [["role": "user", "content": content]],
                "store": false,
                "stream": true,
            ]
            if let reasoningEffort { fields["reasoning"] = ["effort": reasoningEffort] }
            return fields

        case .chatCompletions, .anthropic:
            var content: [[String: Any]] = [["type": "text", "text": user]]
            if let imageURL { content.append(["type": "image_url", "image_url": ["url": imageURL]]) }
            var fields: [String: Any] = [
                "model": model,
                "max_tokens": maxTokens,
                "stream": false,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": content],
                ],
            ]
            if dialect == .anthropic {
                // Claude 5 models reject any temperature below 1 and think by default.
                if reasoningEffort == "none" { fields["thinking"] = ["type": "disabled"] }
            } else {
                fields["temperature"] = 0.2
                if let reasoningEffort { fields["reasoning_effort"] = reasoningEffort }
            }
            return fields
        }
    }
}

/// Optional parameters that some backends reject with a 400 naming the parameter.
enum ParameterRelaxation: CaseIterable, Sendable {
    case dropReasoning
    case dropThinking
    case dropTemperature
    case useMaxCompletionTokens

    func isRejected(in body: [String: Any], message: String) -> Bool {
        let message = message.lowercased()
        return switch self {
        case .dropReasoning: (body["reasoning_effort"] != nil || body["reasoning"] != nil) && message.contains("reasoning")
        case .dropThinking: body["thinking"] != nil && message.contains("thinking")
        case .dropTemperature: body["temperature"] != nil && message.contains("temperature")
        case .useMaxCompletionTokens: body["max_tokens"] != nil && message.contains("max_tokens")
        }
    }

    func apply(to body: [String: Any]) -> [String: Any] {
        var body = body
        switch self {
        case .dropReasoning:
            body["reasoning_effort"] = nil
            body["reasoning"] = nil
        case .dropThinking:
            body["thinking"] = nil
        case .dropTemperature:
            body["temperature"] = nil
        case .useMaxCompletionTokens:
            body["max_completion_tokens"] = body.removeValue(forKey: "max_tokens")
        }
        return body
    }
}

private actor RelaxationMemory {
    private var relaxationsByEndpoint: [String: [ParameterRelaxation]] = [:]

    func relaxations(for endpoint: String) -> [ParameterRelaxation] {
        relaxationsByEndpoint[endpoint] ?? []
    }

    func remember(_ relaxations: [ParameterRelaxation], for endpoint: String) {
        relaxationsByEndpoint[endpoint] = relaxations
    }
}

/// Server-sent events from a streaming Responses API call.
struct ResponsesEventStream {
    private(set) var text = ""

    /// Returns the full reply once the response completes.
    mutating func consume(_ line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let event = try? JSONDecoder().decode(ResponsesEvent.self, from: Data(payload.utf8)) else { return nil }

        switch event.type {
        case "response.output_text.delta":
            text += event.delta ?? ""
            return nil
        case "response.completed":
            let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else { throw LLMError.emptyResponse }
            return reply
        case "response.incomplete":
            throw LLMError.truncated
        case "response.failed", "error":
            throw LLMError.failed(event.response?.error?.message ?? event.message ?? "The model request failed")
        default:
            return nil
        }
    }
}

private struct ResponsesEvent: Decodable {
    struct Response: Decodable {
        struct Failure: Decodable {
            let message: String?
        }
        let error: Failure?
    }
    let type: String
    let delta: String?
    let message: String?
    let response: Response?
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message
        let finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]
}

/// OpenAI-style `{"data": [{"id"}]}`, or Sign in with ChatGPT's `{"models": [{"slug", "visibility"}]}` in recommended order.
enum ModelList {
    private struct OpenAIStyle: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    private struct ChatGPTStyle: Decodable {
        struct Model: Decodable {
            let slug: String
            let visibility: String?
        }
        let models: [Model]
    }

    static func ids(from data: Data) throws -> [String] {
        if let chatGPT = try? JSONDecoder().decode(ChatGPTStyle.self, from: data) {
            return chatGPT.models.filter { ($0.visibility ?? "list") == "list" }.map(\.slug)
        }
        // Gemini lists "models/gemini-…" but expects the bare name in requests.
        return try JSONDecoder().decode(OpenAIStyle.self, from: data).data
            .map { $0.id.hasPrefix("models/") ? String($0.id.dropFirst("models/".count)) : $0.id }
            .sorted()
    }
}
