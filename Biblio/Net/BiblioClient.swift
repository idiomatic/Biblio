import Foundation

nonisolated enum BiblioError: LocalizedError, Sendable {
    case missingCredentials
    case signInRequired
    case loginFailed(String)
    case http(Int, String?)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "No saved password for this user. Add the user again."
        case .signInRequired: "Sign in to use this feature."
        case .loginFailed(let m): m
        case .http(let code, let m): m ?? HTTPURLResponse.localizedString(forStatusCode: code).capitalized
        case .unexpected(let m): m
        }
    }
}

/// One authenticated BiblioCommons session for a (library, username) pair.
///
/// Requests carry the gateway's `X-Session-Id`/`X-Access-Token` headers. When the
/// gateway rejects them (inactivity timeout, or another login with the same
/// credentials evicted us) the client logs in again with the Keychain password
/// and retries once, so callers never see the expiry.
actor BiblioClient {
    nonisolated let subdomain: String
    nonisolated let username: String
    /// The latest request, shown in the window's status bar.
    nonisolated let status: FetchStatus

    private let session: URLSession
    private var sessionId: String?
    private var authToken: String?
    private var loginTask: Task<Patron, Error>?
    private let password: @Sendable () -> String?
    var patron: Patron?

    private nonisolated var gateway: URL { URL(string: "https://gateway.bibliocommons.com/v2/libraries/\(subdomain)")! }
    /// Guest clients have no username and can only make unauthenticated catalog requests.
    nonisolated var isGuest: Bool { username.isEmpty }
    nonisolated var webBase: URL { URL(string: "https://\(subdomain).bibliocommons.com")! }

    init(subdomain: String, username: String, status: FetchStatus,
         password: (@Sendable () -> String?)? = nil) {
        self.subdomain = subdomain
        self.username = username
        self.status = status
        self.password = password ?? { Keychain.password(subdomain: subdomain, username: username) }
        // Ephemeral: each client keeps its own cookie jar, isolated from other sessions.
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpAdditionalHeaders = ["User-Agent": "Biblio/1.0 (Apple; SwiftUI patron app)"]
        session = URLSession(configuration: config)
    }

    var locale: String { patron?.language ?? Locale.preferredLanguages.first ?? "en-US" }

    // MARK: Authentication

    /// Logs in (or joins a login already in progress) and returns the patron.
    @discardableResult
    func login(force: Bool = false) async throws -> Patron {
        if isGuest { throw BiblioError.signInRequired }
        if !force, let patron, sessionId != nil { return patron }
        if let loginTask { return try await loginTask.value }
        let task = Task { try await performLogin() }
        loginTask = task
        defer { loginTask = nil }
        let p = try await task.value
        patron = p
        return p
    }

    private func performLogin() async throws -> Patron {
        guard let password = password() else {
            throw BiblioError.missingCredentials
        }
        let body: JSON = ["username": .string(username), "password": .string(password)]
        let (json, status) = try await raw("POST", gateway.appending(path: "sessions"), body: body, authenticated: false)
        guard (200..<300).contains(status),
              let sid = json[path: "auth.sessionId"].string,
              let token = json[path: "auth.authToken"].string,
              let uid = json[path: "auth.currentUserId"].int else {
            throw BiblioError.loginFailed(Self.message(in: json) ?? "Login failed. Check the username and PIN.")
        }
        sessionId = sid
        authToken = token
        let user = json["entities"]["users"][String(uid)]
        let accountId = user["accounts"][0].int ?? json["entities"]["accounts"].object.keys.compactMap(Int.init).first ?? 0
        let account = json["entities"]["accounts"][String(accountId)]
        var result = Patron(
            userId: uid,
            accountId: accountId,
            name: user["name"].string ?? username,
            email: user["userContact"]["email"].nonEmptyString,
            language: patron?.language ?? user["preferences"]["language"].string ?? "en-US",
            barcode: account["barcode"].string,
            preferredPickup: account["preferredLocations"][0].string
                ?? account["singleClickHoldsSettings"]["branchId"].string,
            borrowingHistoryEnabled: account["borrowingHistoryEnabled"].bool)
        #if DEBUG
        // For README screenshots: launch with `-SampleAccount YES` to hide the real card and email.
        if UserDefaults.standard.bool(forKey: "SampleAccount") {
            result.email = "reader@example.com"
            result.barcode = "21168012345678"
        }
        #endif
        return result
    }

    func setLanguage(_ code: String) { patron?.language = code }

    // MARK: Requests

    /// Sends a gateway request, logging in first and re-authenticating once if the session expired.
    func send(_ method: String, _ path: String, query: [String: String] = [:], body: JSON? = nil,
              authenticated: Bool = true) async throws -> JSON {
        var url = gateway.appending(path: path)
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if query["locale"] == nil { items.append(URLQueryItem(name: "locale", value: locale)) }
        url.append(queryItems: items.sorted { $0.name < $1.name })

        if authenticated { try await login() }
        var (json, status) = try await raw(method, url, body: body, authenticated: authenticated)
        if authenticated, Self.isAuthFailure(status: status, json: json) {
            sessionId = nil
            try await login(force: true)
            (json, status) = try await raw(method, url, body: body, authenticated: authenticated)
        }
        guard (200..<300).contains(status) else {
            throw BiblioError.http(status, Self.message(in: json))
        }
        return json
    }

    private func raw(_ method: String, _ url: URL, body: JSON?, authenticated: Bool) async throws -> (JSON, Int) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try body.data()
        }
        if authenticated, let sessionId, let authToken {
            req.setValue(sessionId, forHTTPHeaderField: "X-Session-Id")
            req.setValue(authToken, forHTTPHeaderField: "X-Access-Token")
        }
        let (data, response) = try await load(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSON.parse(data)) ?? .null
        return (json, status)
    }

    /// Fetches an HTML page on the library's web host (shares this session's cookies).
    func webPage(_ path: String, query: [URLQueryItem] = []) async throws -> (String, URL) {
        try await login()
        var url = webBase.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var req = URLRequest(url: url)
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await load(req)
        let finalURL = response.url ?? url
        let html = String(decoding: data, as: UTF8.self)
        if finalURL.path.contains("/user/login") {
            // Web session expired independently of the gateway one: log in again and retry.
            try await login(force: true)
            let (d2, r2) = try await load(req)
            return (String(decoding: d2, as: UTF8.self), r2.url ?? url)
        }
        return (html, finalURL)
    }

    /// Submits an HTML form on the library's web host.
    func submitForm(_ form: HTMLForm, values: [String: String]) async throws -> (String, Int) {
        var fields = form.fields
        for (k, v) in values { fields[k] = v }
        var req = URLRequest(url: form.action)
        req.httpMethod = form.method
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = comps.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)
        let (data, response) = try await load(req)
        return (String(decoding: data, as: UTF8.self), (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Every request goes through here: paced by `Throttle` and reported to `status`.
    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let status = self.status
        let session = self.session
        await status.began()
        do {
            let (data, response) = try await Throttle.shared.run { try await session.data(for: request) }
            let url = response.url ?? request.url ?? webBase
            await status.finished(.init(title: FetchStatus.title(url: url, data: data), url: url, bytes: data.count))
            return (data, response)
        } catch {
            await status.finished(nil)
            throw error
        }
    }

    private static func isAuthFailure(status: Int, json: JSON) -> Bool {
        if status == 401 || status == 403 { return true }
        guard status >= 400 else { return false }
        let m = (message(in: json) ?? "").lowercased()
        return m.contains("session") || m.contains("not logged") || m.contains("unauthor") || m.contains("authenticat")
    }

    static func message(in json: JSON) -> String? {
        json[path: "error.message"].nonEmptyString
            ?? json["message"].nonEmptyString
            ?? json["errors"][0]["message"].nonEmptyString
            ?? json["failures"][0]["message"].nonEmptyString
    }
}
