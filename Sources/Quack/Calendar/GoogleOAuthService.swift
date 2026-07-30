import Foundation
import AppKit
import Network
import os

enum GoogleOAuthError: Error, LocalizedError {
    case noAuthCode
    case invalidResponse
    case accessDenied(String?)
    case tokenRefreshFailed
    case listenerSetupFailed(Error)
    case callbackTimedOut

    var errorDescription: String? {
        switch self {
        case .noAuthCode: return "No authorization code returned by Google"
        case .invalidResponse: return "Invalid response from OAuth callback"
        case .accessDenied(let reason): return reason.map { "Access denied: \($0)" } ?? "Access denied by user"
        case .tokenRefreshFailed: return "Failed to refresh access token"
        case .listenerSetupFailed(let e): return "Failed to start local server: \(e.localizedDescription)"
        case .callbackTimedOut: return "Timed out waiting for Google sign-in"
        }
    }
}

// MARK: - OAuth token response types

struct GoogleTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let scope: String?
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope = "scope"
        case tokenType = "token_type"
    }
}

struct GoogleTokenErrorResponse: Codable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

actor GoogleOAuthService {
    private let clientID: String
    private let clientSecret: String

    private let scopes = ["https://www.googleapis.com/auth/calendar.readonly"]
    private let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenURL = "https://oauth2.googleapis.com/token"

    private let defaults: UserDefaults
    private let accessTokenKey = "com.quack.google.accessToken"
    private let refreshTokenKey = "com.quack.google.refreshToken"
    private let expiryDateKey = "com.quack.google.tokenExpiry"

    nonisolated let log: Logger

    init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.defaults = UserDefaults.standard
        self.log = Logger(subsystem: "com.quack.menubar", category: "google-oauth")
    }

    /// True when the user has a refresh token (i.e. has ever signed in and not
    /// signed out). `validAccessToken()` handles silent token refresh on demand,
    /// so checking only the access-token expiry would incorrectly return false
    /// after a normal expiry cycle.
    var isAuthenticated: Bool {
        hasRefreshToken || (accessToken != nil && (tokenExpiryDate ?? .distantPast) > Date())
    }

    var accessToken: String? {
        get { defaults.string(forKey: accessTokenKey) }
        set { defaults.set(newValue, forKey: accessTokenKey) }
    }

    var refreshToken: String? {
        get { defaults.string(forKey: refreshTokenKey) }
        set { defaults.set(newValue, forKey: refreshTokenKey) }
    }

    var tokenExpiryDate: Date? {
        get { defaults.object(forKey: expiryDateKey) as? Date }
        set { defaults.set(newValue, forKey: expiryDateKey) }
    }

    var hasRefreshToken: Bool {
        defaults.string(forKey: refreshTokenKey) != nil
    }

    func clearTokens() {
        defaults.removeObject(forKey: accessTokenKey)
        defaults.removeObject(forKey: refreshTokenKey)
        defaults.removeObject(forKey: expiryDateKey)
    }

    /// Returns a valid access token, refreshing it if necessary.
    /// Returns nil when no token is available (not signed in).
    func validAccessToken() async throws -> String? {
        if let token = accessToken, let expiry = tokenExpiryDate, expiry > Date() {
            return token
        }
        guard let rt = refreshToken else { return nil }
        try await performTokenRefresh(refreshToken: rt)
        return accessToken
    }

    /// Initiates the OAuth 2.0 flow:
    /// 1. Picks a random local port and starts an HTTP listener
    /// 2. Opens the browser to Google's consent page
    /// 3. Catches the redirect, extracts the auth code
    /// 4. Exchanges the code for tokens
    func authenticate() async throws {
        let port = UInt16.random(in: 49152...65535)
        let redirectURI = "http://localhost:\(port)/callback"
        let state = UUID().uuidString

        let code = try await waitForCallback(port: port, redirectURI: redirectURI, state: state)
        try await exchangeCodeForTokens(code: code, redirectURI: redirectURI)
    }

    func signOut() {
        clearTokens()
    }

    // MARK: - OAuth flow

    private func buildAuthURL(redirectURI: String, state: String) -> URL {
        var comps = URLComponents(string: authURL)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return comps.url!
    }

    /// Opens the browser and waits for the OAuth callback on a local HTTP server.
    private func waitForCallback(port: UInt16, redirectURI: String, state: String) async throws -> String {
        let url = buildAuthURL(redirectURI: redirectURI, state: state)
        log.debug("Starting OAuth listener on port \(port)")

        let code: String = try await withCheckedThrowingContinuation { continuation in
            let listener: NWListener
            do {
                listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            } catch {
                continuation.resume(throwing: GoogleOAuthError.listenerSetupFailed(error))
                return
            }

            var didResume = false
            let lock = NSLock()

            listener.newConnectionHandler = { connection in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                    lock.lock()
                    guard !didResume else { lock.unlock(); return }
                    defer { lock.unlock() }

                    if let error = error {
                        continuation.resume(throwing: error)
                        didResume = true
                        return
                    }

                    guard let data, let request = String(data: data, encoding: .utf8) else {
                        continuation.resume(throwing: GoogleOAuthError.invalidResponse)
                        didResume = true
                        return
                    }

                    guard let firstLine = request.components(separatedBy: "\r\n").first,
                          let urlPart = firstLine.components(separatedBy: " ").dropFirst().first,
                          let comps = URLComponents(string: urlPart) else {
                        continuation.resume(throwing: GoogleOAuthError.invalidResponse)
                        didResume = true
                        return
                    }

                    let query = comps.queryItems ?? []

                    if let err = query.first(where: { $0.name == "error" })?.value {
                        continuation.resume(throwing: GoogleOAuthError.accessDenied(err))
                        didResume = true
                        return
                    }

                    let receivedState = query.first(where: { $0.name == "state" })?.value
                    guard receivedState == state else {
                        continuation.resume(throwing: GoogleOAuthError.invalidResponse)
                        didResume = true
                        return
                    }

                    guard let code = query.first(where: { $0.name == "code" })?.value else {
                        continuation.resume(throwing: GoogleOAuthError.noAuthCode)
                        didResume = true
                        return
                    }

                    let html = "<html><body><p>Authenticated! You can close this tab.</p></body></html>"
                    let response = """
HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)
"""
                    connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
                        connection.cancel()
                        continuation.resume(returning: code)
                    }))
                    didResume = true
                }
                connection.start(queue: .main)
            }

            listener.start(queue: .main)

            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }

            // Timeout: if we never get a callback within 300s, give up
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                lock.lock()
                if !didResume {
                    listener.cancel()
                    continuation.resume(throwing: GoogleOAuthError.callbackTimedOut)
                    didResume = true
                }
                lock.unlock()
            }
        }

        log.debug("Received auth code, exchanging for tokens")
        return code
    }

    private func exchangeCodeForTokens(code: String, redirectURI: String) async throws {
        let body = [
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ]

        let response: GoogleTokenResponse = try await performTokenRequest(body: body)
        accessToken = response.accessToken
        tokenExpiryDate = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        if let rt = response.refreshToken {
            refreshToken = rt
        }
        log.debug("Tokens acquired successfully")
    }

    private func performTokenRefresh(refreshToken rt: String) async throws {
        let body = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": rt,
            "grant_type": "refresh_token",
        ]

        let response: GoogleTokenResponse = try await performTokenRequest(body: body)
        accessToken = response.accessToken
        tokenExpiryDate = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        log.debug("Access token refreshed")
    }

    private func performTokenRequest(body: [String: String]) async throws -> GoogleTokenResponse {
        var req = URLRequest(url: URL(string: tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleOAuthError.tokenRefreshFailed
        }

        if http.statusCode != 200 {
            if let errResp = try? JSONDecoder().decode(GoogleTokenErrorResponse.self, from: data) {
                log.error("Token request failed: \(errResp.error) – \(errResp.errorDescription ?? "")")
            }
            throw GoogleOAuthError.tokenRefreshFailed
        }

        return try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
    }
}
