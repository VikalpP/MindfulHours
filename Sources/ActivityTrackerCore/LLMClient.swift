import Foundation

public struct LLMConfiguration: Sendable, Equatable {
    public var baseURL: URL
    public var apiKey: String
    public var model: String

    public init(baseURL: URL, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }
}

public enum LLMError: Error, LocalizedError {
    case notConfigured
    case http(status: Int, body: String)
    case emptyResponse
    case truncated
    case unparseableReply(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Set the proxy URL and model in Settings"
        case .http(let status, let body): "HTTP \(status): \(body.prefix(300))"
        case .emptyResponse: "Model returned no content"
        case .truncated: "Model hit max_tokens before answering"
        case .unparseableReply(let reply): "Unparseable reply: \(reply.prefix(200))"
        }
    }
}

/// Speaks the OpenAI Chat Completions dialect, which CLIProxyAPI (and most other gateways) expose for every provider.
public struct LLMClient: Sendable {
    public var configuration: LLMConfiguration
    private let session: URLSession

    public init(configuration: LLMConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    /// `reasoningEffort` maps to the provider's thinking budget; backends that reject the parameter are retried without it.
    public func complete(system: String, user: String, imageJPEG: Data? = nil, maxTokens: Int = 1024, reasoningEffort: String? = nil) async throws -> String {
        var userContent: [[String: Any]] = [["type": "text", "text": user]]
        if let imageJPEG {
            userContent.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())"],
            ])
        }
        var body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": maxTokens,
            "temperature": 0.2,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent],
            ],
        ]

        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }

        let data: Data
        do {
            data = try await send(chatRequest(body))
        } catch LLMError.http(400, let message) where reasoningEffort != nil && message.contains("reasoning") {
            body["reasoning_effort"] = nil
            data = try await send(chatRequest(body))
        }

        let choice = try JSONDecoder().decode(ChatCompletionResponse.self, from: data).choices.first
        guard let content = choice?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw choice?.finishReason == "length" ? LLMError.truncated : LLMError.emptyResponse
        }
        return content
    }

    public func availableModels() async throws -> [String] {
        let data = try await send(authorizedRequest(path: "models"))
        return try JSONDecoder().decode(ModelList.self, from: data).data.map(\.id).sorted()
    }

    private func chatRequest(_ body: [String: Any]) throws -> URLRequest {
        var request = authorizedRequest(path: "chat/completions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90
        return request
    }

    private func authorizedRequest(path: String) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
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

private struct ModelList: Decodable {
    struct Model: Decodable {
        let id: String
    }
    let data: [Model]
}
