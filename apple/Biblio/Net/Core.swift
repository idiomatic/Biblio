import BiblioCore
import Foundation

/// The bridge to libbiblio, the Zig core shared with the Android, GNOME and Windows apps.
///
/// The app uses the core's typed C interface (see core/include/biblio.h): each operation
/// returns a `biblio_result` and fills a C struct that CoreModels.swift copies into the app's
/// models. Calls block, so they run on a queue of their own rather than Swift's cooperative
/// pool. The core's HTTP goes through URLSession so requests use the system trust store,
/// proxies and VPNs.
nonisolated enum Core {
    private static let queue = DispatchQueue(label: "com.rbrian.Biblio.core", attributes: .concurrent)

    /// Installs the URLSession transport once, before the first client is created.
    static let setUp: Void = {
        biblio_set_transport({ _, request, response in
            guard let request, let response else { return 1 }
            return Transport.shared.send(request.pointee, into: response)
        }, nil)
    }()

    /// Runs blocking core calls off the cooperative pool.
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        _ = setUp
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// Runs a call that fills a result struct, converts it and frees it. A NULL result (only
    /// `biblio_patron` before sign-in) is nil.
    static func fetch<C, T>(_ call: (UnsafeMutablePointer<UnsafeMutablePointer<C>?>, UnsafeMutablePointer<biblio_error>) -> biblio_result,
                            free: (UnsafeMutablePointer<C>?) -> Void,
                            _ convert: (C) -> T) throws -> T? {
        var out: UnsafeMutablePointer<C>?
        try check { call(&out, $0) }
        defer { free(out) }
        return out.map { convert($0.pointee) }
    }

    /// Runs a call and throws its error, if any.
    static func check(_ call: (UnsafeMutablePointer<biblio_error>) -> biblio_result) throws {
        var err = biblio_error()
        defer { biblio_error_clear(&err) }
        let result = call(&err)
        guard result != BIBLIO_OK else { return }
        let message = string(err.message) ?? "The library returned an unexpected response."
        switch result {
        case BIBLIO_MISSING_CREDENTIALS: throw BiblioError.missingCredentials
        case BIBLIO_SIGN_IN_REQUIRED: throw BiblioError.signInRequired
        case BIBLIO_LOGIN_FAILED: throw BiblioError.loginFailed(message)
        case BIBLIO_HTTP: throw BiblioError.http(Int(err.status), message)
        default: throw BiblioError.unexpected(message)
        }
    }

    /// Takes a string the core allocated with biblio_alloc.
    static func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        defer { biblio_free(p) }
        return p.map { String(cString: $0) }
    }

    /// Copies a Swift string into memory the core frees.
    static func coreString(_ s: String) -> UnsafeMutablePointer<CChar>? {
        let utf8 = Array(s.utf8CString)
        guard let p = biblio_alloc(utf8.count)?.assumingMemoryBound(to: CChar.self) else { return nil }
        utf8.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: utf8.count) }
        return p
    }

    /// C strings for the length of a call; nil stays NULL.
    static func withCStrings<R>(_ strings: [String?], _ body: ([UnsafePointer<CChar>?]) throws -> R) rethrows -> R {
        let copies = strings.map { $0.flatMap { strdup($0) } }
        defer { copies.forEach { free($0) } }
        return try body(copies.map { $0.map { UnsafePointer($0) } })
    }
}

// MARK: Reading C structs

nonisolated func string(_ p: UnsafePointer<CChar>?) -> String? { p.map { String(cString: $0) } }

nonisolated func strings(_ p: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int) -> [String] {
    buffer(p, count).compactMap(string)
}

nonisolated func buffer<T>(_ p: UnsafePointer<T>?, _ count: Int) -> UnsafeBufferPointer<T> {
    UnsafeBufferPointer(start: count > 0 ? p : nil, count: count)
}

/// Sends the core's requests with URLSession: one request at a time per call, no redirects
/// followed and no cookies stored (the core does both).
nonisolated private final class Transport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = Transport()

    /// Set once in `init`; it can't be created before `self` exists, since `self` is its delegate.
    private var session: URLSession!

    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func send(_ req: biblio_http_request, into out: UnsafeMutablePointer<biblio_http_response>) -> Int32 {
        guard let url = URL(string: String(cString: req.url)) else { return 1 }
        var request = URLRequest(url: url)
        request.httpMethod = String(cString: req.method)
        for i in 0..<req.header_count {
            let h = req.headers[i]
            request.setValue(String(cString: h.value), forHTTPHeaderField: String(cString: h.name))
        }
        if let body = req.body { request.httpBody = Data(bytes: body, count: req.body_len) }

        nonisolated(unsafe) var result: (Data, HTTPURLResponse)?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { result = (data ?? Data(), http) }
            done.signal()
        }.resume()
        done.wait()
        guard let (data, http) = result else { return 1 }

        var lines = ""
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, let value = value as? String else { continue }
            if name.caseInsensitiveCompare("Set-Cookie") == .orderedSame { continue }
            lines += "\(name): \(value)\r\n"
        }
        // URLSession joins Set-Cookie headers with commas; give the core one line per cookie.
        let fields = http.allHeaderFields.reduce(into: [String: String]()) { d, kv in
            if let k = kv.key as? String, let v = kv.value as? String { d[k] = v }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            var line = "Set-Cookie: \(cookie.name)=\(cookie.value)"
            if !cookie.domain.isEmpty, cookie.domain.hasPrefix(".") { line += "; Domain=\(cookie.domain)" }
            if let expires = cookie.expiresDate, expires < .now { line += "; Max-Age=0" }
            lines += line + "\r\n"
        }

        out.pointee.status = Int32(http.statusCode)
        out.pointee.headers = copy(Data(lines.utf8), length: &out.pointee.headers_len)?.assumingMemoryBound(to: CChar.self)
        out.pointee.body = copy(data, length: &out.pointee.body_len)?.assumingMemoryBound(to: UInt8.self)
        return 0
    }

    private func copy(_ data: Data, length: inout Int) -> UnsafeMutableRawPointer? {
        length = data.count
        guard let p = biblio_alloc(max(data.count, 1)) else { return nil }
        data.withUnsafeBytes { if let base = $0.baseAddress { p.copyMemory(from: base, byteCount: data.count) } }
        return p
    }
}
