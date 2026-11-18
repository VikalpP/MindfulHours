import CryptoKit
import Foundation

public enum SignInError: Error, LocalizedError {
    case denied
    case stateMismatch
    case missingCallbackValue(String)
    case invalidIDToken(String)
    case planUsageNotGranted
    case http(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .denied: "Sign-in was cancelled"
        case .stateMismatch: "Sign-in response didn't match this request; try again"
        case .missingCallbackValue(let name): "Sign-in response had no \(name); try again"
        case .invalidIDToken(let reason): "Sign-in returned an invalid identity: \(reason)"
        case .planUsageNotGranted: "Allow MindfulHours to use your ChatGPT plan to describe your activity"
        case .http(let status, let body): "Sign-in failed (HTTP \(status)): \(body.prefix(200))"
        }
    }
}

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String = randomURLSafeString(byteCount: 32)) {
        self.verifier = verifier
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
}

public func randomURLSafeString(byteCount: Int) -> String {
    Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncoded
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}

/// OpenRouter's PKCE flow, which mints an API key owned by the user. https://openrouter.ai/docs/use-cases/oauth-pkce
public enum OpenRouterSignIn {
    public static let callbackPath = "/callback"

    public static func authorizationURL(callbackURL: URL, pkce: PKCE) -> URL {
        var components = URLComponents(string: "https://openrouter.ai/auth")!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: callbackURL.absoluteString),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "key_label", value: "MindfulHours"),
        ]
        return components.url!
    }

    public static func exchange(callback: [String: String], pkce: PKCE, session: URLSession = .shared) async throws -> String {
        guard let code = callback["code"] else { throw SignInError.denied }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code, "code_verifier": pkce.verifier, "code_challenge_method": "S256",
        ])
        struct KeyResponse: Decodable { let key: String }
        return try JSONDecoder().decode(KeyResponse.self, from: try await send(request, session: session)).key
    }
}

/// Sign in with ChatGPT for open-source local apps, which lets requests draw on the user's ChatGPT plan.
/// https://developers.openai.com/siwc/token-sharing-open-source
public enum ChatGPTSignIn {
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let callbackPath = "/auth/callback"
    public static let preferredCallbackPort: UInt16 = 1455
    static let registrationClientID = "dynamic_agent_client"
    static let planUsageScope = "chatgpt.tokens.use.direct"
    private static let tokenURL = URL(string: "\(issuer)/api/accounts/oauth/token")!

    public struct Attempt: Sendable {
        public let pkce = PKCE()
        public let state = randomURLSafeString(byteCount: 24)
        public let nonce = randomURLSafeString(byteCount: 24)
        public let redirectURI: URL
        /// Nil on first sign-in, when OpenAI registers MindfulHours for this account and returns a client ID.
        public let savedClientID: String?

        public init(redirectURI: URL, savedClientID: String?) {
            self.redirectURI = redirectURI
            self.savedClientID = savedClientID
        }
    }

    public static func authorizationURL(for attempt: Attempt, hostID: String, previous: ChatGPTSession?) -> URL {
        var items = [
            URLQueryItem(name: "client_id", value: attempt.savedClientID ?? registrationClientID),
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: attempt.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: "openid profile email offline_access resource.invoke \(planUsageScope)"),
            URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "state", value: attempt.state),
            URLQueryItem(name: "nonce", value: attempt.nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: attempt.pkce.challenge),
        ]
        if attempt.savedClientID == nil {
            items.append(URLQueryItem(name: "agent_name_hint", value: "MindfulHours"))
        } else if let previous {
            items.append(URLQueryItem(name: "id_token_hint", value: previous.idToken))
            if let email = previous.email { items.append(URLQueryItem(name: "login_hint", value: email)) }
        }
        var components = URLComponents(string: "\(issuer)/api/accounts/authorize")!
        components.queryItems = items
        return components.url!
    }

    public static func exchange(callback: [String: String], for attempt: Attempt, session: URLSession = .shared) async throws -> ChatGPTSession {
        guard callback["state"] == attempt.state else { throw SignInError.stateMismatch }
        if callback["error"] != nil { throw SignInError.denied }
        guard let code = callback["code"] else { throw SignInError.missingCallbackValue("code") }
        let clientID: String
        if let saved = attempt.savedClientID {
            if let issued = callback["client_id"], issued != saved { throw SignInError.stateMismatch }
            clientID = saved
        } else {
            guard let issued = callback["client_id"] else { throw SignInError.missingCallbackValue("client ID") }
            clientID = issued
        }

        let tokens = try await tokenResponse([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": attempt.pkce.verifier,
            "redirect_uri": attempt.redirectURI.absoluteString,
            "resource": resource,
        ], session: session)
        guard let idToken = tokens.idToken else { throw SignInError.invalidIDToken("missing") }
        // Received straight from the token endpoint over TLS, so issuer, audience and nonce are checked without the
        // signature (OpenID Connect Core 3.1.3.7).
        let claims = try IDTokenClaims(idToken)
        guard claims.issuer == issuer else { throw SignInError.invalidIDToken("unexpected issuer") }
        guard claims.audience.contains(clientID) else { throw SignInError.invalidIDToken("unexpected audience") }
        guard claims.nonce == attempt.nonce else { throw SignInError.invalidIDToken("nonce mismatch") }
        guard claims.expiresAt > .now else { throw SignInError.invalidIDToken("expired") }

        let session = ChatGPTSession(clientID: clientID, subject: claims.subject, email: claims.email, idToken: idToken, tokens: tokens)
        guard session.scopes.contains(planUsageScope) else { throw SignInError.planUsageNotGranted }
        return session
    }

    public static func refreshed(_ current: ChatGPTSession, session: URLSession = .shared) async throws -> ChatGPTSession {
        let tokens = try await tokenResponse([
            "grant_type": "refresh_token",
            "client_id": current.clientID,
            "refresh_token": current.refreshToken,
            "resource": resource,
        ], session: session)
        return current.updated(with: tokens)
    }

    /// Best effort: the user can also disconnect MindfulHours in ChatGPT's settings.
    public static func revoke(_ current: ChatGPTSession, session: URLSession = .shared) async throws {
        struct Discovery: Decodable {
            let revocationEndpoint: URL
            private enum CodingKeys: String, CodingKey { case revocationEndpoint = "revocation_endpoint" }
        }
        let discoveryURL = URL(string: "\(issuer)/.well-known/openid-configuration")!
        let discovery = try JSONDecoder().decode(Discovery.self, from: try await send(URLRequest(url: discoveryURL), session: session))
        _ = try await send(formRequest(discovery.revocationEndpoint, [
            "token": current.refreshToken, "token_type_hint": "refresh_token", "client_id": current.clientID,
        ]), session: session)
    }

    private static func tokenResponse(_ form: [String: String], session: URLSession) async throws -> TokenResponse {
        try JSONDecoder().decode(TokenResponse.self, from: try await send(formRequest(tokenURL, form), session: session))
    }

    private static func formRequest(_ url: URL, _ form: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" unescaped, which form decoding would read as a space.
        request.httpBody = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return request
    }
}

public struct ChatGPTSession: Codable, Sendable, Equatable {
    public var clientID: String
    public var subject: String
    public var email: String?
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scopes: [String]

    init(clientID: String, subject: String, email: String?, idToken: String, tokens: TokenResponse, now: Date = .now) {
        self.clientID = clientID
        self.subject = subject
        self.email = email
        self.idToken = idToken
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken ?? ""
        expiresAt = now.addingTimeInterval(tokens.expiresIn ?? 3600)
        scopes = tokens.scope?.split(separator: " ").map(String.init) ?? []
    }

    public func needsRefresh(at now: Date = .now) -> Bool {
        expiresAt.timeIntervalSince(now) < 5 * 60
    }

    func updated(with tokens: TokenResponse, now: Date = .now) -> ChatGPTSession {
        var session = self
        session.accessToken = tokens.accessToken
        if let refreshToken = tokens.refreshToken { session.refreshToken = refreshToken }
        if let idToken = tokens.idToken { session.idToken = idToken }
        if let scope = tokens.scope { session.scopes = scope.split(separator: " ").map(String.init) }
        session.expiresAt = now.addingTimeInterval(tokens.expiresIn ?? 3600)
        return session
    }
}

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: TimeInterval?
    let scope: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
        case scope
    }
}

struct IDTokenClaims {
    let issuer: String
    let subject: String
    let audience: [String]
    let nonce: String?
    let email: String?
    let expiresAt: Date

    init(_ jwt: String) throws {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3, let payload = Data(base64URLEncoded: String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw SignInError.invalidIDToken("malformed")
        }
        guard let issuer = json["iss"] as? String, let subject = json["sub"] as? String, let expiration = json["exp"] as? TimeInterval else {
            throw SignInError.invalidIDToken("missing issuer, subject or expiry")
        }
        expiresAt = Date(timeIntervalSince1970: expiration)
        self.issuer = issuer
        self.subject = subject
        audience = (json["aud"] as? [String]) ?? [json["aud"] as? String].compactMap { $0 }
        nonce = json["nonce"] as? String
        email = json["email"] as? String
    }
}

private func send(_ request: URLRequest, session: URLSession) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        throw SignInError.http(status: status, body: String(decoding: data, as: UTF8.self))
    }
    return data
}
