import XCTest
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
}
