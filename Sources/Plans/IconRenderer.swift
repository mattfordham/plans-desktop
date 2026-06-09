import AppKit
import CoreGraphics
import Foundation

/// Canonical drawing logic for the Plans app icon.
///
/// This is the single source of truth shared by the standalone
/// `Tools/make-icon.swift` generator and the test suite. The icon is a
/// native-macOS-style squircle tile (inset within a transparent margin) filled
/// with a single FLAT brand color and overlaid with a centered white
/// `list.bullet` SF Symbol glyph. There is intentionally NO gradient — the look
/// is flat and modern.
enum IconRenderer {
    /// The flat brand fill — modern indigo (≈ #5B6BF0).
    static let brandColor = NSColor(srgbRed: 0.357, green: 0.420, blue: 0.941, alpha: 1.0)

    /// Draws the full icon into the current graphics context for a given pixel size.
    static func drawIcon(pixelSize: Int) {
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
    static func renderPNG(pixelSize: Int) -> Data? {
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
}
