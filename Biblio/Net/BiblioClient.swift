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
        var configure: [String: Any] = ["op": "configure", "language": language]
        #if DEBUG
        // For README screenshots: launch with `-SampleAccount YES` to hide the real card and email.
        configure["sampleAccount"] = UserDefaults.standard.bool(forKey: "SampleAccount")
        #endif
        _ = try? Core.callNow(handle.pointer, configure, as: Bool.self)
    }

    /// The patron from the last login (no network request).
    var patron: Patron? { try? Core.callNow(handle.pointer, ["op": "patron"], as: Patron?.self) }

    // MARK: Authentication

    /// Logs in (or joins a login already in progress) and returns the patron.
    @discardableResult
    func login(force: Bool = false) async throws -> Patron {
        try await call(["op": "login", "force": force])
    }

    func setLanguage(_ code: String) {
        _ = try? Core.callNow(handle.pointer, ["op": "configure", "language": code], as: Bool.self)
    }

    // MARK: Requests

    /// Runs a core operation, reporting it in the status bar.
    func call<T: Decodable & Sendable>(_ request: [String: Any], as type: T.Type = T.self) async throws -> T {
        let status = self.status
        await status.began()
        do {
            let result = try await Core.call(handle.pointer, request, as: type)
            await status.finished(lastFetch())
            return result
        } catch let failure as Core.Failure {
            await status.finished(lastFetch())
            throw Self.error(failure)
        } catch {
            await status.finished(nil)
            throw error
        }
    }

    private nonisolated func lastFetch() -> FetchStatus.Fetch? {
        struct Status: Decodable { var title: String?; var url: String?; var bytes: Int }
        guard let s = try? Core.callNow(handle.pointer, ["op": "status"], as: Status.self),
              let title = s.title, let url = s.url.flatMap(URL.init(string:)) else { return nil }
        return .init(title: title, url: url, bytes: s.bytes)
    }

    private static func error(_ f: Core.Failure) -> Error {
        switch f.kind {
        case "missingCredentials": BiblioError.missingCredentials
        case "signInRequired": BiblioError.signInRequired
        case "loginFailed": BiblioError.loginFailed(f.message)
        case "http": BiblioError.http(f.status ?? 0, f.message)
        default: BiblioError.unexpected(f.message)
        }
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
