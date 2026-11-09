import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
      throw NSError(domain: "MoneyApp.Icon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    let frame = NSRect(x: 64, y: 64, width: 896, height: 896)
    let background = NSBezierPath(roundedRect: frame, xRadius: 205, yRadius: 205)
    NSColor(calibratedRed: 0.055, green: 0.23, blue: 0.23, alpha: 1).setFill()
    background.fill()
    let heights: [CGFloat] = [220, 350, 490]
    for index in 0..<3 {
      let bar = NSBezierPath(
        roundedRect: NSRect(
          x: 235 + CGFloat(index) * 195, y: 265, width: 150, height: heights[index]), xRadius: 48,
        yRadius: 48)
      (index == 2
        ? NSColor(calibratedRed: 0.48, green: 0.89, blue: 0.71, alpha: 1)
        : NSColor(calibratedWhite: 0.97, alpha: index == 0 ? 0.75 : 0.95)).setFill()
      bar.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw NSError(domain: "MoneyApp.Icon", code: 2)
    }
    let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    try data.write(to: output.appendingPathComponent(name))
  }
}
