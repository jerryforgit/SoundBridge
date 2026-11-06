import AppKit
import Foundation

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let context = NSGraphicsContext.current else {
    fputs("no graphics context\n", stderr)
    exit(1)
}
context.imageInterpolation = .high

let bounds = NSRect(x: 64, y: 64, width: size - 128, height: size - 128)
let rounded = NSBezierPath(roundedRect: bounds, xRadius: 220, yRadius: 220)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.05, green: 0.58, blue: 0.66, alpha: 1.0),
    NSColor(calibratedRed: 0.03, green: 0.10, blue: 0.28, alpha: 1.0),
])!
gradient.draw(in: rounded, angle: -55)

NSColor(white: 1.0, alpha: 0.14).setStroke()
rounded.lineWidth = 6
rounded.stroke()

if let symbol = NSImage(systemSymbolName: "hifispeaker.2.fill", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: 520, weight: .regular)
    if let configured = symbol.withSymbolConfiguration(config) {
        let tinted = NSImage(size: configured.size)
        tinted.lockFocus()
        configured.draw(in: NSRect(origin: .zero, size: configured.size))
        NSColor.white.setFill()
        NSRect(origin: .zero, size: configured.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        let drawSize = NSSize(width: 560, height: 560)
        let rect = NSRect(
            x: (size - drawSize.width) / 2,
            y: (size - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        tinted.draw(in: rect)
    }
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to encode png\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
