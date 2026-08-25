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

    // MARK: - Plural extraction (#069)

    /// A single drop/paste carrying MULTIPLE image file URLs must yield one PNG
    /// per file, not just the first. Fails RED until `pngDatas(from:)` exists.
    func testExtractsMultiplePNGsFromMultipleFileURLs() throws {
        pasteboard.clearContents()
        let url1 = tempDir.appendingPathComponent("\(UUID().uuidString).png")
        let url2 = tempDir.appendingPathComponent("\(UUID().uuidString).png")
        try pngBytes().write(to: url1)
        try pngBytes().write(to: url2)
        pasteboard.writeObjects([url1 as NSURL, url2 as NSURL])

        let results = PlanNSTextView.pngDatas(from: pasteboard)
        XCTAssertEqual(results.count, 2, "expected one PNG per file URL")
        for (index, data) in results.enumerated() {
            assertValidPNG(data, "(multi file URL #\(index))")
        }
    }

    /// A single paste carrying MULTIPLE `NSImage` objects must yield one PNG per
    /// image.
    func testExtractsMultiplePNGsFromMultipleNSImages() throws {
        pasteboard.clearContents()
        pasteboard.writeObjects([makeImage(), makeImage()])

        let results = PlanNSTextView.pngDatas(from: pasteboard)
        XCTAssertEqual(results.count, 2, "expected one PNG per NSImage object")
        for (index, data) in results.enumerated() {
            assertValidPNG(data, "(multi NSImage #\(index))")
        }
    }

    /// The plural extractor returns an EMPTY ARRAY (not nil, which it can't) for a
    /// pasteboard with no image at all.
    func testPluralExtractorReturnsEmptyForNoImage() throws {
        pasteboard.clearContents()
        pasteboard.setString("just some text", forType: .string)
        XCTAssertEqual(PlanNSTextView.pngDatas(from: pasteboard), [])

        pasteboard.clearContents()
        XCTAssertEqual(PlanNSTextView.pngDatas(from: pasteboard), [])
    }

    // MARK: - Paste entry point (#062 follow-up)

    /// Builds a `PlanNSTextView` configured exactly as `PlanTextEditor.makeNSView`
    /// does — critically `isRichText = false`, which is what restricts the view's
    /// advertised readable types and gates ⌘V.
    private func makeTextView() -> PlanNSTextView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = PlanNSTextView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 200),
            textContainer: textContainer
        )
        textView.isRichText = false
        return textView
    }

    /// A menu item standing in for Edit ▸ Paste, used to ask the text view whether
    /// it would ENABLE ⌘V for the current pasteboard.
    private func pasteMenuItem() -> NSMenuItem {
        NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    }

    /// The real root cause of "drag works, paste doesn't": with `isRichText =
    /// false` the text view advertises ONLY text-ish readable types, so AppKit
    /// disables the Paste command for an image-only clipboard and ⌘V is never
    /// dispatched at all — `paste(_:)` is not even called. Overriding
    /// `readablePasteboardTypes` to advertise the image types is what re-enables
    /// the command and lets the image branch run.
    func testAdvertisesImageTypesAsReadable() throws {
        let textView = makeTextView()
        let readable = Set(textView.readablePasteboardTypes)

        XCTAssertTrue(readable.contains(.png), "expected .png to be advertised as readable")
        XCTAssertTrue(readable.contains(.tiff), "expected .tiff to be advertised as readable")
        XCTAssertTrue(readable.contains(.fileURL), "expected .fileURL to be advertised as readable")
    }

    /// Advertising the image types must actually flip the Paste command from
    /// disabled to enabled for an image-only pasteboard. This is the behaviour the
    /// user observed as "Cmd+V does nothing".
    func testPasteCommandIsEnabledForImageOnlyPasteboard() throws {
        let textView = makeTextView()
        // `validateUserInterfaceItem` for paste: consults the GENERAL pasteboard,
        // so drive it through the same seam the view uses, without mutating the
        // user's real clipboard.
        pasteboard.clearContents()
        pasteboard.setData(try pngBytes(), forType: .png)

        XCTAssertTrue(
            textView.canPaste(from: pasteboard),
            "expected an image-only pasteboard to enable the Paste command"
        )
    }

    /// The paste entry point must hand PNG bytes to `onImagePasted` and must NOT
    /// let the image land in the text (no attachment glyph, no `super` insert).
    func testReadSelectionCapturesImageAndLeavesTextUntouched() throws {
        let textView = makeTextView()
        var captured: Data?
        textView.onImagePasted = { captured = $0 }

        pasteboard.clearContents()
        pasteboard.setData(try pngBytes(), forType: .png)

        XCTAssertTrue(textView.readSelection(from: pasteboard), "expected the image to be handled")
        assertValidPNG(captured, "(readSelection entry point)")
        XCTAssertEqual(textView.string, "", "image paste must not insert anything into the text")
    }

    /// A PDF-only pasteboard (screenshots, Preview, browsers) reaches the callback
    /// through the entry point too, not just through the extraction helper.
    func testReadSelectionCapturesNSImageOnlyPasteboard() throws {
        let textView = makeTextView()
        var captured: Data?
        textView.onImagePasted = { captured = $0 }

        pasteboard.clearContents()
        pasteboard.setData(pdfData(), forType: .pdf)

        XCTAssertTrue(textView.readSelection(from: pasteboard))
        assertValidPNG(captured, "(PDF-only pasteboard via entry point)")
        XCTAssertEqual(textView.string, "")
    }

    /// Regression guard: plain-text paste must keep working normally and must NOT
    /// fire the image callback. Both `NewPlanModal` and `ReElaborateModal` depend
    /// on this.
    func testPlainTextPasteStillInsertsTextAndDoesNotFireCallback() throws {
        let textView = makeTextView()
        var fired = false
        textView.onImagePasted = { _ in fired = true }

        pasteboard.clearContents()
        pasteboard.setString("hello world", forType: .string)

        XCTAssertTrue(textView.readSelection(from: pasteboard))
        XCTAssertFalse(fired, "plain-text paste must not fire onImagePasted")
        XCTAssertEqual(textView.string, "hello world")
    }

    /// `pasteAsPlainText` is the other command AppKit can route a paste through
    /// (Edit ▸ Paste and Match Style, and some plain-text configurations). It must
    /// run the same image branch rather than silently dropping the image.
    func testPasteAsPlainTextRoutesImagesThroughTheSameBranch() throws {
        let textView = makeTextView()
        var captured: Data?
        textView.onImagePasted = { captured = $0 }

        pasteboard.clearContents()
        pasteboard.setData(try pngBytes(), forType: .png)

        XCTAssertTrue(
            textView.captureImage(from: pasteboard),
            "expected the shared image branch to handle an image-only pasteboard"
        )
        assertValidPNG(captured, "(shared capture helper)")
        XCTAssertEqual(textView.string, "")
    }
}
