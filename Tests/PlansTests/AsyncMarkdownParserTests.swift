import XCTest
import SwiftUI
@testable import Plans

/// Tests for `AsyncMarkdownParser`, the pure helper that lets the detail view
/// parse a section body OFF the main thread and decide whether a completed
/// parse is still the newest one before applying it. The parse itself must
/// produce exactly the same `[MarkdownBlock]` as `MarkdownBlockRenderer.parse`
/// (it delegates), and the generation guard is modelled as a pure function so
/// the newest-wins / stale-drop behaviour can be tested without any SwiftUI.
final class AsyncMarkdownParserTests: XCTestCase {

    // MARK: - parse delegation

    /// A representative body containing a paragraph, a bullet list, and a
    /// fenced code block must parse identically to `MarkdownBlockRenderer`.
    func testParseMatchesMarkdownBlockRenderer() {
        let body = """
        This is an intro paragraph with **bold** text.

        - first bullet
        - second bullet

        ```swift
        let x = 1
        print(x)
        ```
        """

        let expected = MarkdownBlockRenderer.parse(body)
        let actual = AsyncMarkdownParser.parse(body)

        XCTAssertEqual(actual, expected)
        // Sanity: the fixture really does exercise all three block kinds.
        XCTAssertTrue(expected.contains(where: {
            if case .paragraph = $0 { return true } else { return false }
        }))
        XCTAssertTrue(expected.contains(where: {
            if case .bulletList = $0 { return true } else { return false }
        }))
        XCTAssertTrue(expected.contains(where: {
            if case .codeBlock = $0 { return true } else { return false }
        }))
    }

    // MARK: - generation / newest-wins guard

    /// A completed parse whose generation matches the current generation is
    /// applied.
    func testShouldApplyWhenGenerationMatchesCurrent() {
        XCTAssertTrue(AsyncMarkdownParser.shouldApply(completed: 3, current: 3))
    }

    /// A stale result (an older generation finishing AFTER a newer parse has
    /// already been kicked off) is dropped.
    func testShouldNotApplyStaleResult() {
        // Generation 1 finishes late; current has already advanced to 2.
        XCTAssertFalse(AsyncMarkdownParser.shouldApply(completed: 1, current: 2))
    }

    /// A result from a generation newer than the current one should never
    /// happen with a monotonic counter, but is likewise not applied — only an
    /// exact match wins.
    func testShouldNotApplyFutureResult() {
        XCTAssertFalse(AsyncMarkdownParser.shouldApply(completed: 5, current: 4))
    }

    // MARK: - prepare (#113: off-main render model)

    /// The single prepared inline text of a one-paragraph body.
    private func preparedParagraph(_ body: String, style: MarkdownStyle) throws -> AttributedString {
        let blocks = AsyncMarkdownParser.prepare(body, style: style)
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
            AsyncMarkdownParser.prepareInline($0, bodySize: MarkdownStyle.plan.bodySize)
        }
        XCTAssertEqual(AsyncMarkdownParser.prepare(body, style: .plan), [
            .heading(level: 1, text: "Title"),
            .bulletList([inline("one"), inline("two")]),
            .numberedList([inline("first")]),
            .blockquote(inline("quoted")),
            .codeBlock(CodeHighlighter.highlight("let x = 1", language: "swift")),
        ])
    }

    /// Preparation runs on a detached task in production; its output must not
    /// depend on which thread built it.
    func testPrepareOffMainMatchesInlineResult() async {
        let body = "para with `code`\n\n- item **bold**\n\n```js\nconst a = 1\n```"
        let expected = AsyncMarkdownParser.prepare(body, style: .plan)
        let detached = await _Concurrency.Task.detached(priority: .userInitiated) {
            AsyncMarkdownParser.prepare(body, style: .plan)
        }.value
        XCTAssertEqual(detached, expected)
    }

    // MARK: - placeholder

    /// A body within the cap is shown whole.
    func testPlaceholderLeavesShortBodyUnchanged() {
        XCTAssertEqual(AsyncMarkdownParser.placeholder(for: "short body"), "short body")
    }

    /// A long body is cut to the cap, so the first frame's text layout does not
    /// grow with the size of the plan.
    func testPlaceholderCapsLongBody() {
        let body = String(repeating: "abcde ", count: 5_000)
        let placeholder = AsyncMarkdownParser.placeholder(for: body)
        XCTAssertEqual(placeholder.count, AsyncMarkdownParser.placeholderCharacterLimit)
        XCTAssertTrue(body.hasPrefix(placeholder))
    }

    // MARK: - PreparedMarkdownCache

    private func blocks(_ text: String) -> [PreparedMarkdownBlock] {
        [.heading(level: 1, text: text)]
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
