import Foundation
import ImageIO
import Observation
import SwiftUI

/// Square library icons, cached on disk so each library's site is asked only once. In order of
/// preference: the website's own large icon (apple-touch-icon or a sized `rel="icon"`), the
/// directory's partner logo with its white margins trimmed, then the site's small favicon.
@Observable
final class LibraryIcons {
    nonisolated enum Icon: Sendable {
        /// A square icon that fills the tile.
        case icon(Data)
        /// A wide logo, shown fitted on white.
        case logo(Data)
        case missing
    }

    static let shared = LibraryIcons()

    private(set) var icons: [String: Icon] = [:]
    @ObservationIgnored private var started: Set<String> = []

    private let directory: URL = {
        let dir = URL.cachesDirectory.appending(path: "LibraryIcons", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func icon(_ key: String) -> Icon? { icons[key] }

    /// Looks up the icon for `key` once. `website` may be nil when it has to be read from the
    /// catalog of `subdomain` (libraries saved before icons existed).
    func load(key: String, website: URL?, subdomain: String? = nil, logo: URL? = nil) async {
        guard icons[key] == nil, started.insert(key).inserted else { return }
        let name = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        let iconFile = directory.appending(path: name + ".icon"), logoFile = directory.appending(path: name + ".logo")
        if let data = try? Data(contentsOf: iconFile) { icons[key] = .icon(data); return }
        if let data = try? Data(contentsOf: logoFile) { icons[key] = .logo(data); return }

        var site = website
        if site == nil, let subdomain { site = await Self.homeLink(subdomain) }
        let found = await site.asyncFlatMap(Self.fetchIcon)
        if let found, found.pixels >= Self.largeIcon {
            try? found.data.write(to: iconFile)
            icons[key] = .icon(found.data)
        } else if let logo, let trimmed = await Self.fetchLogo(logo) {
            try? trimmed.write(to: logoFile)
            icons[key] = .logo(trimmed)
        } else if let found {
            try? found.data.write(to: iconFile)
            icons[key] = .icon(found.data)
        } else {
            icons[key] = .missing
        }
    }

    /// Icons at least this many pixels wide look sharp in the 36-point tile.
    private nonisolated static let largeIcon = 64

    private nonisolated static func homeLink(_ subdomain: String) async -> URL? {
        try? await LibraryLookup.info(for: subdomain).website.flatMap(URL.init(string:))
    }

    /// The largest square icon among the site's first few candidates.
    private nonisolated static func fetchIcon(_ website: URL) async -> (data: Data, pixels: Int)? {
        let website = website.upgradedToHTTPS
        guard let (data, http) = try? await LibraryLookup.get(website), http.statusCode == 200 else { return nil }
        let base = http.url ?? website
        var candidates = iconLinks(String(decoding: data, as: UTF8.self), base: base)
        for path in ["/apple-touch-icon.png", "/favicon.ico"] {
            if let url = URL(string: path, relativeTo: base)?.absoluteURL, !candidates.contains(url) {
                candidates.append(url)
            }
        }
        var best: (data: Data, pixels: Int)?
        for url in candidates.prefix(3) {
            guard let (icon, response) = try? await LibraryLookup.get(url.upgradedToHTTPS), response.statusCode == 200,
                  let pixels = squarePixels(icon), pixels >= 16 else { continue }
            if pixels > best?.pixels ?? 0 { best = (icon, pixels) }
            if pixels >= largeIcon { break }
        }
        return best
    }

    /// Sized icons first, largest first (apple-touch-icons count as 180 px when unsized),
    /// then unsized `rel="icon"` links.
    nonisolated static func iconLinks(_ html: String, base: URL) -> [URL] {
        guard let re = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: .caseInsensitive) else { return [] }
        let ns = html as NSString
        func attr(_ tag: String, _ name: String) -> String? {
            let pattern = #"\s"# + name + #"\s*=\s*["']([^"']*)["']"#
            guard let r = tag.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
            let match = String(tag[r])
            guard let q = match.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
            return String(match[match.index(after: q)...].dropLast())
        }
        var found: [(rank: Int, url: URL)] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            guard let rel = attr(tag, "rel")?.lowercased(), let href = attr(tag, "href"),
                  let url = URL(string: htmlDecoded(href), relativeTo: base)?.absoluteURL else { continue }
            let size = attr(tag, "sizes").flatMap { Int($0.lowercased().split(separator: "x").first ?? "") } ?? 0
            if rel.contains("apple-touch-icon") {
                found.append((max(size, 180), url))
            } else if rel.split(separator: " ").contains("icon") {
                found.append((size, url))
            }
        }
        var seen = Set<URL>()
        return found.sorted { $0.rank > $1.rank }.map(\.url).filter { seen.insert($0).inserted }
    }

    /// Decodes the entities that appear in `href` attributes.
    private nonisolated static func htmlDecoded(_ s: String) -> String {
        var out = s
        for (k, v) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&lt;": "<", "&gt;": ">", "&#x3D;": "="] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out
    }

    /// The pixel width of the largest square image in `data` (an .ico may hold several).
    private nonisolated static func squarePixels(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let sizes = (0..<CGImageSourceGetCount(source)).compactMap { i -> Int? in
            guard let p = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
                  abs(w - h) <= 1 else { return nil }
            return w
        }
        return sizes.max()
    }

    /// The directory logo cropped to its non-white content, re-encoded as PNG.
    private nonisolated static func fetchLogo(_ url: URL) async -> Data? {
        guard let (data, response) = try? await LibraryLookup.get(url.upgradedToHTTPS), response.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var (minX, minY, maxX, maxY) = (w, h, -1, -1)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if min(pixels[i], pixels[i + 1], pixels[i + 2]) < 232 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = max(maxX - minX, maxY - minY) / 20
        let crop = CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + 1 + 2 * pad, height: maxY - minY + 1 + 2 * pad)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let cropped = context.makeImage()?.cropping(to: crop) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cropped, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

private extension URL {
    /// Directory links are sometimes plain http, which App Transport Security blocks.
    nonisolated var upgradedToHTTPS: URL {
        guard scheme == "http", var c = URLComponents(url: self, resolvingAgainstBaseURL: true) else { return self }
        c.scheme = "https"
        return c.url ?? self
    }
}

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

extension Image {
    init?(iconData: Data) {
        guard let image = PlatformImage(data: iconData) else { return nil }
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

private extension Optional {
    func asyncFlatMap<U>(_ transform: (Wrapped) async -> U?) async -> U? {
        guard let self else { return nil }
        return await transform(self)
    }
}

/// A square library icon (see `LibraryIcons`), or a tile in the library's brand color.
struct LibraryIconView: View {
    var key: String
    var website: URL?
    var subdomain: String?
    var logo: URL?
    var tint: Color = .accentColor
    var size: CGFloat = 36

    @State private var icons = LibraryIcons.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        ZStack {
            switch icons.icon(key) {
            case .icon(let data):
                if let image = Image(iconData: data) {
                    image.resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                }
            case .logo(let data):
                Color.white
                if let image = Image(iconData: data) {
                    image.resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(size * 0.08)
                }
            case .missing, nil:
                shape.fill(tint.gradient)
                Image(systemName: "building.columns.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
        .accessibilityHidden(true)
        .task(id: key) { await icons.load(key: key, website: website, subdomain: subdomain, logo: logo) }
    }
}
