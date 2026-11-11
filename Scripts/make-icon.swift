// Draws the app icon and writes a 1024 x 1024 PNG.
// Usage: swift Scripts/make-icon.swift <output.png>
import AppKit

let side = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: the standard macOS icon shape with a blue-to-indigo gradient.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.56, blue: 1.0, alpha: 1),
           ending: NSColor(srgbRed: 0.33, green: 0.20, blue: 0.82, alpha: 1))!
    .draw(in: shape, angle: -90)

NSColor.white.set()

// A play triangle with softened corners.
let play = NSBezierPath()
play.move(to: NSPoint(x: 440, y: 400))
play.line(to: NSPoint(x: 440, y: 624))
play.line(to: NSPoint(x: 624, y: 512))
play.close()
play.lineJoinStyle = .round
play.lineWidth = 44
play.fill()
play.stroke()

// Four corner marks closing in on it: "make this smaller".
let center = 512.0, reach = 205.0, arm = 92.0
let marks = NSBezierPath()
for dx in [-1.0, 1.0] {
    for dy in [-1.0, 1.0] {
        let corner = NSPoint(x: center + dx * reach, y: center + dy * reach)
        marks.move(to: NSPoint(x: corner.x + dx * arm, y: corner.y))
        marks.line(to: corner)
        marks.line(to: NSPoint(x: corner.x, y: corner.y + dy * arm))
    }
}
marks.lineWidth = 38
marks.lineCapStyle = .round
marks.lineJoinStyle = .round
NSColor.white.withAlphaComponent(0.92).set()
marks.stroke()

NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try rep.representation(using: .png, properties: [:])!.write(to: output)
