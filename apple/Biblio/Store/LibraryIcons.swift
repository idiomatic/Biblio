import BiblioCore
import Foundation
import ImageIO
import Observation
import SwiftUI

/// Square library icons from the core (`biblio_library_icon`), cached on disk so each
/// library's site is asked only once. A wide directory logo is trimmed to its content.
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

        let found = try? await Core.run { Self.lookUp(website: website, subdomain: subdomain, logo: logo) }
        switch found {
        case .icon(let data):
            try? data.write(to: iconFile)
            icons[key] = .icon(data)
        case .logo(let data):
            try? data.write(to: logoFile)
            icons[key] = .logo(data)
        default:
            icons[key] = .missing
        }
    }

    /// The core's icon, with a logo trimmed to its content and re-encoded as PNG.
    private nonisolated static func lookUp(website: URL?, subdomain: String?, logo: URL?) -> Icon {
        var bytes: UnsafeMutablePointer<UInt8>?
        var len = 0
        let kind = Core.withCStrings([website?.absoluteString, subdomain, logo?.absoluteString]) {
            biblio_library_icon($0[0], $0[1], $0[2], &bytes, &len)
        }
        defer { biblio_free(bytes) }
        guard let bytes else { return .missing }
        let data = Data(bytes: bytes, count: len)
        if kind == BIBLIO_ICON_LOGO { return trimmed(data).map(Icon.logo) ?? .missing }
        return .icon(data)
    }

    /// The logo drawn on white and cropped to its non-white content.
    private nonisolated static func trimmed(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var b = [Int](repeating: 0, count: 4)
        guard biblio_logo_bounds(pixels, w, h, w * 4, 4, &b),
              let cropped = context.makeImage()?.cropping(to: CGRect(x: b[0], y: b[1], width: b[2], height: b[3])) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cropped, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
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
