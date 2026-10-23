import AppKit

// Generated from a system symbol; no downloaded artwork or image dependency.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSColor(calibratedRed: 0.075, green: 0.16, blue: 0.24, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: Double(pixels) * 0.055, dy: Double(pixels) * 0.055),
                     xRadius: Double(pixels) * 0.21, yRadius: Double(pixels) * 0.21).fill()
        let symbol = NSImage(systemSymbolName: "location.north.circle", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: Double(pixels) * 0.59, weight: .light))!
        let tint = NSImage(size: symbol.size)
        tint.lockFocus()
        NSColor(calibratedRed: 0.63, green: 0.86, blue: 0.96, alpha: 1).setFill()
        NSRect(origin: .zero, size: symbol.size).fill()
        symbol.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
        tint.unlockFocus()
        let inset = Double(pixels) * 0.20
        tint.draw(in: bounds.insetBy(dx: inset, dy: inset))
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
