// Renders the brand assets from the SVG masters. Run via ./render.sh.
import AppKit

let out = CommandLine.arguments[1]

func bitmap(_ w: Int, _ h: Int, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(path)"))
}

func load(_ name: String) -> NSImage {
    guard let img = NSImage(contentsOf: URL(fileURLWithPath: name)) else { fatalError("cannot load \(name)") }
    return img
}

// App icon set.
let icon = load("icon.svg")
try? FileManager.default.createDirectory(atPath: "\(out)/AppIcon.iconset", withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let rep = bitmap(px, px) { icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px)) }
        save(rep, "AppIcon.iconset/icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png")
    }
}
save(bitmap(1024, 1024) { icon.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024)) }, "icon-1024.png")

// Menu bar template glyph, 18 pt.
let glyph = load("menubar.svg")
for scale in [1, 2] {
    let px = 18 * scale
    save(bitmap(px, px) { glyph.draw(in: NSRect(x: 0, y: 0, width: px, height: px)) },
         "MenuBarIcon\(scale == 2 ? "@2x" : "").png")
}

// Logo lockups at 2x (480 px tall), drawn natively so the wordmark gets real font weights.
for (name, color) in [("light", NSColor(srgbRed: 0x14/255, green: 0x18/255, blue: 0x21/255, alpha: 1)),
                      ("dark", NSColor.white)] {
    let size: CGFloat = 184
    let word = NSMutableAttributedString()
    word.append(NSAttributedString(string: "Take ", attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color, .kern: -3]))
    word.append(NSAttributedString(string: "Control", attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: .heavy), .foregroundColor: color, .kern: -3]))
    let text = word.size()
    let rep = bitmap(504 + Int(text.width) + 48, 480) {
        icon.draw(in: NSRect(x: 0, y: 0, width: 480, height: 480))
        word.draw(at: NSPoint(x: 504, y: (480 - text.height) / 2 + 6))
    }
    save(rep, "logo-\(name).png")
}
