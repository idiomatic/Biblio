// swift docs/screenshots/blur.swift IN OUT POINT_WIDTH x,y,w,h... — Gaussian-blur each rect (in points, top-left origin), keeping alpha.
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!
let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let k = CGFloat(cg.width) / CGFloat(Double(a[3])!)
let H = CGFloat(cg.height)
var img = CIImage(cgImage: cg)
let input = img
for spec in a[4...] {
    let v = spec.split(separator: ",").map { CGFloat(Double($0)!) }
    let r = CGRect(x: v[0] * k, y: H - (v[1] + v[3]) * k, width: v[2] * k, height: v[3] * k).integral
    let blurred = input.cropped(to: r).clampedToExtent()
        .applyingGaussianBlur(sigma: 7 * k).cropped(to: r)
    img = blurred.composited(over: img)
}
let ctx = CIContext()
let out = ctx.createCGImage(img, from: input.extent)!
let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dst, out, nil)
CGImageDestinationFinalize(dst)
