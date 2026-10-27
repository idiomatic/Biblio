import BiblioCore
import Foundation

/// The bridge to libbiblio, the Zig core shared with the Android, GNOME and Windows apps.
///
/// Each operation is a JSON request answered with `{"ok": true, "result": …}` or
/// `{"ok": false, "error": {…}}` (see core/include/biblio.h). Calls block, so they run on
/// a queue of their own rather than Swift's cooperative pool. The core's HTTP goes through
/// URLSession so requests use the system trust store, proxies and VPNs.
nonisolated enum Core {
    private static let queue = DispatchQueue(label: "com.rbrian.Biblio.core", attributes: .concurrent)

    /// Installs the URLSession transport once, before the first client is created.
    static let setUp: Void = {
        biblio_set_transport({ _, request, response in
            guard let request, let response else { return 1 }
            return Transport.shared.send(request.pointee, into: response)
        }, nil)
    }()

    struct Failure: LocalizedError, Decodable, Sendable {
        var kind: String
        var message: String
        var status: Int?
        var errorDescription: String? { message }
    }

    private struct Response<T: Decodable>: Decodable {
        var ok: Bool
        var result: T?
        var error: Failure?
    }

    /// Runs one operation. `client` is nil for operations that need no account.
    static func call<T: Decodable & Sendable>(_ client: OpaquePointer?, _ request: [String: Any],
                                               as type: T.Type = T.self) async throws -> T {
        _ = setUp
        let body = try JSONSerialization.data(withJSONObject: request)
        let text = String(decoding: body, as: UTF8.self)
        let box = ClientBox(client)
        let data: Data = await withCheckedContinuation { continuation in
            queue.async {
                let out = text.withCString { biblio_call(box.pointer, $0) }
                defer { biblio_free(out) }
                continuation.resume(returning: out.map { Data(bytes: $0, count: strlen($0)) } ?? Data())
            }
        }
        return try decode(data, as: type)
    }

    /// Runs an operation that never touches the network (status, cached patron, display helpers).
    static func callNow<T: Decodable>(_ client: OpaquePointer?, _ request: [String: Any], as type: T.Type = T.self) throws -> T {
        _ = setUp
        let body = try JSONSerialization.data(withJSONObject: request)
        let out = String(decoding: body, as: UTF8.self).withCString { biblio_call(client, $0) }
        defer { biblio_free(out) }
        return try decode(out.map { Data(bytes: $0, count: strlen($0)) } ?? Data(), as: type)
    }

    private static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let response = try JSONDecoder().decode(Response<T>.self, from: data)
        if let error = response.error { throw error }
        if let result = response.result { return result }
        // `null` results decode to nil for optional result types.
        if let none = (Optional<Any>.none as Any) as? T { return none }
        throw Failure(kind: "unexpected", message: "The library returned an unexpected response.")
    }

    /// Lets a client pointer cross into the core's queue.
    private struct ClientBox: @unchecked Sendable {
        let pointer: OpaquePointer?
        init(_ pointer: OpaquePointer?) { self.pointer = pointer }
    }

    /// Copies a Swift string into memory the core frees.
    static func coreString(_ s: String) -> UnsafeMutablePointer<CChar>? {
        let utf8 = Array(s.utf8CString)
        guard let p = biblio_alloc(utf8.count)?.assumingMemoryBound(to: CChar.self) else { return nil }
        utf8.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: utf8.count) }
        return p
    }
}

/// Sends the core's requests with URLSession: one request at a time per call, no redirects
/// followed and no cookies stored (the core does both).
nonisolated private final class Transport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = Transport()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

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
