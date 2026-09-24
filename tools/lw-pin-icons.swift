// Renders the overlay's pin button icons from SF Symbols into hammerspoon/icons/.
// Hammerspoon's hs.image cannot load SF Symbols by name, so they are baked to PNG once.
//   swift tools/lw-pin-icons.swift
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("hammerspoon/icons")

// symbol, file, gray level: outline = ready to pin (mid gray), filled = pinned (near black)
let icons: [(String, String, CGFloat)] = [
    ("pin", "pin-off.png", 0.45),
    ("pin.fill", "pin-on.png", 0.08),
]
let px = 48  // drawn at 16pt in the overlay, so 3x

for (name, file, gray) in icons {
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.8, weight: .semibold)
    guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { fatalError("no symbol \(name)") }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = sym.size
    let r = NSRect(x: (CGFloat(px) - s.width) / 2, y: (CGFloat(px) - s.height) / 2,
                   width: s.width, height: s.height)
    sym.draw(in: r)
    NSColor(white: gray, alpha: 1).set()
    r.fill(using: .sourceAtop)  // tint the template glyph
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(file))
    print("wrote \(file)")
}
