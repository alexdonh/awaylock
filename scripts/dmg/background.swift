#!/usr/bin/env swift
// Renders the DMG window background: an arrow from the app to Applications and the instruction.
// English only: Finder can't localize a DMG background, and the arrow says it in any language.
// Run by scripts/dmg/layout.sh, which commits the result. Usage: background.swift <out.tiff> (1x + 2x)
// Layout must match scripts/dmg/layout.sh: 660×400 window, 128 pt icons centred at (170, 178), (490, 178).
import AppKit

let size = CGSize(width: 660, height: 400)
let headline = "Drag AwayLock to Applications."

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                               pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size   // points, so drawing below is in the window's coordinates
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // AppKit is bottom-up; Finder positions are top-down.
    func y(_ top: CGFloat) -> CGFloat { size.height - top }

    NSColor(white: 0.965, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()

    // Arrow between the icons.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 268, y: y(178)))
    arrow.line(to: NSPoint(x: 392, y: y(178)))
    arrow.move(to: NSPoint(x: 382, y: y(168)))
    arrow.line(to: NSPoint(x: 392, y: y(178)))
    arrow.line(to: NSPoint(x: 382, y: y(188)))
    arrow.lineWidth = 1.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(white: 0.55, alpha: 1).setStroke()
    arrow.stroke()

    let centered = NSMutableParagraphStyle()
    centered.alignment = .center
    func draw(_ text: String, top: CGFloat, height: CGFloat, font: NSFont, color: NSColor) {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: centered])
            .draw(in: NSRect(x: 40, y: y(top + height), width: size.width - 80, height: height))
    }
    draw(headline, top: 316, height: 24, font: .systemFont(ofSize: 16, weight: .semibold), color: NSColor(white: 0.12, alpha: 1))
    return rep
}

let out = CommandLine.arguments.dropFirst().first ?? "background.tiff"
let image = NSImage(size: size)
image.addRepresentation(render(scale: 1))
image.addRepresentation(render(scale: 2))
guard let tiff = image.tiffRepresentation(using: .lzw, factor: 0) else { fatalError("could not encode TIFF") }
try tiff.write(to: URL(fileURLWithPath: out))
