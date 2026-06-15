import XCTest
@testable import Plans

/// Tests for `MarkdownBlockRenderer.parse(_:)`, the pure block parser that turns
/// a section body into an ordered array of `MarkdownBlock` values (paragraphs,
/// bullet/numbered lists, fenced code, blockquotes, sub-headings). The parser
/// must never crash and must coalesce consecutive same-kind lines into a single
/// block, splitting on blank lines.
final class MarkdownBlockRendererTests: XCTestCase {
    func testEmptyInputYieldsEmptyArray() {
        XCTAssertEqual(MarkdownBlockRenderer.parse(""), [])
    }

    func testWhitespaceOnlyInputYieldsEmptyArray() {
        XCTAssertEqual(MarkdownBlockRenderer.parse("\n   \n\n"), [])
    }

    func testPlainParagraph() {
        XCTAssertEqual(
            MarkdownBlockRenderer.parse("Hello world."),
            [.paragraph("Hello world.")]
        )
    }

    func testMultilineParagraphPreservesInternalNewlines() {
        XCTAssertEqual(
            MarkdownBlockRenderer.parse("Line one\nLine two"),
            [.paragraph("Line one\nLine two")]
        )
    }

    func testTwoParagraphsSeparatedByBlankLine() {
        XCTAssertEqual(
            MarkdownBlockRenderer.parse("First.\n\nSecond."),
            [.paragraph("First."), .paragraph("Second.")]
        )
    }

    func testBulletListWithDash() {
        XCTAssertEqual(
            MarkdownBlockRenderer.parse("- one\n- two\n- three"),
            [.bulletList(["one", "two", "three"])]
        )
    }

    func testBulletListWithAsterisk() {
        XCTAssertEqual(
            MarkdownBlockRenderer.parse("* alpha\n* beta"),
            [.bulletList(["alpha", "beta"])]
        )
    }

    func testNumberedList() {
        XCTAssertEqual(
            MarkdownBlockRenderer.parse("1. first\n2. second\n3. third"),
            [.numberedList(["first", "second", "third"])]
        )
    }

    func testFencedCodeBlockPreservesInnerLinesVerbatim() {
        let body = "```\nlet x = 1\n    indented\n```"
        XCTAssertEqual(
            MarkdownBlockRenderer.parse(body),
            [.codeBlock(language: nil, code: "let x = 1\n    indented")]
        )
    }

    func testFencedCodeBlockWithLanguageInfoString() {
        let body = "```swift\nprint(\"hi\")\n```"
        XCTAssertEqual(
            MarkdownBlockRenderer.parse(body),
            [.codeBlock(language: "swift", code: "print(\"hi\")")]
        )
    }

    func testFencedCodeBlockInfoStringTrimmedToLanguage() {
        // A trailing info string after the language token is dropped; surrounding
        // whitespace is trimmed.
        let body = "```  swift  \nx\n```"
        XCTAssertEqual(
            MarkdownBlockRenderer.parse(body),
            [.codeBlock(language: "swift", code: "x")]
        )
    }

    func testBlockquoteLinesStrippedAndJoined() {
        XCTAssertEqual(
            MarkdownBlockRenderer.parse("> quoted one\n> quoted two"),
            [.blockquote("quoted one\nquoted two")]
        )
    }

    func testBlockquoteBareMarker() {
        XCTAssertEqual(
            MarkdownBlockRenderer.parse(">no space\n>"),
            [.blockquote("no space\n")]
        )
    }

    func testHeadingLevels() {
        XCTAssertEqual(
            MarkdownBlockRenderer.parse("## Section\n\n### Subsection"),
            [.heading(level: 2, text: "Section"),
             .heading(level: 3, text: "Subsection")]
        )
    }

    func testLeadingWhitespaceToleratedOnMarkers() {
        XCTAssertEqual(
            MarkdownBlockRenderer.parse("  - indented bullet\n   * another"),
            [.bulletList(["indented bullet", "another"])]
        )
        XCTAssertEqual(
            MarkdownBlockRenderer.parse("   > indented quote"),
            [.blockquote("indented quote")]
        )
    }

    func testMixedInterleavedContentOrdering() {
        let body = """
        Intro paragraph.

        - bullet a
        - bullet b

        ### A heading

        1. step one
        2. step two

        > a quote

        ```
        code here
        ```

        Closing paragraph.
        """
        XCTAssertEqual(
            MarkdownBlockRenderer.parse(body),
            [
                .paragraph("Intro paragraph."),
                .bulletList(["bullet a", "bullet b"]),
                .heading(level: 3, text: "A heading"),
                .numberedList(["step one", "step two"]),
                .blockquote("a quote"),
                .codeBlock(language: nil, code: "code here"),
                .paragraph("Closing paragraph."),
            ]
        )
    }

    func testConsecutiveListsNotSeparatedByBlankCoalesceWhenSameKind() {
        XCTAssertEqual(
            MarkdownBlockRenderer.parse("- a\n- b"),
            [.bulletList(["a", "b"])]
        )
    }

    func testBulletThenNumberedWithoutBlankSplitsIntoTwoBlocks() {
        XCTAssertEqual(
            MarkdownBlockRenderer.parse("- a\n1. b"),
            [.bulletList(["a"]), .numberedList(["b"])]
        )
    }

    func testUnclosedFencedCodeBlockFallsBackGracefully() {
        // Malformed: opening fence with no closing fence. Remaining lines are
        // emitted as a code block (never crash, never drop content).
        let body = "```\nunterminated\nmore code"
        XCTAssertEqual(
            MarkdownBlockRenderer.parse(body),
            [.codeBlock(language: nil, code: "unterminated\nmore code")]
        )
    }

    func testParagraphThenCodeBlockWithoutBlankLine() {
        let body = "before\n```\ncode\n```"
        XCTAssertEqual(
            MarkdownBlockRenderer.parse(body),
            [.paragraph("before"), .codeBlock(language: nil, code: "code")]
        )
    }
}
