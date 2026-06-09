import XCTest
import AppKit
@testable import Plans

final class MakeIconTests: XCTestCase {
    /// Guards the "flat, no-gradient" requirement: the tile background must be a
    /// single uniform color. We render a small icon, decode it, and sample a
    /// cluster of pixels strictly inside the squircle tile (avoiding the
    /// centered glyph and the transparent margin). Those pixels must all be the
    /// SAME color — a diagonal gradient would vary across them — and must match
    /// the expected flat brand indigo.
    func testTileBackgroundIsFlatUniformColor() throws {
        let pixelSize = 128
        guard let data = IconRenderer.renderPNG(pixelSize: pixelSize) else {
            return XCTFail("renderPNG returned nil")
        }
        guard let rep = NSBitmapImageRep(data: data) else {
            return XCTFail("could not decode PNG into NSBitmapImageRep")
        }

        // The tile occupies the centered 80% of the canvas. The glyph sits in
        // the middle, so sample a cluster in the upper-left interior of the tile
        // (well inside the squircle, clear of the glyph and the margin).
        let tileFraction = 0.80
        let margin = (1.0 - tileFraction) / 2.0 // ~0.10 of canvas on each side
        // Sampling region: roughly 18%..32% of the canvas in both axes — inside
        // the tile (margin ends at 10%) and clear of the central glyph.
        let sampleFractions: [Double] = [0.18, 0.22, 0.26, 0.30]
        XCTAssertGreaterThan(margin, 0.0)

        var sampled: [NSColor] = []
        for fx in sampleFractions {
            for fy in sampleFractions {
                let px = Int(Double(pixelSize) * fx)
                let py = Int(Double(pixelSize) * fy)
                guard let color = rep.colorAt(x: px, y: py) else {
                    return XCTFail("no color at (\(px), \(py))")
                }
                sampled.append(color)
            }
        }

        XCTAssertFalse(sampled.isEmpty, "expected sampled background pixels")

        // All sampled background pixels must be identical within a tight
        // tolerance — proving a flat fill rather than a gradient.
        let tolerance = 0.012
        let first = sampled[0]
        for color in sampled {
            XCTAssertEqual(color.redComponent, first.redComponent, accuracy: tolerance, "red varies — not flat")
            XCTAssertEqual(color.greenComponent, first.greenComponent, accuracy: tolerance, "green varies — not flat")
            XCTAssertEqual(color.blueComponent, first.blueComponent, accuracy: tolerance, "blue varies — not flat")
            XCTAssertEqual(color.alphaComponent, 1.0, accuracy: tolerance, "tile interior must be opaque")
        }

        // And the flat color must be the expected brand indigo. We re-render
        // the brand color through the SAME bitmap pipeline so the comparison is
        // robust to the deviceRGB<->sRGB color-space round-trip that sampling a
        // decoded PNG introduces (sampling the raw brand NSColor directly would
        // disagree with the on-disk pixels by ~0.07 per channel on some display
        // profiles). Comparing pipeline-to-pipeline keeps the assertion about
        // brand identity without baking in a display-specific conversion shift.
        let expected = renderedBrandReference(pixelSize: pixelSize)
        let brandTolerance = 0.03
        XCTAssertEqual(first.redComponent, expected.redComponent, accuracy: brandTolerance, "red mismatch vs brand")
        XCTAssertEqual(first.greenComponent, expected.greenComponent, accuracy: brandTolerance, "green mismatch vs brand")
        XCTAssertEqual(first.blueComponent, expected.blueComponent, accuracy: brandTolerance, "blue mismatch vs brand")
    }

    /// Renders a solid swatch of `IconRenderer.brandColor` through the same
    /// NSBitmapImageRep PNG pipeline used by the icon, then samples it back —
    /// yielding the brand color as it actually lands in decoded pixels.
    private func renderedBrandReference(pixelSize: Int) -> NSColor {
        let rep = NSBitmapImageRep(
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
        )!
        rep.size = NSSize(width: pixelSize, height: pixelSize)
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        IconRenderer.brandColor.setFill()
        NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill()
        NSGraphicsContext.restoreGraphicsState()
        let data = rep.representation(using: .png, properties: [:])!
        let decoded = NSBitmapImageRep(data: data)!
        return decoded.colorAt(x: pixelSize / 2, y: pixelSize / 2)!
    }
}
