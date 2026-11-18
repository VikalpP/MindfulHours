import Foundation
import Testing
@testable import MindfulHoursCore

/// Serves canned responses to URLSessions built by `StubServer.session()`, recording each request.
private final class StubServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: (URLRequest, Data) -> (status: Int, body: String) = { _, _ in (500, "") }
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data)] = []

    static func session(_ respond: @escaping (URLRequest, Data) -> (status: Int, body: String)) -> URLSession {
        self.respond = respond
        requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }

    static func jsonBody(_ index: Int) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: requests[index].body)) as? [String: Any] ?? [:]
    }

    static func formBody(_ index: Int) -> [String: String] {
        let items = URLComponents(string: "?" + String(decoding: requests[index].body, as: UTF8.self))?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable, case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.requests.append((request, body))
        let (status, responseBody) = Self.respond(request, body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func jwt(_ claims: [String: Any]) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: claims)
    return "e30.\(payload.base64URLEncoded).c2ln"
}

private let chatCompletionReply = #"{"choices": [{"message": {"content": "ok"}, "finish_reason": "stop"}]}"#

@Suite struct AIProviderTests {
    @Test func prefersNewestSmallVisionModel() {
        #expect(AIProvider.claude.preferredModel(from: ["claude-opus-5-5", "claude-haiku-4-5", "claude-haiku-5-5"]) == "claude-haiku-5-5")
        #expect(AIProvider.ollama.preferredModel(from: ["llama3.1:8b", "qwen2.5vl:7b"]) == "qwen2.5vl:7b")
        #expect(AIProvider.openAI.preferredModel(from: ["gpt-5-mini-tts", "gpt-5-mini", "gpt-5.1-mini"]) == "gpt-5.1-mini")
        #expect(AIProvider.custom.preferredModel(from: ["b", "a"]) == "b")
        #expect(AIProvider.ollama.preferredModel(from: []) == nil)
    }

    @Test func keepsChatGPTRecommendedOrder() {
        #expect(AIProvider.chatGPT.preferredModel(from: ["gpt-6.1", "gpt-6.1-mini", "gpt-5-mini"]) == "gpt-6.1-mini")
    }

    @Test func parsesBothModelListShapes() throws {
        let openAIStyle = #"{"data": [{"id": "models/gemini-2.5-flash"}, {"id": "a-model"}]}"#
        #expect(try ModelList.ids(from: Data(openAIStyle.utf8)) == ["a-model", "gemini-2.5-flash"])

        let chatGPTStyle = #"{"models": [{"slug": "z", "visibility": "list"}, {"slug": "hidden", "visibility": "hide"}, {"slug": "a"}]}"#
        #expect(try ModelList.ids(from: Data(chatGPTStyle.utf8)) == ["z", "a"])
    }
}

@Suite struct LLMRequestTests {
    private func body(_ dialect: LLMDialect, image: Data? = nil) -> [String: Any] {
        LLMRequestBody(dialect: dialect, model: "m", system: "sys", user: "hi", imageJPEG: image, maxTokens: 100, reasoningEffort: "none").fields
    }

    @Test func anthropicTurnsThinkingOffAndOmitsTemperature() {
        let fields = body(.anthropic)
        #expect((fields["thinking"] as? [String: String]) == ["type": "disabled"])
        #expect(fields["temperature"] == nil)
        #expect(fields["reasoning_effort"] == nil)
    }

    @Test func responsesStreamsWithoutStoringOrTokenLimit() {
        let fields = body(.responses, image: Data([1, 2]))
        #expect(fields["store"] as? Bool == false)
        #expect(fields["stream"] as? Bool == true)
        #expect(fields["max_output_tokens"] == nil && fields["temperature"] == nil)
        #expect(fields["instructions"] as? String == "sys")
        let content = ((fields["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        #expect(content.map { $0["type"] as? String } == ["input_text", "input_image"])
        #expect((content.last?["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    @Test func relaxesOnlyTheRejectedParameter() {
        let fields = body(.chatCompletions)
        let message = "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."
        #expect(ParameterRelaxation.allCases.filter { $0.isRejected(in: fields, message: message) } == [.useMaxCompletionTokens])
        let relaxed = ParameterRelaxation.useMaxCompletionTokens.apply(to: fields)
        #expect(relaxed["max_tokens"] == nil && relaxed["max_completion_tokens"] as? Int == 100)
    }

    @Test func collectsStreamedTextUntilCompleted() throws {
        var stream = ResponsesEventStream()
        let lines = [
            "event: response.output_text.delta",
            #"data: {"type": "response.output_text.delta", "delta": "Hel"}"#,
            #"data: {"type": "response.output_text.delta", "delta": "lo"}"#,
        ]
        for line in lines { #expect(try stream.consume(line) == nil) }
        #expect(try stream.consume(#"data: {"type": "response.completed", "response": {}}"#) == "Hello")
    }

    @Test func reportsFailedStream() {
        var stream = ResponsesEventStream()
        #expect(throws: LLMError.self) {
            try stream.consume(#"data: {"type": "response.failed", "response": {"error": {"message": "usage limit"}}}"#)
        }
    }
}

@Suite(.serialized) struct StubbedNetworkTests {
    @Test func retriesWithoutRejectedTemperatureAndRemembersIt() async throws {
        let session = StubServer.session { _, body in
            let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            return fields["temperature"] == nil ? (200, chatCompletionReply) : (400, #"{"error": {"message": "temperature: unsupported value"}}"#)
        }
        let client = LLMClient(configuration: LLMConfiguration(baseURL: URL(string: "https://stub.test/v1")!, apiKey: "k", model: "temperature-test"), session: session)

        #expect(try await client.complete(system: "s", user: "u") == "ok")
        #expect(StubServer.requests.count == 2)
        #expect(StubServer.requests[1].request.value(forHTTPHeaderField: "Authorization") == "Bearer k")

        #expect(try await client.complete(system: "s", user: "u") == "ok")
        #expect(StubServer.requests.count == 3)
    }

    @Test func sendsAnthropicKeyHeader() async throws {
        let session = StubServer.session { _, _ in (200, chatCompletionReply) }
        let client = LLMClient(configuration: LLMConfiguration(baseURL: URL(string: "https://stub.test/v1")!, apiKey: "sk-ant", model: "m", dialect: .anthropic), session: session)
        _ = try await client.complete(system: "s", user: "u")
        let request = StubServer.requests[0].request
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func registersChatGPTClientAndChecksTheIdentity() async throws {
        let attempt = ChatGPTSignIn.Attempt(redirectURI: URL(string: "http://127.0.0.1:1455/auth/callback")!, savedClientID: nil)
        let idToken = jwt(["iss": ChatGPTSignIn.issuer, "sub": "user-1", "aud": "oaiapp_1", "nonce": attempt.nonce,
                           "email": "a@b.c", "exp": Date.now.timeIntervalSince1970 + 3600])
        let session = StubServer.session { _, _ in
            (200, #"{"access_token": "at", "refresh_token": "rt", "id_token": "\#(idToken)", "expires_in": 3600, "scope": "openid email chatgpt.tokens.use.direct"}"#)
        }

        let signedIn = try await ChatGPTSignIn.exchange(
            callback: ["code": "c+1", "state": attempt.state, "client_id": "oaiapp_1"], for: attempt, session: session
        )
        #expect(signedIn.clientID == "oaiapp_1" && signedIn.email == "a@b.c" && signedIn.accessToken == "at")
        let form = StubServer.formBody(0)
        #expect(form["grant_type"] == "authorization_code" && form["client_id"] == "oaiapp_1")
        #expect(form["code"] == "c+1" && form["code_verifier"] == attempt.pkce.verifier)
    }

    @Test func rejectsChatGPTSignInWithoutPlanUsage() async throws {
        let attempt = ChatGPTSignIn.Attempt(redirectURI: URL(string: "http://127.0.0.1:1455/auth/callback")!, savedClientID: "oaiapp_1")
        let idToken = jwt(["iss": ChatGPTSignIn.issuer, "sub": "user-1", "aud": ["oaiapp_1"], "nonce": attempt.nonce, "exp": Date.now.timeIntervalSince1970 + 3600])
        let session = StubServer.session { _, _ in (200, #"{"access_token": "at", "id_token": "\#(idToken)", "scope": "openid email"}"#) }
        await #expect(throws: SignInError.self) {
            try await ChatGPTSignIn.exchange(callback: ["code": "c", "state": attempt.state], for: attempt, session: session)
        }
    }
}

@Suite struct SignInTests {
    @Test func pkceChallengeIsUnpaddedBase64URLOfSHA256() {
        // printf %s <verifier> | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '='
        #expect(PKCE(verifier: "dBjftJeZ4CVP-mJ92K5eRDw9rnGzSeUa6WgfAj4yWK0").challenge == "Gk63hXY7jWtB8E3UepXf7m_vwRcYMBvwufcU2kUID2s")
    }

    @Test func registersOnFirstChatGPTSignInAndReusesClientAfter() {
        let redirect = URL(string: "http://127.0.0.1:1455/auth/callback")!
        func query(_ url: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }

        let first = query(ChatGPTSignIn.authorizationURL(for: .init(redirectURI: redirect, savedClientID: nil), hostID: "urn:uuid:x", previous: nil))
        #expect(first["client_id"] == "dynamic_agent_client" && first["agent_name_hint"] == "MindfulHours")
        #expect(first["ext_agent_host_id"] == "urn:uuid:x" && first["code_challenge_method"] == "S256")
        #expect(first["scope"]?.contains("chatgpt.tokens.use.direct") == true)

        let again = query(ChatGPTSignIn.authorizationURL(for: .init(redirectURI: redirect, savedClientID: "oaiapp_1"), hostID: "urn:uuid:x", previous: nil))
        #expect(again["client_id"] == "oaiapp_1" && again["agent_name_hint"] == nil)
    }

    @Test func rejectsCallbackForAnotherAttempt() async {
        let attempt = ChatGPTSignIn.Attempt(redirectURI: URL(string: "http://127.0.0.1:1/auth/callback")!, savedClientID: nil)
        await #expect(throws: SignInError.self) {
            try await ChatGPTSignIn.exchange(callback: ["code": "c", "state": "forged", "client_id": "x"], for: attempt)
        }
    }

    @Test func loopbackServerReturnsTheCallbackQuery() async throws {
        let server = try await LoopbackCallbackServer.start(path: "/callback")
        let callbackURL = URL(string: server.redirectURI().absoluteString + "?code=abc&state=xyz")!
        async let callback = server.callback()

        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(server.port)/favicon.ico")!)
        let (page, response) = try await URLSession.shared.data(from: callbackURL)

        #expect(try await callback == ["code": "abc", "state": "xyz"])
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: page, as: UTF8.self).contains("signed in"))
    }
}
