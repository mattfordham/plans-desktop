import XCTest
@testable import Plans

/// Unit tests for the pure `CodeHighlighter` lexer. Assertions are on token
/// kinds and their text (which together imply the colored ranges), not on raw
/// `Color` values — the kind→color mapping lives in `CodeTheme` and is trivial.
final class CodeHighlighterTests: XCTestCase {

    /// Concatenating every token's text must reproduce the input exactly — the
    /// lexer covers the whole string once, dropping nothing.
    private func assertLosslessCoverage(_ code: String, language: String?, file: StaticString = #filePath, line: UInt = #line) {
        let tokens = CodeHighlighter.tokenize(code, language: language)
        XCTAssertEqual(tokens.map(\.text).joined(), code, file: file, line: line)
    }

    private func kinds(_ code: String, _ language: String?) -> [CodeTokenKind] {
        CodeHighlighter.tokenize(code, language: language).map(\.kind)
    }

    private func token(_ code: String, _ language: String?, kind: CodeTokenKind) -> [String] {
        CodeHighlighter.tokenize(code, language: language).filter { $0.kind == kind }.map(\.text)
    }

    func testSwiftKeywordsHighlighted() {
        let code = "let x = 1"
        XCTAssertEqual(token(code, "swift", kind: .keyword), ["let"])
        assertLosslessCoverage(code, language: "swift")
    }

    func testSwiftStringLiteralHighlighted() {
        let code = "print(\"hello\")"
        XCTAssertEqual(token(code, "swift", kind: .string), ["\"hello\""])
        assertLosslessCoverage(code, language: "swift")
    }

    func testSwiftLineCommentHighlighted() {
        let code = "let x = 1 // a note"
        XCTAssertEqual(token(code, "swift", kind: .comment), ["// a note"])
        assertLosslessCoverage(code, language: "swift")
    }

    func testSwiftBlockCommentHighlighted() {
        let code = "a /* b */ c"
        XCTAssertEqual(token(code, "swift", kind: .comment), ["/* b */"])
        assertLosslessCoverage(code, language: "swift")
    }

    func testNumberHighlighted() {
        let code = "let x = 42"
        XCTAssertEqual(token(code, "swift", kind: .number), ["42"])
        assertLosslessCoverage(code, language: "swift")
    }

    func testDigitInsideIdentifierIsNotANumber() {
        // `x1` is an identifier, not `x` + number `1`.
        let code = "var x1 = y2"
        XCTAssertTrue(token(code, "swift", kind: .number).isEmpty)
        assertLosslessCoverage(code, language: "swift")
    }

    func testStringEscapeDoesNotEndStringEarly() {
        let code = "\"a\\\"b\""  // "a\"b"
        XCTAssertEqual(token(code, "swift", kind: .string), ["\"a\\\"b\""])
        assertLosslessCoverage(code, language: "swift")
    }

    func testCapitalizedIdentifierClassifiedAsTypeInSwift() {
        let code = "let v: Color = .red"
        XCTAssertEqual(token(code, "swift", kind: .type), ["Color"])
        assertLosslessCoverage(code, language: "swift")
    }

    func testFunctionCallClassifiedInSwift() {
        let code = "foo(x)"
        XCTAssertEqual(token(code, "swift", kind: .function), ["foo"])
        assertLosslessCoverage(code, language: "swift")
    }

    func testFunctionCallToleratesSpaceBeforeParen() {
        let code = "bar ()"
        XCTAssertEqual(token(code, "swift", kind: .function), ["bar"])
        assertLosslessCoverage(code, language: "swift")
    }

    func testTypeAndFunctionNotClassifiedInGenericFallback() {
        // Unknown language: capitalized words and call sites stay plain.
        let code = "Foo(x)"
        XCTAssertTrue(token(code, "plaintext", kind: .type).isEmpty)
        XCTAssertTrue(token(code, "plaintext", kind: .function).isEmpty)
        assertLosslessCoverage(code, language: "plaintext")
    }

    func testJavaScriptKeywordsAndTemplateString() {
        let code = "const s = `hi`"
        XCTAssertEqual(token(code, "js", kind: .keyword), ["const"])
        XCTAssertEqual(token(code, "js", kind: .string), ["`hi`"])
        assertLosslessCoverage(code, language: "javascript")
    }

    func testShellLineCommentWithHash() {
        let code = "echo hi # comment"
        XCTAssertEqual(token(code, "bash", kind: .comment), ["# comment"])
        assertLosslessCoverage(code, language: "bash")
    }

    func testJSONKeywordsAndStrings() {
        let code = "{\"k\": true}"
        XCTAssertEqual(token(code, "json", kind: .string), ["\"k\""])
        XCTAssertEqual(token(code, "json", kind: .keyword), ["true"])
        assertLosslessCoverage(code, language: "json")
    }

    func testUnknownLanguageFallsBackToGeneric() {
        // No keywords, but strings/comments/numbers still classified.
        let code = "foo \"bar\" 7 # note"
        XCTAssertTrue(token(code, "brainfuck", kind: .keyword).isEmpty)
        XCTAssertEqual(token(code, "brainfuck", kind: .string), ["\"bar\""])
        XCTAssertEqual(token(code, "brainfuck", kind: .number), ["7"])
        XCTAssertEqual(token(code, "brainfuck", kind: .comment), ["# note"])
        assertLosslessCoverage(code, language: "brainfuck")
    }

    func testNilLanguageUsesGenericFallback() {
        let code = "\"x\""
        XCTAssertEqual(token(code, nil, kind: .string), ["\"x\""])
        assertLosslessCoverage(code, language: nil)
    }

    func testUnterminatedStringRunsToEndWithoutCrashing() {
        let code = "\"never closed"
        XCTAssertEqual(token(code, "swift", kind: .string), ["\"never closed"])
        assertLosslessCoverage(code, language: "swift")
    }

    func testUnterminatedBlockCommentRunsToEndWithoutCrashing() {
        let code = "/* open"
        XCTAssertEqual(token(code, "swift", kind: .comment), ["/* open"])
        assertLosslessCoverage(code, language: "swift")
    }

    func testEmptyInputProducesNoTokens() {
        XCTAssertTrue(CodeHighlighter.tokenize("", language: "swift").isEmpty)
    }

    func testHighlightProducesAttributedStringEqualToSource() {
        let code = "let x = \"y\""
        let attributed = CodeHighlighter.highlight(code, language: "swift")
        XCTAssertEqual(String(attributed.characters), code)
    }
}
