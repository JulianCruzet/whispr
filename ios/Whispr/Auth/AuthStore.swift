// Email and password sign-in with Supabase. The session is kept in the Keychain, so the
// app remembers you after it closes. Only the publishable key belongs in the app: a secret
// key bypasses row-level security and must never ship in a client.

import Foundation
import Observation
import Security

/// What Supabase returns for a signed-in user, and what the Keychain remembers.
struct AuthSession: Codable {
    let accessToken: String
    let refreshToken: String
    let email: String
}

enum AuthFailure: LocalizedError {
    case rejected(String)
    /// Couldn't get an answer: no network, or Supabase is having trouble.
    case unreachable
    /// The account exists but its email isn't confirmed yet.
    case confirmEmail(String)

    var errorDescription: String? {
        switch self {
        case let .rejected(message): message
        case .unreachable: "Couldn't reach the server. Check your connection and try again."
        case let .confirmEmail(email): "Check \(email) for a link to confirm your account, then sign in."
        }
    }
}

/// Supabase's auth API. Plain requests, so the app needs no extra packages.
struct SupabaseAuthAPI {
    let projectURL: URL
    let publishableKey: String

    private struct TokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let email: String?
        let user: User?

        struct User: Decodable { let email: String? }
    }

    private struct ErrorResponse: Decodable {
        let msg: String?
        let error_description: String?
    }

    func signIn(email: String, password: String) async throws -> AuthSession {
        try await requestSession(
            path: "auth/v1/token",
            query: "grant_type=password",
            body: ["email": email, "password": password],
            fallbackEmail: email
        )
    }

    func signUp(email: String, password: String) async throws -> AuthSession {
        try await requestSession(
            path: "auth/v1/signup",
            query: nil,
            body: ["email": email, "password": password],
            fallbackEmail: email
        )
    }

    func refresh(_ session: AuthSession) async throws -> AuthSession {
        try await requestSession(
            path: "auth/v1/token",
            query: "grant_type=refresh_token",
            body: ["refresh_token": session.refreshToken],
            fallbackEmail: session.email
        )
    }

    private func requestSession(
        path: String,
        query: String?,
        body: [String: String],
        fallbackEmail: String
    ) async throws -> AuthSession {
        var components = URLComponents(url: projectURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.query = query
        guard let url = components?.url else { throw AuthFailure.unreachable }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AuthFailure.unreachable
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw AuthFailure.unreachable }

        // 429 and 5xx mean try again later, not that the account or session is bad.
        if status == 429 || status >= 500 { throw AuthFailure.unreachable }
        guard (200..<300).contains(status) else {
            let details = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthFailure.rejected(details?.msg ?? details?.error_description ?? "That didn't work. Please try again.")
        }

        guard let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthFailure.unreachable
        }
        // With email confirmation on, sign-up succeeds without a session.
        guard let access = tokens.access_token, let refresh = tokens.refresh_token else {
            throw AuthFailure.confirmEmail(fallbackEmail)
        }
        return AuthSession(
            accessToken: access,
            refreshToken: refresh,
            email: tokens.user?.email ?? tokens.email ?? fallbackEmail
        )
    }
}

/// The saved session. Keychain items stay until sign-out, and never leave this device.
enum SessionKeychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.juliancruzet.whispr.auth",
        kSecAttrAccount as String: "session",
    ]

    static func load() -> AuthSession? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    static func save(_ session: AuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        clear()
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Who's signed in, for the UI.
@MainActor
@Observable
final class AuthStore {
    private(set) var session: AuthSession?
    private let api: SupabaseAuthAPI?

    /// Without Supabase settings there's nothing to sign in to, so the app just opens.
    var isSignedIn: Bool { api == nil || session != nil }
    var email: String? { session?.email }

    init() {
        api = Self.apiFromInfoPlist()
        session = api == nil ? nil : SessionKeychain.load()
    }

    private static func apiFromInfoPlist() -> SupabaseAuthAPI? {
        let info = Bundle.main.infoDictionary
        guard let address = info?["SupabaseURL"] as? String,
              let key = info?["SupabasePublishableKey"] as? String,
              address.hasPrefix("https://"), !key.isEmpty,
              let url = URL(string: address) else { return nil }
        return SupabaseAuthAPI(projectURL: url, publishableKey: key)
    }

    func signIn(email: String, password: String) async throws {
        guard let api else { return }
        remember(try await api.signIn(email: email, password: password))
    }

    func signUp(email: String, password: String) async throws {
        guard let api else { return }
        remember(try await api.signUp(email: email, password: password))
    }

    /// Runs when the app opens. You stay signed in through a bad connection; only Supabase
    /// rejecting the session outright signs you out.
    func refreshIfSignedIn() async {
        guard let api, let current = session else { return }
        do {
            remember(try await api.refresh(current))
        } catch AuthFailure.rejected {
            signOut()
        } catch {}
    }

    func signOut() {
        SessionKeychain.clear()
        session = nil
    }

    private func remember(_ session: AuthSession) {
        SessionKeychain.save(session)
        self.session = session
    }
}
