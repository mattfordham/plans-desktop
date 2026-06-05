#!/usr/bin/env swift

// make-icon.swift
//
// Standalone generator for the Plans app icon. Draws a full-bleed rounded-rect
// ("squircle"-ish) icon with a diagonal blue → purple → pink gradient and a
// centered WHITE `list.bullet` SF Symbol glyph on top, matching the menu-bar
// icon (see Sources/Plans/MenuBarLabel.swift).
//
// It renders one PNG per required macOS iconset size, using Apple's mandated
// filenames, into an output directory (default `Plans.iconset` in the cwd).
//
// Usage:
//   ./Tools/make-icon.swift [output-iconset-dir]
//   swift Tools/make-icon.swift [output-iconset-dir]
//
// Afterwards, convert to .icns with:
//   iconutil -c icns Plans.iconset -o Resources/Plans.icns

import AppKit
import CoreGraphics
import Foundation

// MARK: - Required iconset entries (Apple mandated filenames + pixel sizes)

struct IconEntry {
    let fileName: String
    let pixelSize: Int
}

let entries: [IconEntry] = [
    IconEntry(fileName: "icon_16x16.png", pixelSize: 16),
    IconEntry(fileName: "icon_16x16@2x.png", pixelSize: 32),
    IconEntry(fileName: "icon_32x32.png", pixelSize: 32),
    IconEntry(fileName: "icon_32x32@2x.png", pixelSize: 64),
    IconEntry(fileName: "icon_128x128.png", pixelSize: 128),
    IconEntry(fileName: "icon_128x128@2x.png", pixelSize: 256),
    IconEntry(fileName: "icon_256x256.png", pixelSize: 256),
    IconEntry(fileName: "icon_256x256@2x.png", pixelSize: 512),
    IconEntry(fileName: "icon_512x512.png", pixelSize: 512),
    IconEntry(fileName: "icon_512x512@2x.png", pixelSize: 1024),
]

// MARK: - Drawing

/// Brand gradient stops (diagonal blue → purple → pink), matching the
/// "colorful gradient" brief and reading well on light/dark Dock backgrounds.
let gradientColors: [NSColor] = [
    NSColor(srgbRed: 0.20, green: 0.45, blue: 0.98, alpha: 1.0), // blue
    NSColor(srgbRed: 0.55, green: 0.30, blue: 0.95, alpha: 1.0), // purple
    NSColor(srgbRed: 0.98, green: 0.35, blue: 0.70, alpha: 1.0), // pink
]

/// Draws the full icon into the current graphics context for a given pixel size.
func drawIcon(pixelSize: Int) {
    let size = CGFloat(pixelSize)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // macOS Big Sur+ icons use a superellipse-ish corner radius of roughly
    // 0.2237 of the icon side. A rounded rect approximates this closely enough
    // for our purposes.
    let cornerRadius = size * 0.2237
    let roundedPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    NSGraphicsContext.current?.saveGraphicsState()
    roundedPath.addClip()

    // Diagonal gradient (45°) across the full canvas.
    if let gradient = NSGradient(colors: gradientColors) {
        gradient.draw(in: rect, angle: 45)
    } else {
        gradientColors.first?.setFill()
        rect.fill()
    }

    NSGraphicsContext.current?.restoreGraphicsState()

    // Centered white `list.bullet` glyph, sized to ~57% of the canvas.
    let glyphFraction: CGFloat = 0.57
    let glyphSide = size * glyphFraction

    let symbolConfig = NSImage.SymbolConfiguration(
        pointSize: glyphSide,
        weight: .semibold,
        scale: .large
    )

    if let baseSymbol = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Plans"),
       let symbol = baseSymbol.withSymbolConfiguration(symbolConfig) {
        // Tint the symbol white.
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(at: .zero, from: NSRect(origin: .zero, size: symbol.size), operation: .sourceOver, fraction: 1.0)
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        let drawSize = symbol.size
        let drawRect = NSRect(
            x: (size - drawSize.width) / 2.0,
            y: (size - drawSize.height) / 2.0,
            width: drawSize.width,
            height: drawSize.height
        )
        tinted.draw(in: drawRect, from: NSRect(origin: .zero, size: drawSize), operation: .sourceOver, fraction: 1.0)
    } else {
        FileHandle.standardError.write("warning: could not load list.bullet symbol at size \(pixelSize)\n".data(using: .utf8)!)
    }
}

/// Renders a single PNG at the given pixel size and returns its data.
func renderPNG(pixelSize: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return nil
    }
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        return nil
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawIcon(pixelSize: pixelSize)
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

// MARK: - Main

let arguments = CommandLine.arguments
let outputDir = arguments.count > 1 ? arguments[1] : "Plans.iconset"

let fileManager = FileManager.default
do {
    try fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true, attributes: nil)
} catch {
    FileHandle.standardError.write("error: could not create output directory \(outputDir): \(error)\n".data(using: .utf8)!)
    exit(1)
}

print("Generating iconset in \(outputDir)/")

for entry in entries {
    guard let data = renderPNG(pixelSize: entry.pixelSize) else {
        FileHandle.standardError.write("error: failed to render \(entry.fileName)\n".data(using: .utf8)!)
        exit(1)
    }
    let path = (outputDir as NSString).appendingPathComponent(entry.fileName)
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("  wrote \(entry.fileName) (\(entry.pixelSize)x\(entry.pixelSize)px)")
    } catch {
        FileHandle.standardError.write("error: could not write \(path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

print("Done. \(entries.count) PNGs written.")
