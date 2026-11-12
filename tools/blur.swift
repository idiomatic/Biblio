// swift tools/blur.swift IN OUT POINT_WIDTH x,y,w,h... — Gaussian-blur each rect (in points, top-left origin), keeping alpha.
// OUT is PNG, JPEG, or HEIC by its extension.
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("blur: \(message)\nusage: swift tools/blur.swift IN OUT POINT_WIDTH x,y,w,h...\n".utf8))
    exit(2)
}

let a = CommandLine.arguments
guard a.count >= 5 else { fail("expected an input, an output, a point width, and at least one rect") }
guard let pointWidth = Double(a[3]), pointWidth > 0 else { fail("POINT_WIDTH must be a positive number, not \(a[3])") }
let rects = a[4...].map { spec -> [CGFloat] in
    let v = spec.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
    guard v.count == 4 else { fail("a rect is four numbers, x,y,w,h, not \(spec)") }
    return v
}
let outURL = URL(fileURLWithPath: a[2])
guard let type = UTType(filenameExtension: outURL.pathExtension), [UTType.png, .jpeg, .heic].contains(type) else {
    fail("OUT must end in .png, .jpg, or .heic")
}
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil),
      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("can't read \(a[1])") }
let k = CGFloat(cg.width) / CGFloat(pointWidth)
let H = CGFloat(cg.height)
var img = CIImage(cgImage: cg)
let input = img
for v in rects {
    let r = CGRect(x: v[0] * k, y: H - (v[1] + v[3]) * k, width: v[2] * k, height: v[3] * k).integral
    let blurred = input.cropped(to: r).clampedToExtent()
        .applyingGaussianBlur(sigma: 7 * k).cropped(to: r)
    img = blurred.composited(over: img)
}
let ctx = CIContext()
guard let out = ctx.createCGImage(img, from: input.extent),
      let dst = CGImageDestinationCreateWithURL(outURL as CFURL, type.identifier as CFString, 1, nil) else { fail("can't write \(a[2])") }
CGImageDestinationAddImage(dst, out, nil)
guard CGImageDestinationFinalize(dst) else { fail("can't write \(a[2])") }
