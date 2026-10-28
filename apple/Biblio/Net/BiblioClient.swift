import BiblioCore
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

/// One authenticated BiblioCommons session for a (library, username) pair, kept by libbiblio.
///
/// The core logs in with the Keychain password when first needed and again whenever the
/// gateway ends the session (inactivity, or the same login signing in elsewhere), so callers
/// never see the expiry.
actor BiblioClient {
    nonisolated let subdomain: String
    nonisolated let username: String
    /// The latest request, shown in the window's status bar.
    nonisolated let status: FetchStatus

    private nonisolated let handle: Handle

    /// Guest clients have no username and can only make unauthenticated catalog requests.
    nonisolated var isGuest: Bool { username.isEmpty }
    nonisolated var webBase: URL { URL(string: "https://\(subdomain).bibliocommons.com")! }

    init(subdomain: String, username: String, status: FetchStatus,
         password: (@Sendable () -> String?)? = nil) {
        self.subdomain = subdomain
        self.username = username
        self.status = status
        handle = Handle(subdomain: subdomain, username: username,
                        password: password ?? { Keychain.password(subdomain: subdomain, username: username) })
        let language = Locale.preferredLanguages.first ?? "en-US"
        var sampleAccount: Int32 = -1
        #if DEBUG
        // For README screenshots: launch with `-SampleAccount YES` to hide the real card and email.
        sampleAccount = UserDefaults.standard.bool(forKey: "SampleAccount") ? 1 : 0
        #endif
        biblio_configure(handle.pointer, language, sampleAccount)
    }

    /// The patron from the last login (no network request).
    var patron: Patron? {
        try? Core.fetch({ biblio_patron(handle.pointer, $0, $1) }, free: biblio_patron_free, Patron.init) ?? nil
    }

    // MARK: Authentication

    /// Logs in (or joins a login already in progress) and returns the patron.
    @discardableResult
    func login(force: Bool = false) async throws -> Patron {
        try await fetch({ biblio_login($0, force, $1, $2) }, free: biblio_patron_free, Patron.init)
    }

    func setLanguage(_ code: String) {
        biblio_configure(handle.pointer, code, -1)
    }

    // MARK: Requests

    /// Runs core calls on the client, reporting them in the status bar.
    func run<T: Sendable>(_ work: @escaping @Sendable (OpaquePointer?) throws -> T) async throws -> T {
        let status = self.status
        let handle = self.handle
        await status.began()
        do {
            let result = try await Core.run { try work(handle.pointer) }
            await status.finished(lastFetch())
            return result
        } catch {
            await status.finished(lastFetch())
            throw error
        }
    }

    /// Runs a call that fills a result struct and returns it as an app model.
    func fetch<C, T: Sendable>(_ call: @escaping @Sendable (OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<C>?>,
                                                            UnsafeMutablePointer<biblio_error>) -> biblio_result,
                               free: @escaping @Sendable (UnsafeMutablePointer<C>?) -> Void,
                               _ convert: @escaping @Sendable (C) -> T) async throws -> T {
        try await run { client in
            guard let value = try Core.fetch({ call(client, $0, $1) }, free: free, convert) else {
                throw BiblioError.unexpected("The library returned an unexpected response.")
            }
            return value
        }
    }

    /// Runs a call that returns nothing but success or failure.
    func perform(_ call: @escaping @Sendable (OpaquePointer?, UnsafeMutablePointer<biblio_error>) -> biblio_result) async throws {
        try await run { client in try Core.check { call(client, $0) } }
    }

    private nonisolated func lastFetch() -> FetchStatus.Fetch? {
        try? Core.fetch({ biblio_status(handle.pointer, $0, $1) }, free: biblio_fetch_status_free) { s in
            string(s.title).flatMap { title in
                string(s.url).flatMap(URL.init(string:)).map { FetchStatus.Fetch(title: title, url: $0, bytes: Int(s.bytes)) }
            }
        } ?? nil
    }

    /// Owns the core client and the password callback's context.
    private final class Handle: @unchecked Sendable {
        let pointer: OpaquePointer?
        private let password: Unmanaged<PasswordBox>

        init(subdomain: String, username: String, password: @escaping @Sendable () -> String?) {
            _ = Core.setUp
            let box = Unmanaged.passRetained(PasswordBox(password))
            self.password = box
            pointer = biblio_client_new(subdomain, username, { ctx, _, _ in
                guard let ctx, let password = Unmanaged<PasswordBox>.fromOpaque(ctx).takeUnretainedValue().get() else { return nil }
                return Core.coreString(password)
            }, box.toOpaque())
        }

        deinit {
            biblio_client_free(pointer)
            password.release()
        }
    }

    private final class PasswordBox: @unchecked Sendable {
        let get: @Sendable () -> String?
        init(_ get: @escaping @Sendable () -> String?) { self.get = get }
    }
}
