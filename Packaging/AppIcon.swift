import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The three panes mirror the default tmux workspace. Align the gutters to pixels
// so both rows are still distinct at the smallest Dock and Finder sizes.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}

func render(points: Int, scale: Int) throws {
    let size = points * scale
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let unit = CGFloat(size) / 128
    ctx.scaleBy(x: unit, y: unit)
    let frame = CGRect(x: 9, y: 9, width: 110, height: 110)
    let tile = CGPath(roundedRect: frame, cornerWidth: 26, cornerHeight: 26, transform: nil)
    let background = rgb(0.055, 0.185, 0.185)
    ctx.setFillColor(background)
    ctx.addPath(tile)
    ctx.fillPath()

    let panes = CGRect(x: 29, y: 35, width: 70, height: 58)
    let mark = CGPath(roundedRect: panes, cornerWidth: 8, cornerHeight: 8, transform: nil)
    ctx.addPath(mark)
    ctx.clip()
    ctx.setFillColor(rgb(0.61, 0.94, 0.80))
    ctx.fill(panes)
    let gutter = max(1, (6 * unit).rounded()) / unit
    let split = ((64 - gutter / 2) * unit).rounded() / unit
    ctx.setFillColor(background)
    ctx.fill(CGRect(x: panes.minX, y: split, width: panes.width, height: gutter))
    ctx.fill(CGRect(x: split, y: split, width: gutter, height: panes.maxY - split))
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
