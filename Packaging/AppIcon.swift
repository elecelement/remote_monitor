import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Render a terminal prompt and utilization bars on the same grid at each Dock size.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}

func render(points: Int, scale: Int) throws {
    let size = points * scale
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 128, y: CGFloat(size) / 128)
    let frame = CGRect(x: 9, y: 9, width: 110, height: 110)
    let tile = CGPath(roundedRect: frame, cornerWidth: 26, cornerHeight: 26, transform: nil)
    ctx.addPath(tile)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [rgb(0.05, 0.15, 0.18), rgb(0.07, 0.39, 0.34)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 16, y: 12),
                           end: CGPoint(x: 115, y: 120), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.setStrokeColor(rgb(0.53, 0.92, 0.74))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(7)
    ctx.move(to: CGPoint(x: 33, y: 78))
    ctx.addLine(to: CGPoint(x: 47, y: 64))
    ctx.addLine(to: CGPoint(x: 33, y: 50))
    ctx.strokePath()
    for (x, height) in [(60, 12), (73, 23), (86, 36)] {
        ctx.move(to: CGPoint(x: x, y: 48))
        ctx.addLine(to: CGPoint(x: x, y: 48 + height))
        ctx.strokePath()
    }
    let suffix = scale == 1 ? "" : "@2x"
    let url = directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) { throw CocoaError(.fileWriteUnknown) }
}

for points in [16, 32, 128, 256, 512] {
    try render(points: points, scale: 1)
    try render(points: points, scale: 2)
}
