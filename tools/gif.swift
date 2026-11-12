// swift tools/gif.swift IN OUT.gif [options] — a screen recording (.mov or .mp4) as a looping GIF89a.
// Keeps a frame when the screen changes, at most --fps a second, each held until the next; still
// spans longer than --max-hold are cut to it, and --fast plays a span faster, so a recording driven
// at tool speed reads at human speed. --taps draws a dot and an expanding ring at each tap, as
// terrarium's `record --clicks` does, for recordings (like the iOS Simulator's) that show none.
//
//   --width PX           output width (default: the recording's)
//   --fps N              at most N frames a second (default 12)
//   --max-hold S         cut any still span to S seconds (default 1.2)
//   --final-hold S       hold the last frame S seconds before looping (default 2)
//   --fast FROM-TO:N     play the span FROM to TO seconds N times faster (repeatable)
//   --start S, --end S   keep only this part of the recording, in seconds
//   --taps FILE          lines of "SECONDS X Y": a tap, in seconds from the recording's start and
//                        points from its top left
//   --scale N            pixels per point in the recording, for --taps (default 3)
//   --snap               with --taps, move each tap to the recording's first change at or after
//                        its logged time (within 1.5 s), when the tool's log runs early
//   --pace S             with --taps, play the time between taps beyond S seconds after each
//                        8 times faster, so tool-driven waits read at human speed
//   --fade S             fade in from --fade-color over S seconds at the loop's start, and out
//                        to it at its end, so the jump back reads as a new take
//   --fade-color C       white (default) or black, for a dark-mode recording
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("gif: \(message)\nusage: swift tools/gif.swift IN OUT.gif [--width PX] [--fps N] [--max-hold S] [--final-hold S] [--fast FROM-TO:N]... [--start S] [--end S] [--taps FILE] [--scale N] [--snap] [--pace S] [--fade S] [--fade-color white|black]\n".utf8))
    exit(2)
}

struct Fast { var from, to, speed: Double }
struct Tap { var time, x, y: Double }

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { fail("expected an input and an output") }
let inURL = URL(fileURLWithPath: args.removeFirst())
let outURL = URL(fileURLWithPath: args.removeFirst())
guard outURL.pathExtension.lowercased() == "gif" else { fail("OUT must end in .gif") }

var width: Int?
var fps = 12.0
var maxHold = 1.2
var finalHold = 2.0
var fasts: [Fast] = []
var start = 0.0
var end = Double.infinity
var taps: [Tap] = []
var scale = 3.0
var pace: Double?
var snap = false
var fade = 0.0
var fadeWhite = true

func number(_ s: String?, _ name: String) -> Double {
    guard let s, let v = Double(s), v >= 0 else { fail("\(name) needs a number") }
    return v
}
var tapsPath: String?
while !args.isEmpty {
    let flag = args.removeFirst()
    if flag == "--snap" { snap = true; continue }
    let value = args.isEmpty ? nil : args.removeFirst()
    switch flag {
    case "--width": width = Int(number(value, flag))
    case "--fps": fps = number(value, flag)
    case "--max-hold": maxHold = number(value, flag)
    case "--final-hold": finalHold = number(value, flag)
    case "--start": start = number(value, flag)
    case "--end": end = number(value, flag)
    case "--scale": scale = number(value, flag)
    case "--pace": pace = number(value, flag)
    case "--fade": fade = number(value, flag)
    case "--fade-color":
        guard value == "white" || value == "black" else { fail("--fade-color is white or black") }
        fadeWhite = value == "white"
    case "--taps": tapsPath = value
    case "--fast":
        let parts = (value ?? "").split(whereSeparator: { $0 == "-" || $0 == ":" }).compactMap { Double($0) }
        guard parts.count == 3, parts[0] < parts[1], parts[2] > 0 else { fail("--fast is FROM-TO:N, not \(value ?? "")") }
        fasts.append(Fast(from: parts[0], to: parts[1], speed: parts[2]))
    default: fail("unknown option \(flag)")
    }
}
guard fps > 0 else { fail("--fps must be positive") }
if let tapsPath {
    guard let text = try? String(contentsOfFile: tapsPath, encoding: .utf8) else { fail("can't read \(tapsPath)") }
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let v = line.split(separator: " ").compactMap { Double($0) }
        guard v.count == 3 else { fail("a tap is SECONDS X Y, not \(line)") }
        taps.append(Tap(time: v[0], x: v[1], y: v[2]))
    }
}


// The recording's frame times: a frame is written only when the screen changed.
let asset = AVURLAsset(url: inURL)
guard let track = try? await asset.loadTracks(withMediaType: .video).first else { fail("no video in \(inURL.path)") }
let size = try await track.load(.naturalSize)
guard let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { fail("can't read \(inURL.path)") }
var times: [Double] = []
repeat { times.append(cursor.presentationTimeStamp.seconds) } while cursor.stepInDecodeOrder(byCount: 1) == 1
times.sort()
let duration = try await asset.load(.duration).seconds
end = min(end, duration)
times = times.filter { $0 >= start && $0 < end }
if times.first.map({ $0 > start }) ?? true { times.insert(start, at: 0) }

if snap {
    for i in taps.indices {
        if let t = times.first(where: { $0 >= taps[i].time && $0 <= taps[i].time + 1.5 }) { taps[i].time = t }
    }
}
if let pace {
    let times = taps.map(\.time).sorted()
    for (a, b) in zip(times, times.dropFirst()) where b - 0.25 > a + pace {
        fasts.append(Fast(from: a + pace, to: b - 0.25, speed: 8))
    }
}
func speed(at t: Double) -> Double { fasts.first { t >= $0.from && t < $0.to }?.speed ?? 1 }

// Keep a frame when at least 1/fps of playing time passed since the last kept one, or when it
// then stays put.
let step = 1 / fps
var kept: [Double] = []
for (i, t) in times.enumerated() {
    let next = i + 1 < times.count ? times[i + 1] : end
    let gap = step * speed(at: t)
    if kept.isEmpty || t - kept.last! >= gap || next - t >= gap { kept.append(t) }
}
// A tap's ring needs frames even over a still screen.
let ring = 0.48
for tap in taps where tap.time >= start && tap.time < end {
    var t = tap.time
    while t <= tap.time + ring { kept.append(t); t += step }
}
kept = Array(Set(kept)).sorted()



let outWidth = width ?? Int(size.width)
let k = Double(outWidth) / Double(size.width)
let generator = AVAssetImageGenerator(asset: asset)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
generator.maximumSize = CGSize(width: Double(outWidth), height: Double(size.height) * k)

let fadeFrames = fade > 0 ? max(2, Int((fade * fps).rounded())) : 0
guard let dst = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.gif.identifier as CFString, kept.count + 2 * fadeFrames, nil) else { fail("can't write \(outURL.path)") }
CGImageDestinationSetProperties(dst, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

var written = 0.0
func add(_ image: CGImage, hold: Double) {
    // GIF delays are in hundredths; browsers treat under 0.02 s as 0.1 s.
    let hold = max(0.02, (hold * 100).rounded() / 100)
    written += hold
    CGImageDestinationAddImage(dst, image, [kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFDelayTime: hold,
        kCGImagePropertyGIFUnclampedDelayTime: hold,
    ]] as CFDictionary)
}
/// The image over the fade color at opacity `alpha`.
func faded(_ image: CGImage, _ alpha: Double) -> CGImage {
    guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    ctx.setFillColor(fadeWhite ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(rect)
    ctx.setAlpha(alpha)
    ctx.draw(image, in: rect)
    return ctx.makeImage() ?? image
}
var lastImage: CGImage?
for (i, t) in kept.enumerated() {
    // The latest frame at or before t; a ring frame between changes reuses the screen it's over.
    let frameTime = times.last { $0 <= t } ?? t
    var image: CGImage
    do {
        image = try await generator.image(at: CMTime(seconds: frameTime, preferredTimescale: 600)).image
    } catch { fail("can't read the frame at \(frameTime) s: \(error)") }
    let active = taps.filter { t >= $0.time && t < $0.time + ring }
    if !active.isEmpty, let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        let h = Double(image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pt = scale * k
        for tap in active {
            let p = (t - tap.time) / ring
            let c = CGPoint(x: tap.x * pt, y: h - tap.y * pt)
            let alpha = 1 - p
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.45, blue: 1, alpha: 0.55 * alpha))
            let dot = 9 * pt
            ctx.fillEllipse(in: CGRect(x: c.x - dot, y: c.y - dot, width: 2 * dot, height: 2 * dot))
            let r = (10 + 22 * p) * pt
            ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.45, blue: 1, alpha: 0.9 * alpha))
            ctx.setLineWidth(3 * pt)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        if let marked = ctx.makeImage() { image = marked }
    }
    if i == 0 {
        for f in 0..<fadeFrames { add(faded(image, Double(f) / Double(fadeFrames)), hold: fade / Double(fadeFrames)) }
    }
    var hold = i + 1 < kept.count ? (kept[i + 1] - t) / speed(at: t) : finalHold
    if i + 1 < kept.count { hold = min(hold, maxHold) }
    add(image, hold: hold)
    lastImage = image
}
if let lastImage {
    for f in 1...max(1, fadeFrames) where fadeFrames > 0 { add(faded(lastImage, 1 - Double(f) / Double(fadeFrames)), hold: fade / Double(fadeFrames)) }
}
guard CGImageDestinationFinalize(dst) else { fail("can't write \(outURL.path)") }
let bytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
print("\(outURL.path): \(kept.count + 2 * fadeFrames) frames, \(String(format: "%.1f", written)) s, \(bytes / 1024) KiB")
