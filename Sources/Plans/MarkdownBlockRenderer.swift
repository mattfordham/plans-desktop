import Foundation

/// A single block-level element parsed out of a plan section body. Block
/// structure (lists, fenced code, blockquotes, sub-headings) is recovered here
/// so the detail view can render it with proper layout instead of the flat,
/// inline-only paragraph rendering. Inline markdown WITHIN a block's text
/// (e.g. `**bold**` inside a paragraph or list item) is still handled at render
/// time via `AttributedString(markdown:)`.
enum MarkdownBlock: Equatable {
    /// A run of non-blank, non-special lines, joined by `\n` (internal newlines
    /// preserved). Rendered as inline markdown.
    case paragraph(String)
    /// Consecutive `- `/`* ` lines, markers stripped.
    case bulletList([String])
    /// Consecutive `N. ` lines, markers stripped.
    case numberedList([String])
    /// Consecutive `> ` lines, marker stripped, joined by `\n`.
    case blockquote(String)
    /// A fenced (```` ``` ````) code block. `language` is the trimmed info-string
    /// language hint after the opening fence (nil when absent); `code` is the
    /// verbatim inner lines joined by `\n`. The fences are dropped.
    case codeBlock(language: String?, code: String)
    /// An ATX heading (`#`+ followed by a space); `level` is the count of
    /// leading `#`, `text` is the remainder.
    case heading(level: Int, text: String)
}

/// Pure, testable block-level markdown parser for plan section bodies. Splits a
/// body into an ordered array of `MarkdownBlock`. It never throws and never
/// crashes on any input; malformed constructs (e.g. an unclosed fenced code
/// block) fall back gracefully rather than dropping content.
enum MarkdownBlockRenderer {
    static func parse(_ body: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []

        // Accumulators for the currently-open block. Only one is non-empty at a
        // time; `flush()` emits whichever is active and resets.
        var paragraphLines: [String] = []
        var bulletItems: [String] = []
        var numberedItems: [String] = []
        var quoteLines: [String] = []

        func flush() {
            if !paragraphLines.isEmpty {
                blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
                paragraphLines = []
            }
            if !bulletItems.isEmpty {
                blocks.append(.bulletList(bulletItems))
                bulletItems = []
            }
            if !numberedItems.isEmpty {
                blocks.append(.numberedList(numberedItems))
                numberedItems = []
            }
            if !quoteLines.isEmpty {
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                quoteLines = []
            }
        }

        let lines = body.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let rawLine = lines[index]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // Fenced code block: a line whose trimmed form starts with ```.
            // Collect inner lines verbatim until the closing fence (or end of
            // input, in which case we still emit a code block).
            if trimmed.hasPrefix("```") {
                flush()
                let language = Self.parseFenceLanguage(trimmed)
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        index += 1 // consume the closing fence
                        break
                    }
                    codeLines.append(candidate)
                    index += 1
                }
                blocks.append(.codeBlock(language: language, code: codeLines.joined(separator: "\n")))
                continue
            }

            // Blank line: separates blocks.
            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }

            // ATX heading: `#`+ followed by a space.
            if let heading = Self.parseHeading(trimmed) {
                flush()
                blocks.append(heading)
                index += 1
                continue
            }

            // Bullet list item: `- ` or `* `.
            if let item = Self.parseBullet(trimmed) {
                // Switching away from any other open block kind.
                if !paragraphLines.isEmpty || !numberedItems.isEmpty || !quoteLines.isEmpty {
                    flush()
                }
                bulletItems.append(item)
                index += 1
                continue
            }

            // Numbered list item: `N. `.
            if let item = Self.parseNumbered(trimmed) {
                if !paragraphLines.isEmpty || !bulletItems.isEmpty || !quoteLines.isEmpty {
                    flush()
                }
                numberedItems.append(item)
                index += 1
                continue
            }

            // Blockquote line: `> ` or bare `>`.
            if trimmed.hasPrefix(">") {
                if !paragraphLines.isEmpty || !bulletItems.isEmpty || !numberedItems.isEmpty {
                    flush()
                }
                quoteLines.append(Self.stripQuoteMarker(trimmed))
                index += 1
                continue
            }

            // Anything else: paragraph text.
            if !bulletItems.isEmpty || !numberedItems.isEmpty || !quoteLines.isEmpty {
                flush()
            }
            paragraphLines.append(rawLine)
            index += 1
        }

        flush()
        return blocks
    }

    /// Extracts the language hint from an opening fence line (already trimmed).
    /// Drops the leading ```` ``` ````, trims, and takes the first whitespace-
    /// delimited token. Returns `nil` when no language is present.
    private static func parseFenceLanguage(_ trimmed: String) -> String? {
        let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        guard !info.isEmpty else { return nil }
        let token = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
        return token.map(String.init)
    }

    /// Parses an ATX heading from an already-trimmed line, or returns `nil`.
    /// The level is the count of leading `#`; there must be a space after them.
    private static func parseHeading(_ trimmed: String) -> MarkdownBlock? {
        var level = 0
        let chars = Array(trimmed)
        while level < chars.count && chars[level] == "#" {
            level += 1
        }
        guard level >= 1, level < chars.count, chars[level] == " " else {
            return nil
        }
        let text = String(chars[(level + 1)...]).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    /// Strips a `- ` or `* ` bullet marker from an already-trimmed line, or
    /// returns `nil` when the line is not a bullet item.
    private static func parseBullet(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("- ") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        if trimmed.hasPrefix("* ") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Strips a `N. ` numbered marker from an already-trimmed line, or returns
    /// `nil` when the line is not a numbered item.
    private static func parseNumbered(_ trimmed: String) -> String? {
        let chars = Array(trimmed)
        var i = 0
        while i < chars.count && chars[i].isNumber {
            i += 1
        }
        guard i > 0, i + 1 < chars.count, chars[i] == ".", chars[i + 1] == " " else {
            return nil
        }
        return String(chars[(i + 2)...]).trimmingCharacters(in: .whitespaces)
    }

    /// Strips a leading `>` and one optional following space from an
    /// already-trimmed blockquote line.
    private static func stripQuoteMarker(_ trimmed: String) -> String {
        var rest = String(trimmed.dropFirst()) // drop the '>'
        if rest.hasPrefix(" ") {
            rest = String(rest.dropFirst())
        }
        return rest
    }
}
