import XCTest
import AppKit
@testable import Plans

/// Exercises `PlanNSTextView.pngData(from:)` — the pasteboard→PNG extraction that
/// backs image paste/drop in the new-plan prompt (#062). Uses an off-general
/// pasteboard so the user's real clipboard is never touched.
@MainActor
final class PlanTextEditorImageTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("PlansTest-\(UUID().uuidString)"))
        pasteboard.clearContents()

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlansTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A tiny valid 2x2 image drawn in-code.
    private func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        return image
    }

    /// Raw TIFF bytes for a tiny image.
    private func tiffData() throws -> Data {
        let tiff = try XCTUnwrap(makeImage().tiffRepresentation)
        return tiff
    }

    /// Raw PNG bytes for a tiny image.
    private func pngBytes() throws -> Data {
        let tiff = try tiffData()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// PDF bytes for a tiny image. A PDF-only pasteboard is readable as an
    /// `NSImage` object but exposes NO raw `.png`/`.tiff` via `data(forType:)`,
    /// mirroring real sources (Preview, browsers, screenshots) whose paste was
    /// silently dropped before the NSImage branch existed.
    private func pdfData() -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 2, height: 2)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        ctx.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// Asserts `data` decodes back to a valid bitmap (i.e. is real PNG).
    private func assertValidPNG(_ data: Data?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let bytes = data else {
            XCTFail("expected non-nil PNG Data \(message)", file: file, line: line)
            return
        }
        XCTAssertNotNil(NSBitmapImageRep(data: bytes), "returned bytes were not decodable as an image \(message)", file: file, line: line)
    }

    // MARK: - Cases

    func testExtractsFromRawPNGData() throws {
        pasteboard.clearContents()
        pasteboard.setData(try pngBytes(), forType: .png)

        let result = PlanNSTextView.pngData(from: pasteboard)
        assertValidPNG(result, "(raw .png)")
    }

    func testExtractsFromTIFFData() throws {
        pasteboard.clearContents()
        pasteboard.setData(try tiffData(), forType: .tiff)

        let result = PlanNSTextView.pngData(from: pasteboard)
        assertValidPNG(result, "(raw .tiff)")
    }

    /// The currently-failing case: an image readable only as an `NSImage`
    /// OBJECT, with NO raw png/tiff available via `data(forType:)`. Populated as
    /// a PDF-only pasteboard, which `data(forType: .png/.tiff)` cannot satisfy
    /// but `readObjects(forClasses: [NSImage.self])` can. Fails RED until the
    /// NSImage branch is added in Step 3.
    func testExtractsFromNSImageObject() throws {
        pasteboard.clearContents()
        pasteboard.setData(pdfData(), forType: .pdf)

        // Precondition: the pre-existing raw paths genuinely can't see it.
        XCTAssertNil(pasteboard.data(forType: .png), "test setup: expected no raw .png")
        XCTAssertNil(pasteboard.data(forType: .tiff), "test setup: expected no raw .tiff")

        let result = PlanNSTextView.pngData(from: pasteboard)
        assertValidPNG(result, "(NSImage object, PDF-only pasteboard)")
    }

    func testExtractsFromFileURL() throws {
        pasteboard.clearContents()
        let fileURL = tempDir.appendingPathComponent("\(UUID().uuidString).png")
        try pngBytes().write(to: fileURL)
        pasteboard.writeObjects([fileURL as NSURL])

        let result = PlanNSTextView.pngData(from: pasteboard)
        assertValidPNG(result, "(file URL)")
    }

    func testReturnsNilForPlainStringOnly() throws {
        pasteboard.clearContents()
        pasteboard.setString("just some text", forType: .string)

        XCTAssertNil(PlanNSTextView.pngData(from: pasteboard))
    }

    func testReturnsNilForEmptyPasteboard() throws {
        pasteboard.clearContents()

        XCTAssertNil(PlanNSTextView.pngData(from: pasteboard))
    }
}
