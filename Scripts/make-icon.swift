// Renders the Keens In Key app icon (a Camelot-style wheel with a "K") to PNG files and builds an .icns.
// Usage: swift Scripts/make-icon.swift <output-dir>
import Foundation
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func hue(_ n: Int) -> CGFloat {
    let h = 180.0 - 30.0 * Double(n)
    return CGFloat((h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)) / 360
}

func render(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

    // Rounded-square background (macOS icon grid: ~80% of canvas).
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.19, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Wheel.
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    let outerR = rect.width * 0.42
    let midR = rect.width * 0.29
    let innerR = rect.width * 0.17
    for n in 1...12 {
        let startAngle = CGFloat.pi / 2 - CGFloat(n - 1) * CGFloat.pi / 6 - CGFloat.pi / 12
        let endAngle = startAngle - CGFloat.pi / 6
        for (r0, r1, sat, bri) in [(midR, outerR, 0.55, 0.95), (innerR, midR, 0.7, 0.8)] {
            let seg = CGMutablePath()
            seg.addArc(center: centre, radius: r1, startAngle: startAngle, endAngle: endAngle, clockwise: true)
            seg.addArc(center: centre, radius: r0, startAngle: endAngle, endAngle: startAngle, clockwise: false)
            seg.closeSubpath()
            ctx.addPath(seg)
            ctx.setFillColor(NSColor(calibratedHue: hue(n), saturation: sat, brightness: bri, alpha: 1).cgColor)
            ctx.fillPath()
            ctx.addPath(seg)
            ctx.setStrokeColor(NSColor(calibratedWhite: 0.05, alpha: 0.9).cgColor)
            ctx.setLineWidth(s * 0.006)
            ctx.strokePath()
        }
    }
    // Centre disc + letter.
    ctx.setFillColor(NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: centre.x - innerR, y: centre.y - innerR, width: innerR * 2, height: innerR * 2))
    let font = NSFont.systemFont(ofSize: innerR * 1.5, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let str = NSAttributedString(string: "K", attributes: attrs)
    let sz = str.size()
    str.draw(at: NSPoint(x: centre.x - sz.width / 2, y: centre.y - sz.height / 2 + innerR * 0.05))
    ctx.restoreGState()
    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL, pixels: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
                   ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    writePNG(render(size: px), to: iconset.appendingPathComponent("\(name).png"), pixels: px)
}
writePNG(render(size: 1024), to: outDir.appendingPathComponent("AppIcon-1024.png"), pixels: 1024)
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
task.launch()
task.waitUntilExit()
print("icon written to \(outDir.path), iconutil status \(task.terminationStatus)")
