#!/usr/bin/env swift

// make-icon.swift
//
// Standalone generator for the Plans app icon. Draws a native-macOS-style
// squircle tile filled with a single FLAT brand indigo (no gradient) and a
// centered WHITE `list.bullet` SF Symbol glyph on top, matching the menu-bar
// icon (see Sources/Plans/MenuBarLabel.swift).
//
// It renders one PNG per required macOS iconset size, using Apple's mandated
// filenames, into an output directory (default `Plans.iconset` in the cwd).
//
// NOTE: The canonical drawing logic lives in Sources/Plans/IconRenderer.swift,
// which the test suite exercises directly. This script is a standalone Swift
// file run via `swift Tools/make-icon.swift` and CANNOT `import Plans` (it is
// not linked against the library target), so the `drawIcon`/`renderPNG`
// functions below intentionally MIRROR IconRenderer and MUST be kept in sync
// with it. The flat-fill property is guarded by MakeIconTests against the
// canonical IconRenderer.
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

/// The flat brand fill — modern indigo (≈ #5B6BF0). Mirrors
/// `IconRenderer.brandColor`.
let brandColor = NSColor(srgbRed: 0.357, green: 0.420, blue: 0.941, alpha: 1.0)

/// Draws the full icon into the current graphics context for a given pixel size.
func drawIcon(pixelSize: Int) {
    let size = CGFloat(pixelSize)

    // Native macOS app icons inset the squircle tile within the full bounding
    // box, leaving a transparent margin (the tile is ~80% of the canvas). This
    // keeps the icon from looking oversized next to system icons in the Dock.
    let tileFraction: CGFloat = 0.80
    let tileSide = size * tileFraction
    let tileOrigin = (size - tileSide) / 2.0
    let tileRect = NSRect(x: tileOrigin, y: tileOrigin, width: tileSide, height: tileSide)

    // macOS Big Sur+ icons use a superellipse-ish corner radius of roughly
    // 0.2237 of the tile side. A rounded rect approximates this closely enough
    // for our purposes.
    let cornerRadius = tileSide * 0.2237
    let roundedPath = NSBezierPath(roundedRect: tileRect, xRadius: cornerRadius, yRadius: cornerRadius)

    NSGraphicsContext.current?.saveGraphicsState()
    roundedPath.addClip()

    // Flat single-color fill — no gradient.
    brandColor.setFill()
    tileRect.fill()

    NSGraphicsContext.current?.restoreGraphicsState()

    // Centered white `list.bullet` glyph. Sized relative to the tile (not the
    // full canvas) with extra padding so it doesn't crowd the tile edges.
    let glyphFraction: CGFloat = 0.46
    let glyphSide = tileSide * glyphFraction

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
