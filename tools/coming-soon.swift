// Draws the README's "coming soon" sketches: a wobbly, hand-drawn outline of each platform's
// window or phone over plain shapes (sidebar, list rows, inspector), with its name.
//
//   swift tools/coming-soon.swift OUT_DIR
//
// Writes gnome-coming-soon.png (1400×875) and android-coming-soon.png (600×1300), each with a
// -dark variant, the sizes of the checked-in placeholders in docs/screenshots.

import AppKit

struct Sketch {
    let file: String
    let name: String
    /// The canvas the sketch is drawn on, scaled down to `output` when written.
    let size: CGSize
    let output: CGSize
    let accent: NSColor
    let style: Style
    enum Style { case gnome, android }
}

let sketches = [
    Sketch(file: "gnome-coming-soon", name: "GNOME", size: CGSize(width: 1600, height: 1000), output: CGSize(width: 1400, height: 875), accent: NSColor(srgbRed: 0.55, green: 0.3, blue: 0.75, alpha: 1), style: .gnome),
    Sketch(file: "android-coming-soon", name: "Android", size: CGSize(width: 1080, height: 2340), output: CGSize(width: 600, height: 1300), accent: NSColor(srgbRed: 0.2, green: 0.6, blue: 0.35, alpha: 1), style: .android),
]

/// A repeatable pseudo-random stream, so reruns draw the same sketch.
struct Wobble {
    var state: UInt64 = 0x9E3779B97F4A7C15
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 10_000) / 10_000 - 0.5
    }
}

final class Pen {
    let ctx: CGContext
    var wobble = Wobble()
    let ink: NSColor
    init(_ ctx: CGContext, ink: NSColor) {
        self.ctx = ctx
        self.ink = ink
    }

    /// A line that drifts a little, drawn twice like a pen going over it.
    func line(_ a: CGPoint, _ b: CGPoint, width: CGFloat = 4, color: NSColor? = nil) {
        ctx.setStrokeColor((color ?? ink).cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        for pass in 0..<2 {
            let jitter: CGFloat = pass == 0 ? 5 : 3
            let mid = CGPoint(x: (a.x + b.x) / 2 + wobble.next() * jitter * 2, y: (a.y + b.y) / 2 + wobble.next() * jitter * 2)
            ctx.move(to: CGPoint(x: a.x + wobble.next() * jitter, y: a.y + wobble.next() * jitter))
            ctx.addQuadCurve(to: CGPoint(x: b.x + wobble.next() * jitter, y: b.y + wobble.next() * jitter), control: mid)
            ctx.strokePath()
        }
    }

    func rect(_ r: CGRect, radius: CGFloat = 0, width: CGFloat = 4, color: NSColor? = nil, fill: NSColor? = nil) {
        if let fill {
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        let r = r.insetBy(dx: radius * 0.15, dy: radius * 0.15)
        line(CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), width: width, color: color)
        line(CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), width: width, color: color)
        line(CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), width: width, color: color)
        line(CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY), width: width, color: color)
    }

    func circle(_ center: CGPoint, radius: CGFloat, width: CGFloat = 4, color: NSColor? = nil) {
        ctx.setStrokeColor((color ?? ink).cgColor)
        ctx.setLineWidth(width)
        ctx.addEllipse(in: CGRect(x: center.x - radius + wobble.next() * 4, y: center.y - radius + wobble.next() * 4, width: radius * 2, height: radius * 2))
        ctx.strokePath()
    }

    func text(_ string: String, at point: CGPoint, size: CGFloat, color: NSColor? = nil, centered: Bool = false) {
        let font = NSFont(name: "Noteworthy-Bold", size: size) ?? NSFont(name: "MarkerFelt-Wide", size: size) ?? NSFont.systemFont(ofSize: size, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color ?? ink]
        let s = NSAttributedString(string: string, attributes: attributes)
        let w = s.size().width
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        s.draw(at: CGPoint(x: centered ? point.x - w / 2 : point.x, y: point.y))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Placeholder text: a few strokes of varying length.
    func lines(in r: CGRect, count: Int, color: NSColor, width: CGFloat = 8) {
        for i in 0..<count {
            let y = r.maxY - CGFloat(i) * (r.height / CGFloat(max(count, 1)))
            let length = r.width * (i == 0 ? 0.8 : 0.45 + abs(wobble.next()) * 0.5)
            line(CGPoint(x: r.minX, y: y), CGPoint(x: r.minX + length, y: y), width: width, color: color)
        }
    }
}

func draw(_ s: Sketch, dark: Bool) -> Data? {
    let w = Int(s.size.width), h = Int(s.size.height)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    let paper = dark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.985, alpha: 1)
    let ink = dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.18, alpha: 1)
    let faint = dark ? NSColor(white: 0.32, alpha: 1) : NSColor(white: 0.78, alpha: 1)
    let tint = s.accent.withAlphaComponent(dark ? 0.35 : 0.18)
    ctx.setFillColor(paper.cgColor)
    ctx.fill(CGRect(origin: .zero, size: s.size))
    let pen = Pen(ctx, ink: ink)

    switch s.style {
    case .gnome:
        let frame = CGRect(x: 60, y: 60, width: CGFloat(w) - 120, height: CGFloat(h) - 120)
        pen.rect(frame, radius: 40, width: 6)
        // Title bar and window controls.
        let barY = frame.maxY - 80
        pen.line(CGPoint(x: frame.minX, y: barY), CGPoint(x: frame.maxX, y: barY), width: 4)
        pen.text("Biblio", at: CGPoint(x: frame.midX, y: barY + 24), size: 30, color: faint, centered: true)
        pen.circle(CGPoint(x: frame.maxX - 60, y: barY + 40), radius: 18, width: 4)
        // Sidebar, list, and inspector.
        let body = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: barY - frame.minY)
        let sideX = body.minX + 330
        let listX = body.maxX - 520
        pen.line(CGPoint(x: sideX, y: body.minY), CGPoint(x: sideX, y: body.maxY), width: 4, color: faint)
        pen.line(CGPoint(x: listX, y: body.minY), CGPoint(x: listX, y: body.maxY), width: 4, color: faint)
        for i in 0..<6 {
            let y = body.maxY - 90 - CGFloat(i) * 70
            pen.rect(CGRect(x: body.minX + 36, y: y - 14, width: 34, height: 34), radius: 8, width: 4, color: i == 2 ? s.accent : faint, fill: i == 2 ? tint : nil)
            pen.line(CGPoint(x: body.minX + 100, y: y + 3), CGPoint(x: body.minX + 100 + (i == 2 ? 160 : 120 + CGFloat(i % 3) * 25), y: y + 3), width: 8, color: i == 2 ? s.accent : faint)
        }
        for i in 0..<4 {
            let y = body.maxY - 150 - CGFloat(i) * 150
            pen.rect(CGRect(x: sideX + 40, y: y - 90, width: 80, height: 115), radius: 6, width: 4, color: faint, fill: i == 1 ? tint : nil)
            pen.line(CGPoint(x: sideX + 150, y: y + 10), CGPoint(x: sideX + 400, y: y + 10), width: 9, color: ink.withAlphaComponent(0.6))
            pen.lines(in: CGRect(x: sideX + 150, y: y - 28, width: 330, height: 60), count: 2, color: faint)
        }
        pen.rect(CGRect(x: listX + 40, y: body.maxY - 340, width: 150, height: 220), radius: 6, width: 4, color: faint, fill: tint)
        pen.lines(in: CGRect(x: listX + 220, y: body.maxY - 130, width: 250, height: 100), count: 3, color: faint)
        pen.lines(in: CGRect(x: listX + 40, y: body.maxY - 700, width: 430, height: 300), count: 6, color: faint)
        // The name, over the middle of the list.
        pen.rect(CGRect(x: frame.midX - 270, y: frame.midY - 120, width: 540, height: 240), radius: 40, width: 6, color: s.accent, fill: paper)
        pen.text(s.name, at: CGPoint(x: frame.midX, y: frame.midY - 10), size: 84, color: ink, centered: true)
        pen.text("coming soon", at: CGPoint(x: frame.midX, y: frame.midY - 84), size: 46, color: s.accent, centered: true)
    case .android:
        let phone = CGRect(x: 70, y: 70, width: CGFloat(w) - 140, height: CGFloat(h) - 140)
        pen.rect(phone, radius: 110, width: 7)
        // Status bar, app bar, list rows, and the bottom navigation.
        pen.circle(CGPoint(x: phone.midX, y: phone.maxY - 70), radius: 20, width: 5)
        pen.text("9:41", at: CGPoint(x: phone.minX + 90, y: phone.maxY - 90), size: 40, color: faint)
        pen.text("Biblio", at: CGPoint(x: phone.minX + 90, y: phone.maxY - 240), size: 70)
        pen.rect(CGRect(x: phone.minX + 70, y: phone.maxY - 400, width: phone.width - 140, height: 90), radius: 45, width: 4, color: faint)
        for i in 0..<5 {
            let y = phone.maxY - 560 - CGFloat(i) * 230
            pen.rect(CGRect(x: phone.minX + 80, y: y - 150, width: 130, height: 180), radius: 8, width: 4, color: faint, fill: i == 1 ? tint : nil)
            pen.line(CGPoint(x: phone.minX + 250, y: y + 5), CGPoint(x: phone.minX + 650, y: y + 5), width: 10, color: ink.withAlphaComponent(0.6))
            pen.lines(in: CGRect(x: phone.minX + 250, y: y - 45, width: 560, height: 110), count: 3, color: faint, width: 8)
        }
        pen.line(CGPoint(x: phone.minX + 40, y: phone.minY + 250), CGPoint(x: phone.maxX - 40, y: phone.minY + 250), width: 4, color: faint)
        for i in 0..<4 {
            let x = phone.minX + 150 + CGFloat(i) * (phone.width - 300) / 3
            pen.circle(CGPoint(x: x, y: phone.minY + 170), radius: 34, width: 4, color: i == 0 ? s.accent : faint)
        }
        pen.rect(CGRect(x: phone.midX - 360, y: phone.midY - 170, width: 720, height: 340), radius: 50, width: 6, color: s.accent, fill: paper)
        pen.text(s.name, at: CGPoint(x: phone.midX, y: phone.midY - 5), size: 110, centered: true)
        pen.text("coming soon", at: CGPoint(x: phone.midX, y: phone.midY - 115), size: 62, color: s.accent, centered: true)
    }

    let ow = Int(s.output.width), oh = Int(s.output.height)
    guard let image = ctx.makeImage(),
          let small = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    small.interpolationQuality = .high
    small.draw(image, in: CGRect(origin: .zero, size: s.output))
    guard let scaled = small.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for sketch in sketches {
    for dark in [false, true] {
        let name = "\(sketch.file)\(dark ? "-dark" : "").png"
        guard let data = draw(sketch, dark: dark) else { continue }
        try data.write(to: out.appendingPathComponent(name))
        print(name)
    }
}
