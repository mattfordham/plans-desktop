import XCTest
import SwiftUI
@testable import Plans

/// Tests for `MarkdownPreparer`, which builds a section body's finished render
/// model, and `PreparedMarkdownCache`, which keeps it.
final class MarkdownPreparerTests: XCTestCase {

    // MARK: - prepare

    /// The single prepared inline text of a one-paragraph body.
    private func preparedParagraph(_ body: String, style: MarkdownStyle) throws -> AttributedString {
        let blocks = MarkdownPreparer.prepare(body, style: style)
        guard blocks.count == 1, case let .paragraph(text) = blocks[0] else {
            XCTFail("expected exactly one paragraph, got \(blocks)")
            throw XCTSkip("unexpected block shape")
        }
        return text
    }

    /// Prose runs take the style's body font; inline-code runs keep their
    /// monospaced, accent-tinted chip styling.
    func testPrepareStylesProseAndInlineCode() throws {
        let text = try preparedParagraph("use `foo` now", style: .plan)

        XCTAssertEqual(String(text.characters), "use foo now")
        let runs = Array(text.runs)
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0].swiftUI.font, Font.system(size: MarkdownStyle.plan.bodySize))
        XCTAssertNil(runs[0].swiftUI.foregroundColor)
        XCTAssertEqual(runs[1].swiftUI.font,
                       Font.system(size: MarkdownStyle.plan.bodySize, design: .monospaced))
        XCTAssertEqual(runs[1].swiftUI.foregroundColor, Color.accentColor)
        XCTAssertEqual(runs[2].swiftUI.font, Font.system(size: MarkdownStyle.plan.bodySize))
    }

    /// Inline markdown is interpreted, not shown literally.
    func testPrepareInterpretsInlineMarkdown() throws {
        let text = try preparedParagraph("some **bold** text", style: .plan)
        XCTAssertEqual(String(text.characters), "some bold text")
    }

    /// The font scale comes from the style, so `.compact` replies stay smaller.
    func testPrepareUsesCompactBodySize() throws {
        let text = try preparedParagraph("use `foo`", style: .compact)
        let runs = Array(text.runs)
        XCTAssertEqual(runs[0].swiftUI.font, Font.system(size: MarkdownStyle.compact.bodySize))
        XCTAssertEqual(runs[1].swiftUI.font,
                       Font.system(size: MarkdownStyle.compact.bodySize, design: .monospaced))
    }

    /// Every block kind maps across in document order, with list items prepared
    /// individually and headings left as plain text for the view to style.
    func testPrepareMapsEveryBlockKindInOrder() {
        let body = """
        # Title

        - one
        - two

        1. first

        > quoted

        ```swift
        let x = 1
        ```
        """

        let inline: (String) -> AttributedString = {
            MarkdownPreparer.prepareInline($0, bodySize: MarkdownStyle.plan.bodySize)
        }
        XCTAssertEqual(MarkdownPreparer.prepare(body, style: .plan), [
            .heading(level: 1, text: "Title"),
            .bulletList([inline("one"), inline("two")]),
            .numberedList([inline("first")]),
            .blockquote(inline("quoted")),
            .codeBlock(CodeHighlighter.highlight("let x = 1", language: "swift")),
        ])
    }

    // MARK: - PreparedMarkdownCache

    private func blocks(_ text: String) -> [PreparedMarkdownBlock] {
        [.heading(level: 1, text: text)]
    }

    /// The first request for a body returns its finished blocks straight away,
    /// so a section never has an intermediate state to shift out of.
    @MainActor
    func testPreparedBlocksReturnsFinishedBlocksOnFirstRequest() {
        let cache = PreparedMarkdownCache(capacity: 4)
        let body = "para with `code`\n\n- item"

        XCTAssertEqual(cache.preparedBlocks(forBody: body, style: .plan),
                       MarkdownPreparer.prepare(body, style: .plan))
        XCTAssertEqual(cache.count, 1)
    }

    /// A later request is served from the cache rather than prepared again.
    @MainActor
    func testPreparedBlocksReusesCachedEntry() {
        let cache = PreparedMarkdownCache(capacity: 4)
        cache.store(blocks("cached"), forBody: "a", style: .plan)

        XCTAssertEqual(cache.preparedBlocks(forBody: "a", style: .plan), blocks("cached"))
    }

    @MainActor
    func testCacheMissReturnsNil() {
        let cache = PreparedMarkdownCache(capacity: 4)
        XCTAssertNil(cache.blocks(forBody: "a", style: .plan))
    }

    @MainActor
    func testCacheReturnsStoredBlocks() {
        let cache = PreparedMarkdownCache(capacity: 4)
        cache.store(blocks("a"), forBody: "a", style: .plan)
        XCTAssertEqual(cache.blocks(forBody: "a", style: .plan), blocks("a"))
    }

    /// The same body at a different scale is a different render.
    @MainActor
    func testCacheIsKeyedByStyle() {
        let cache = PreparedMarkdownCache(capacity: 4)
        cache.store(blocks("a"), forBody: "a", style: .plan)
        XCTAssertNil(cache.blocks(forBody: "a", style: .compact))
    }

    /// Past capacity the least-recently-used entry goes, and a lookup counts as
    /// a use.
    @MainActor
    func testCacheEvictsLeastRecentlyUsed() {
        let cache = PreparedMarkdownCache(capacity: 2)
        cache.store(blocks("a"), forBody: "a", style: .plan)
        cache.store(blocks("b"), forBody: "b", style: .plan)
        _ = cache.blocks(forBody: "a", style: .plan)

        cache.store(blocks("c"), forBody: "c", style: .plan)

        XCTAssertNotNil(cache.blocks(forBody: "a", style: .plan))
        XCTAssertNil(cache.blocks(forBody: "b", style: .plan))
        XCTAssertNotNil(cache.blocks(forBody: "c", style: .plan))
        XCTAssertEqual(cache.count, 2)
    }

    /// Re-storing a key replaces it rather than taking a second slot.
    @MainActor
    func testCacheRestoreDoesNotGrow() {
        let cache = PreparedMarkdownCache(capacity: 2)
        cache.store(blocks("a"), forBody: "a", style: .plan)
        cache.store(blocks("a2"), forBody: "a", style: .plan)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.blocks(forBody: "a", style: .plan), blocks("a2"))
    }
}
