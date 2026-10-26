import Foundation

/// Just enough HTML scraping to read and submit the library site's Rails forms
/// (account settings have no gateway endpoint).
nonisolated struct HTMLForm: Sendable {
    struct Input: Sendable { var name: String; var type: String; var value: String }

    var action: URL
    var method: String
    var inputs: [Input]

    /// Default submission values: hidden fields (authenticity token etc.), text values, checked boxes, selected options.
    var fields: [String: String] {
        var out: [String: String] = [:]
        for i in inputs where !["submit", "button", "image", "password"].contains(i.type) {
            out[i.name] = i.value
        }
        // Include the first submit button, as a browser would.
        if let submit = inputs.first(where: { $0.type == "submit" }) { out[submit.name] = submit.value }
        return out
    }

    static func forms(in html: String, base: URL) -> [HTMLForm] {
        matches(#"<form\b([^>]*)>(.*?)</form>"#, in: html).compactMap { m in
            let attrs = m[1], body = m[2]
            let action = attribute("action", in: attrs).flatMap { URL(string: decode($0), relativeTo: base)?.absoluteURL } ?? base
            var method = (attribute("method", in: attrs) ?? "get").uppercased()
            var inputs: [Input] = []
            for tag in matches(#"<input\b([^>]*)>"#, in: body).map({ $0[1] }) {
                guard let name = attribute("name", in: tag).map(decode) else { continue }
                let type = (attribute("type", in: tag) ?? "text").lowercased()
                if (type == "checkbox" || type == "radio") && !tag.contains("checked") { continue }
                inputs.append(Input(name: name, type: type, value: attribute("value", in: tag).map(decode) ?? ""))
            }
            for sel in matches(#"<select\b([^>]*)>(.*?)</select>"#, in: body) {
                guard let name = attribute("name", in: sel[1]).map(decode) else { continue }
                let options = matches(#"<option\b([^>]*)>"#, in: sel[2]).map { $0[1] }
                let chosen = options.first { $0.contains("selected") } ?? options.first
                inputs.append(Input(name: name, type: "select", value: chosen.flatMap { attribute("value", in: $0) }.map(decode) ?? ""))
            }
            // Rails tunnels PUT/PATCH through a hidden `_method` field, which is submitted with the rest.
            if method != "GET" { method = "POST" }
            return HTMLForm(action: action, method: method, inputs: inputs)
        }
    }

    static func links(in html: String, base: URL) -> [URL] {
        matches(##"<a\b[^>]*href="([^"#]+)""##, in: html).compactMap { URL(string: decode($0[1]), relativeTo: base)?.absoluteURL }
    }

    /// Finds a visible error message in a response page, if any.
    static func errorMessage(in html: String) -> String? {
        for pattern in [#"class="[^"]*(?:alert-danger|alert-error|form-error|error_message|errorMessage)[^"]*"[^>]*>(.*?)</"#] {
            if let m = matches(pattern, in: html).first {
                let text = decode(m[1].replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        matches(#"\b\#(name)\s*=\s*"([^"]*)""#, in: tag).first?[1]
            ?? matches(#"\b\#(name)\s*=\s*'([^']*)'"#, in: tag).first?[1]
    }

    private static func matches(_ pattern: String, in s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }

    static func decode(_ s: String) -> String {
        var out = s
        for (k, v) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&lt;": "<", "&gt;": ">", "&#x2713;": "✓", "&#x3D;": "="] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out
    }
}
