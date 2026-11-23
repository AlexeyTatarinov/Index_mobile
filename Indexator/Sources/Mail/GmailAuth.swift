// SPDX-License-Identifier: GPL-3.0-or-later
//
// Google sign-in for Gmail (read-only), OAuth 2.0 authorization code flow with PKCE
// for an "iOS" OAuth client. The client has no secret; the redirect goes to the
// reversed client id URL scheme, which ASWebAuthenticationSession catches itself,
// so nothing has to be registered in Info.plist and a free Apple ID signing works.
// The user's password is typed only on Google's own page.

import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

enum GmailAuthError: LocalizedError {
    case badClientId
    case cancelled
    case denied(String)
    case stateMismatch
    case noCode
    case tokenEndpoint(String)
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .badClientId:
            return "Client ID должен заканчиваться на .apps.googleusercontent.com (тип клиента: iOS)."
        case .cancelled:
            return "Вход отменён."
        case .denied(let reason):
            if reason == "access_denied" {
                return "Google отказал в доступе. Проверь, что твой адрес добавлен в Test users на экране OAuth consent."
            }
            return "Google вернул ошибку: \(reason)"
        case .stateMismatch:
            return "Ответ Google не совпал с запросом, попробуй ещё раз."
        case .noCode:
            return "Google не вернул код авторизации."
        case .tokenEndpoint(let message):
            return "Не удалось получить токен: \(message)"
        case .notSignedIn:
            return "Gmail не подключён или вход истёк. Подключи заново."
        }
    }
}

struct GmailTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiry: Date
}

struct GoogleOAuthConfig: Equatable {
    static let scope = "https://www.googleapis.com/auth/gmail.readonly"
    static let clientSuffix = ".apps.googleusercontent.com"

    let clientId: String

    init?(clientId raw: String) {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(Self.clientSuffix), id.count > Self.clientSuffix.count,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" })
        else { return nil }
        clientId = id
    }

    /// "123-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123-abc"
    var redirectScheme: String {
        "com.googleusercontent.apps." + clientId.dropLast(Self.clientSuffix.count)
    }

    var redirectURI: String { redirectScheme + ":/oauthredirect" }

    func authorizationURL(challenge: String, state: String) -> URL {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return c.url!
    }
}

enum PKCE {
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Holds the tokens and refreshes them. Safe to call from any task.
actor GmailAuth {
    static let shared = GmailAuth()
    private static let keychainAccount = "tokens"

    private var tokens: GmailTokens?
    private var config: GoogleOAuthConfig?
    private var refreshing: Task<GmailTokens, Error>?

    init() {
        if let data = Keychain.load(account: Self.keychainAccount) {
            tokens = try? JSONDecoder().decode(GmailTokens.self, from: data)
        }
    }

    var isSignedIn: Bool { tokens?.refreshToken != nil || (tokens.map { $0.expiry > Date() } ?? false) }

    func configure(_ config: GoogleOAuthConfig?) { self.config = config }

    /// Everything needed for one sign-in attempt; the page is shown by WebAuthenticator.
    struct SignInRequest {
        let config: GoogleOAuthConfig
        let url: URL
        let verifier: String
        let state: String
    }

    nonisolated static func makeSignInRequest(config: GoogleOAuthConfig) -> SignInRequest {
        let verifier = PKCE.verifier()
        let state = PKCE.verifier()
        let url = config.authorizationURL(challenge: PKCE.challenge(for: verifier), state: state)
        return SignInRequest(config: config, url: url, verifier: verifier, state: state)
    }

    /// Exchanges the code from Google's redirect for tokens and stores them in the Keychain.
    func finishSignIn(_ request: SignInRequest, callback: URL) async throws {
        config = request.config
        let code = try Self.code(from: callback, expectedState: request.state)
        let fresh = try await Self.tokenRequest(fields: [
            "code": code,
            "client_id": request.config.clientId,
            "redirect_uri": request.config.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": request.verifier,
        ], previousRefreshToken: nil)
        store(fresh)
    }

    /// Current access token, refreshed when it is about to expire (or when `force`).
    func accessToken(force: Bool = false) async throws -> String {
        guard let current = tokens else { throw GmailAuthError.notSignedIn }
        if !force, current.expiry > Date().addingTimeInterval(60) { return current.accessToken }
        if let refreshing { return try await refreshing.value.accessToken }
        guard let refreshToken = current.refreshToken, let config else { throw GmailAuthError.notSignedIn }
        let task = Task {
            try await Self.tokenRequest(fields: [
                "client_id": config.clientId,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token",
            ], previousRefreshToken: refreshToken)
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            store(fresh)
            return fresh.accessToken
        } catch GmailAuthError.tokenEndpoint(let message) where message.contains("invalid_grant") {
            // Refresh tokens of apps in "Testing" mode expire after 7 days.
            signOutLocally()
            throw GmailAuthError.notSignedIn
        }
    }

    /// Revokes the grant at Google (best effort) and forgets the tokens.
    func signOut() async {
        if let token = tokens?.refreshToken ?? tokens?.accessToken {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["token": token])
            _ = try? await URLSession.shared.data(for: request)
        }
        signOutLocally()
    }

    private func signOutLocally() {
        tokens = nil
        Keychain.delete(account: Self.keychainAccount)
    }

    private func store(_ fresh: GmailTokens) {
        tokens = fresh
        if let data = try? JSONEncoder().encode(fresh) {
            _ = Keychain.save(data, account: Self.keychainAccount)
        }
    }

    // MARK: - Helpers

    static func code(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw GmailAuthError.denied(error) }
        guard value("state") == expectedState else { throw GmailAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw GmailAuthError.noCode }
        return code
    }

    private struct TokenResponse: Decodable {
        let access_token: String?
        let expires_in: Double?
        let refresh_token: String?
        let error: String?
        let error_description: String?
    }

    private static func tokenRequest(fields: [String: String], previousRefreshToken: String?) async throws -> GmailTokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let access = response.access_token else {
            let message = [response.error, response.error_description].compactMap { $0 }.joined(separator: ": ")
            throw GmailAuthError.tokenEndpoint(message.isEmpty ? "пустой ответ" : message)
        }
        return GmailTokens(
            accessToken: access,
            refreshToken: response.refresh_token ?? previousRefreshToken,
            expiry: Date().addingTimeInterval(response.expires_in ?? 3600)
        )
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)!
    }
}

/// Presents Google's page in the system browser sheet and waits for the redirect.
final class WebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthenticator()

    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?

    @MainActor
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })
        anchor = keyWindow ?? ASPresentationAnchor()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: GmailAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? GmailAuthError.noCode)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: GmailAuthError.cancelled)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor!
    }
}
