import AppKit
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first ?? "Resources/CloudShelf-icon.png"
let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

func rounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func arrowHead(at point: NSPoint, direction: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: point)
    path.line(to: NSPoint(x: point.x - 42 * cos(direction - .pi / 6), y: point.y - 42 * sin(direction - .pi / 6)))
    path.line(to: NSPoint(x: point.x - 42 * cos(direction + .pi / 6), y: point.y - 42 * sin(direction + .pi / 6)))
    path.close()
    color.setFill()
    path.fill()
}

image.lockFocus()
NSGraphicsContext.current?.shouldAntialias = true

let canvas = NSRect(x: 28, y: 28, width: 968, height: 968)
let background = NSGradient(starting: color(15, 118, 110), ending: color(8, 74, 70))!
background.draw(in: rounded(canvas, radius: 218), angle: 90)

// Subtle inset produces the recognizable macOS application-icon silhouette.
color(7, 63, 60).withAlphaComponent(0.30).setFill()
rounded(NSRect(x: 92, y: 82, width: 840, height: 760), radius: 154).fill()

// A remote workspace represented as a clean, layered folder.
color(234, 248, 246).setFill()
rounded(NSRect(x: 178, y: 258, width: 668, height: 454), radius: 70).fill()
color(213, 239, 235).setFill()
rounded(NSRect(x: 178, y: 650, width: 302, height: 108), radius: 48).fill()
rounded(NSRect(x: 438, y: 650, width: 408, height: 108), radius: 48).fill()

// Three compact file rows make the subject read as a file manager at icon size.
let fileColors = [color(79, 160, 150), color(44, 126, 119), color(230, 121, 78)]
for (index, tint) in fileColors.enumerated() {
    let y = CGFloat(553 - index * 84)
    tint.setFill()
    rounded(NSRect(x: 254, y: y, width: 126, height: 48), radius: 18).fill()
    color(29, 81, 77).withAlphaComponent(0.30).setFill()
    rounded(NSRect(x: 412, y: y + 10, width: 282, height: 28), radius: 14).fill()
}

// Bidirectional transfer arrows identify the app's core job without text.
let transfer = color(231, 111, 71)
transfer.setStroke()
let upper = NSBezierPath()
upper.move(to: NSPoint(x: 602, y: 740))
upper.curve(to: NSPoint(x: 764, y: 740), controlPoint1: NSPoint(x: 650, y: 740), controlPoint2: NSPoint(x: 716, y: 740))
upper.lineWidth = 24
upper.lineCapStyle = .round
upper.stroke()
arrowHead(at: NSPoint(x: 786, y: 740), direction: 0, color: transfer)

let lower = NSBezierPath()
lower.move(to: NSPoint(x: 742, y: 690))
lower.curve(to: NSPoint(x: 580, y: 690), controlPoint1: NSPoint(x: 694, y: 690), controlPoint2: NSPoint(x: 628, y: 690))
lower.lineWidth = 24
lower.lineCapStyle = .round
lower.stroke()
arrowHead(at: NSPoint(x: 558, y: 690), direction: .pi, color: transfer)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render the application icon.")
}
try png.write(to: URL(fileURLWithPath: outputPath))
