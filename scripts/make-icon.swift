#!/usr/bin/env swift
// Renders the NotchGram app icon: a pure-black glass tile with a notch at its
// top edge and an ice-cyan chat panel unfolding out of it — the app's one
// gesture, drawn. Deliberately nothing like a paper plane.
//
//   swift scripts/make-icon.swift [appiconset-dir] [preview-png]
//
// Defaults: Sources/App/Assets.xcassets/AppIcon.appiconset and
// docs/media/icon.png (512 px). Approach borrowed from Dictate's generator.

import AppKit
import Foundation

let arguments = CommandLine.arguments
let iconSet = URL(fileURLWithPath: arguments.count > 1
    ? arguments[1] : "Sources/App/Assets.xcassets/AppIcon.appiconset")
let preview = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "docs/media/icon.png")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
try FileManager.default.createDirectory(
    at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

let ice = rgb(0x64D2FF)

/// The panel silhouette: a rectangle hanging from `top`, with concave fillets
/// where it meets the top edge (the slab flaring out of the notch) and round
/// bottom corners — NotchGram's `NotchSlabShape`, simplified.
func slab(_ rect: NSRect, topRadius: CGFloat, bottomRadius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let top = rect.maxY
    path.move(to: NSPoint(x: rect.minX - topRadius, y: top))
    path.curve(
        to: NSPoint(x: rect.minX, y: top - topRadius),
        controlPoint1: NSPoint(x: rect.minX - topRadius * 0.45, y: top),
        controlPoint2: NSPoint(x: rect.minX, y: top - topRadius * 0.55))
    path.line(to: NSPoint(x: rect.minX, y: rect.minY + bottomRadius))
    path.appendArc(
        withCenter: NSPoint(x: rect.minX + bottomRadius, y: rect.minY + bottomRadius),
        radius: bottomRadius, startAngle: 180, endAngle: 270)
    path.line(to: NSPoint(x: rect.maxX - bottomRadius, y: rect.minY))
    path.appendArc(
        withCenter: NSPoint(x: rect.maxX - bottomRadius, y: rect.minY + bottomRadius),
        radius: bottomRadius, startAngle: 270, endAngle: 360)
    path.line(to: NSPoint(x: rect.maxX, y: top - topRadius))
    path.curve(
        to: NSPoint(x: rect.maxX + topRadius, y: top),
        controlPoint1: NSPoint(x: rect.maxX, y: top - topRadius * 0.55),
        controlPoint2: NSPoint(x: rect.maxX + topRadius * 0.45, y: top))
    path.close()
    return path
}

func drawIcon(canvas: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    defer { image.unlockFocus() }

    // macOS icon grid: the tile sits inside a margin on a transparent canvas.
    let inset = canvas * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let unit = tile.width
    let squircle = NSBezierPath(roundedRect: tile, xRadius: unit * 0.225, yRadius: unit * 0.225)

    // Drop shadow.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.012)
    shadow.shadowBlurRadius = canvas * 0.028
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()

    // Obsidian: near-black with the faintest cool lift toward the top.
    NSGradient(colors: [rgb(0x1A1E26), rgb(0x0B0D11), rgb(0x040506)])!
        .draw(in: tile, angle: -90)

    // Ice glow pooling under the panel.
    let glowCenter = NSPoint(x: tile.midX, y: tile.minY + unit * 0.34)
    NSGradient(colors: [ice.withAlphaComponent(0.30), ice.withAlphaComponent(0)])!
        .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: unit * 0.62,
              options: [])

    // The unfolding panel, hanging from the top edge.
    // Wider than tall, like the real 880×580 slab — a phone it is not.
    let panelWidth = unit * 0.78
    let panelBottom = tile.minY + unit * 0.30
    let panel = NSRect(
        x: tile.midX - panelWidth / 2, y: panelBottom,
        width: panelWidth, height: tile.maxY - panelBottom)
    let panelPath = slab(panel, topRadius: unit * 0.05, bottomRadius: unit * 0.11)
    NSGradient(colors: [rgb(0x0E2A36), rgb(0x123C4E)])!.draw(in: panelPath, angle: -90)
    NSGradient(colors: [ice.withAlphaComponent(0.05), ice.withAlphaComponent(0.30)])!
        .draw(in: panelPath, angle: -90)
    ice.withAlphaComponent(0.85).setStroke()
    panelPath.lineWidth = max(1, unit * 0.012)
    panelPath.stroke()

    // The notch: pure black, flush with the top edge, inside the panel.
    let notchWidth = unit * 0.30
    let notchHeight = unit * 0.085
    let notch = NSBezierPath(
        roundedRect: NSRect(x: tile.midX - notchWidth / 2, y: tile.maxY - notchHeight,
                            width: notchWidth, height: notchHeight + unit * 0.06),
        xRadius: unit * 0.05, yRadius: unit * 0.05)
    NSColor.black.setFill()
    notch.fill()

    // Two message bubbles inside the panel: incoming graphite, outgoing ice.
    let bubbleHeight = unit * 0.09
    let incoming = NSBezierPath(
        roundedRect: NSRect(x: panel.minX + unit * 0.07, y: panel.minY + unit * 0.24,
                            width: panelWidth * 0.52, height: bubbleHeight),
        xRadius: bubbleHeight / 2, yRadius: bubbleHeight / 2)
    NSColor.white.withAlphaComponent(0.9).setFill()
    incoming.fill()
    let outgoing = NSBezierPath(
        roundedRect: NSRect(x: panel.maxX - unit * 0.07 - panelWidth * 0.42,
                            y: panel.minY + unit * 0.08,
                            width: panelWidth * 0.42, height: bubbleHeight),
        xRadius: bubbleHeight / 2, yRadius: bubbleHeight / 2)
    ice.setFill()
    outgoing.fill()

    // Glass rim: a faint hairline of light around the tile.
    NSGraphicsContext.current?.restoreGraphicsState()
    let rim = NSBezierPath(
        roundedRect: tile.insetBy(dx: unit * 0.004, dy: unit * 0.004),
        xRadius: unit * 0.221, yRadius: unit * 0.221)
    rim.lineWidth = max(1, unit * 0.006)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    rim.stroke()

    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { throw CocoaError(.fileWriteUnknown) }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

let master = drawIcon(canvas: 1024)
let entries: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]
var images: [[String: String]] = []
for entry in entries {
    let pixels = entry.size * entry.scale
    let name = "icon_\(entry.size)x\(entry.size)\(entry.scale == 2 ? "@2x" : "").png"
    // Small sizes are drawn at their own size, not downsampled from 1024, so
    // hairlines snap to whole pixels.
    try writePNG(pixels <= 64 ? drawIcon(canvas: CGFloat(pixels)) : master,
                 pixels: pixels, to: iconSet.appendingPathComponent(name))
    images.append([
        "filename": name, "idiom": "mac",
        "scale": "\(entry.scale)x", "size": "\(entry.size)x\(entry.size)",
    ])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appendingPathComponent("Contents.json"))
try writePNG(master, pixels: 512, to: preview)
print("icon → \(iconSet.path), preview → \(preview.path)")
