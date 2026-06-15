import SwiftUI

/// The semantic kind of a highlighted code token. The view layer maps each kind
/// to a concrete `Color`; tests assert on these kinds (and the resulting ranges)
/// rather than on raw colors, so the lexer stays pure and easy to verify.
enum CodeTokenKind: Equatable {
    case plain
    case keyword
    case string
    case comment
    case number
    /// A capitalized identifier (heuristic for a type/class/struct name).
    case type
    /// An identifier immediately followed by `(` — a function/method call.
    case function
}

/// A contiguous run of source text classified as a single `CodeTokenKind`.
struct CodeToken: Equatable {
    let text: String
    let kind: CodeTokenKind
}

/// Pure, dependency-free syntax highlighter for fenced code blocks. It is a
/// deliberately small hand-rolled lexer (no external packages, per project
/// policy): it recognizes line/block comments, string & character literals,
/// numbers, and a per-language keyword set. Anything else is `.plain`.
///
/// It never throws and never crashes: unterminated strings/comments simply run
/// to end-of-input, and an unknown language falls back to a generic mode that
/// still colors strings, comments, and numbers.
enum CodeHighlighter {
    /// Tokenizes `code` under `language` into typed spans covering the input
    /// exactly once, in order (concatenating `token.text` reproduces `code`).
    static func tokenize(_ code: String, language: String?) -> [CodeToken] {
        let syntax = Syntax.forLanguage(language)
        let scalars = Array(code)
        var tokens: [CodeToken] = []
        var plain = ""

        func flushPlain() {
            if !plain.isEmpty {
                tokens.append(CodeToken(text: plain, kind: .plain))
                plain = ""
            }
        }

        var i = 0
        let n = scalars.count
        while i < n {
            let c = scalars[i]

            // Line comment.
            if let marker = syntax.lineComment, matches(scalars, i, marker) {
                flushPlain()
                var j = i
                while j < n && scalars[j] != "\n" { j += 1 }
                tokens.append(CodeToken(text: String(scalars[i..<j]), kind: .comment))
                i = j
                continue
            }

            // Block comment.
            if let (open, close) = syntax.blockComment, matches(scalars, i, open) {
                flushPlain()
                var j = i + open.count
                while j < n && !matches(scalars, j, close) { j += 1 }
                let end = min(n, j + (j < n ? close.count : 0))
                tokens.append(CodeToken(text: String(scalars[i..<end]), kind: .comment))
                i = end
                continue
            }

            // String / char literal.
            if syntax.stringDelimiters.contains(c) {
                flushPlain()
                let quote = c
                var j = i + 1
                while j < n {
                    if scalars[j] == "\\" { j += 2; continue } // skip escape
                    if scalars[j] == quote { j += 1; break }
                    j += 1
                }
                let end = min(j, n)
                tokens.append(CodeToken(text: String(scalars[i..<end]), kind: .string))
                i = end
                continue
            }

            // Number (a digit not part of an identifier).
            if c.isNumber && !isIdentifierChar(previous(scalars, i)) {
                flushPlain()
                var j = i
                while j < n && (scalars[j].isNumber || scalars[j] == "." || scalars[j] == "_"
                    || scalars[j] == "x" || scalars[j].isHexDigit && j > i) {
                    j += 1
                }
                tokens.append(CodeToken(text: String(scalars[i..<j]), kind: .number))
                i = j
                continue
            }

            // Identifier — may be a keyword, type, or function call.
            if isIdentifierStart(c) {
                var j = i
                while j < n && isIdentifierChar(scalars[j]) { j += 1 }
                let word = String(scalars[i..<j])
                if syntax.keywords.contains(word) {
                    flushPlain()
                    tokens.append(CodeToken(text: word, kind: .keyword))
                } else if syntax.highlightsTypes, let first = word.first, first.isUppercase, first.isLetter {
                    flushPlain()
                    tokens.append(CodeToken(text: word, kind: .type))
                } else if syntax.highlightsFunctions && nextNonSpaceIsOpenParen(scalars, from: j, n: n) {
                    flushPlain()
                    tokens.append(CodeToken(text: word, kind: .function))
                } else {
                    plain += word
                }
                i = j
                continue
            }

            plain.append(c)
            i += 1
        }
        flushPlain()
        return tokens
    }

    /// Builds a colored `AttributedString` for `code` using `theme` to map token
    /// kinds to colors. Convenience over `tokenize` for the view layer.
    static func highlight(_ code: String, language: String?, theme: CodeTheme = .default) -> AttributedString {
        var result = AttributedString()
        for token in tokenize(code, language: language) {
            var piece = AttributedString(token.text)
            piece.foregroundColor = theme.color(for: token.kind)
            result.append(piece)
        }
        return result
    }

    // MARK: - Helpers

    private static func matches(_ scalars: [Character], _ at: Int, _ needle: [Character]) -> Bool {
        guard at + needle.count <= scalars.count else { return false }
        for k in 0..<needle.count where scalars[at + k] != needle[k] { return false }
        return true
    }

    private static func previous(_ scalars: [Character], _ at: Int) -> Character? {
        at > 0 ? scalars[at - 1] : nil
    }

    /// Whether the first non-space character at or after `from` is `(` — used to
    /// detect a function/method call `name(...)` immediately after an identifier.
    private static func nextNonSpaceIsOpenParen(_ scalars: [Character], from: Int, n: Int) -> Bool {
        var k = from
        while k < n && (scalars[k] == " " || scalars[k] == "\t") { k += 1 }
        return k < n && scalars[k] == "("
    }

    private static func isIdentifierStart(_ c: Character) -> Bool {
        c == "_" || c == "$" || c.isLetter
    }

    private static func isIdentifierChar(_ c: Character?) -> Bool {
        guard let c else { return false }
        return c == "_" || c == "$" || c.isLetter || c.isNumber
    }
}

/// Maps `CodeTokenKind` to concrete colors. Defaults are tuned to read well in
/// both light and dark mode against a subtly contrasting code surface.
struct CodeTheme {
    var plain: Color
    var keyword: Color
    var string: Color
    var comment: Color
    var number: Color
    var type: Color
    var function: Color

    func color(for kind: CodeTokenKind) -> Color {
        switch kind {
        case .plain: return plain
        case .keyword: return keyword
        case .string: return string
        case .comment: return comment
        case .number: return number
        case .type: return type
        case .function: return function
        }
    }

    /// A varied, syntax-themed palette. Distinct hues per token kind give code a
    /// rich, editor-like look while staying legible in both light and dark mode.
    static let `default` = CodeTheme(
        plain: .primary,
        keyword: .pink,
        string: Color(red: 0.36, green: 0.62, blue: 0.36),
        comment: .secondary,
        number: .orange,
        type: .teal,
        function: Color(red: 0.40, green: 0.56, blue: 0.92)
    )
}

/// Per-language lexer configuration: comment markers, string delimiters, and the
/// keyword set. `forLanguage` normalizes common aliases and falls back to a
/// generic profile (strings/comments/numbers only, no keywords) for unknowns.
private struct Syntax {
    var lineComment: [Character]?
    var blockComment: (open: [Character], close: [Character])?
    var stringDelimiters: Set<Character>
    var keywords: Set<String>
    /// Color capitalized identifiers as types. Off for languages where that
    /// heuristic misfires (shell, JSON).
    var highlightsTypes: Bool = false
    /// Color `name(` identifiers as function calls.
    var highlightsFunctions: Bool = false

    static func forLanguage(_ language: String?) -> Syntax {
        switch language?.lowercased() {
        case "swift":
            return Syntax(
                lineComment: Array("//"),
                blockComment: (Array("/*"), Array("*/")),
                stringDelimiters: ["\""],
                keywords: [
                    "let", "var", "func", "return", "if", "else", "guard", "switch",
                    "case", "default", "for", "while", "in", "struct", "class", "enum",
                    "protocol", "extension", "import", "private", "public", "internal",
                    "static", "self", "nil", "true", "false", "throw", "throws", "try",
                    "catch", "do", "where", "init", "deinit", "some", "as", "is",
                ],
                highlightsTypes: true,
                highlightsFunctions: true
            )
        case "js", "javascript", "ts", "typescript", "jsx", "tsx":
            return Syntax(
                lineComment: Array("//"),
                blockComment: (Array("/*"), Array("*/")),
                stringDelimiters: ["\"", "'", "`"],
                keywords: [
                    "const", "let", "var", "function", "return", "if", "else", "switch",
                    "case", "default", "for", "while", "of", "in", "class", "extends",
                    "import", "export", "from", "new", "this", "null", "undefined",
                    "true", "false", "async", "await", "try", "catch", "throw", "typeof",
                    "interface", "type", "enum", "public", "private", "readonly",
                ],
                highlightsTypes: true,
                highlightsFunctions: true
            )
        case "json":
            return Syntax(
                lineComment: nil,
                blockComment: nil,
                stringDelimiters: ["\""],
                keywords: ["true", "false", "null"]
            )
        case "sh", "bash", "shell", "zsh":
            return Syntax(
                lineComment: Array("#"),
                blockComment: nil,
                stringDelimiters: ["\"", "'"],
                keywords: [
                    "if", "then", "else", "elif", "fi", "for", "while", "do", "done",
                    "case", "esac", "function", "in", "return", "export", "local",
                ]
            )
        default:
            // Generic fallback: strings/comments/numbers only, no keywords.
            return Syntax(
                lineComment: Array("#"),
                blockComment: nil,
                stringDelimiters: ["\"", "'"],
                keywords: []
            )
        }
    }
}
