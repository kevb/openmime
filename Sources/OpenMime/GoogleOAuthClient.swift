import AppKit
import CryptoKit
import Foundation

struct GoogleOAuthClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func authorize(
        configuration: OAuthConfiguration,
        scope: String = "openid email https://www.googleapis.com/auth/gmail.modify",
        loginHint: String? = nil
    ) async throws -> OAuthTokens {
        let callback = LoopbackOAuthCallback()
        let redirectURI = try await callback.start()
        let verifier = PKCE.codeVerifier()
        let state = PKCE.randomURLSafeString(byteCount: 24)
        let authorizationURL = try Self.authorizationURL(
            configuration: configuration,
            redirectURI: redirectURI,
            verifier: verifier,
            state: state,
            scope: scope,
            loginHint: loginHint
        )

        _ = await MainActor.run {
            NSWorkspace.shared.open(authorizationURL)
        }

        let response = try await callback.waitForResponse()
        guard response.state == state else { throw OAuthError.stateMismatch }
        if let error = response.error { throw OAuthError.authorizationDenied(error) }
        guard let code = response.code else { throw OAuthError.missingAuthorizationCode }

        return try await exchangeCode(
            code,
            verifier: verifier,
            redirectURI: redirectURI,
            configuration: configuration
        )
    }

    func refresh(_ tokens: OAuthTokens, configuration: OAuthConfiguration) async throws -> OAuthTokens {
        var fields = [
            "client_id": configuration.clientID,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token",
        ]
        if let secret = configuration.clientSecret { fields["client_secret"] = secret }
        let response: TokenResponse = try await tokenRequest(fields)
        return OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? tokens.refreshToken,
            expiration: Date().addingTimeInterval(TimeInterval(response.expiresIn))
        )
    }

    static func authorizationURL(
        configuration: OAuthConfiguration,
        redirectURI: URL,
        verifier: String,
        state: String,
        scope: String = "openid email https://www.googleapis.com/auth/gmail.modify",
        loginHint: String? = nil
    ) throws -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if let loginHint, !loginHint.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "login_hint", value: loginHint))
        }
        guard let url = components.url else { throw OAuthError.invalidAuthorizationURL }
        return url
    }

    private func exchangeCode(
        _ code: String,
        verifier: String,
        redirectURI: URL,
        configuration: OAuthConfiguration
    ) async throws -> OAuthTokens {
        var fields = [
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI.absoluteString,
        ]
        if let secret = configuration.clientSecret { fields["client_secret"] = secret }
        let response: TokenResponse = try await tokenRequest(fields)
        guard let refreshToken = response.refreshToken else { throw OAuthError.missingRefreshToken }
        return OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiration: Date().addingTimeInterval(TimeInterval(response.expiresIn))
        )
    }

    private func tokenRequest<T: Decodable & Sendable>(_ fields: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.encode(fields)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let serverError = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
            throw OAuthError.tokenExchangeFailed(serverError?.errorDescription ?? serverError?.error ?? "HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum OAuthError: LocalizedError {
    case invalidAuthorizationURL
    case invalidResponse
    case stateMismatch
    case authorizationDenied(String)
    case missingAuthorizationCode
    case missingRefreshToken
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizationURL: "Could not construct the Google authorization URL."
        case .invalidResponse: "Google returned an invalid response."
        case .stateMismatch: "The OAuth response did not match this sign-in request."
        case .authorizationDenied(let reason): "Google authorization was denied: \(reason)"
        case .missingAuthorizationCode: "Google did not return an authorization code."
        case .missingRefreshToken: "Google did not return a refresh token. Remove OpenMime from your Google Account access and try again."
        case .tokenExchangeFailed(let reason): "Google token exchange failed: \(reason)"
        }
    }
}

private struct TokenResponse: Decodable, Sendable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

private struct TokenErrorResponse: Decodable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

enum PKCE {
    static func codeVerifier() -> String { randomURLSafeString(byteCount: 64) }

    static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

enum FormEncoding {
    static func encode(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.sorted { $0.key < $1.key }.map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
