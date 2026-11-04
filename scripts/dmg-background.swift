// Renders the DMG window background at 1x and 2x.
// Usage: swift dmg-background.swift <output-directory>
import AppKit

let size = NSSize(width: 660, height: 400)
let appCenter = NSPoint(x: 170, y: 200)
let applicationsCenter = NSPoint(x: 490, y: 200)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Soft light gradient, so Finder's dark icon labels stay readable.
    NSGradient(colors: [
        NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.90, green: 0.91, blue: 0.93, alpha: 1),
    ])!.draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Arrow from the app to Applications (Finder's y-axis points down; ours up).
    let y = size.height - appCenter.y
    let start = appCenter.x + 78
    let end = applicationsCenter.x - 78
    let arrow = NSBezierPath()
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: start, y: y))
    arrow.line(to: NSPoint(x: end, y: y))
    arrow.move(to: NSPoint(x: end - 14, y: y + 12))
    arrow.line(to: NSPoint(x: end, y: y))
    arrow.line(to: NSPoint(x: end - 14, y: y - 12))
    NSColor(white: 0.55, alpha: 1).setStroke()
    arrow.stroke()

    let caption = "Drag Top NotchSH into Applications to install"
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    caption.draw(
        in: NSRect(x: 0, y: 52, width: size.width, height: 22),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor(white: 0.4, alpha: 1),
            .paragraphStyle: paragraph,
        ]
    )

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try render(scale: 1).write(to: output.appendingPathComponent("background.png"))
try render(scale: 2).write(to: output.appendingPathComponent("background@2x.png"))
