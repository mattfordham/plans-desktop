import SwiftUI

/// A `MarkdownBlock` with all of its per-block work already done: inline
/// markdown turned into styled `AttributedString`s and code highlighted. The
/// view only wraps these finished values, which `PreparedMarkdownCache` keeps
/// so the work happens once per body rather than on every render.
enum PreparedMarkdownBlock: Equatable {
    case paragraph(AttributedString)
    case heading(level: Int, text: String)
    case bulletList([AttributedString])
    case numberedList([AttributedString])
    case blockquote(AttributedString)
    case codeBlock(AttributedString)
}

/// Pure helpers that turn a section body into its finished render model.
enum MarkdownPreparer {
    /// Builds the finished render model for a section body.
    static func prepare(_ body: String, style: MarkdownStyle) -> [PreparedMarkdownBlock] {
        let inline: (String) -> AttributedString = { prepareInline($0, bodySize: style.bodySize) }
        return MarkdownBlockRenderer.parse(body).map { block in
            switch block {
            case let .paragraph(text):
                return .paragraph(inline(text))
            case let .heading(level, text):
                return .heading(level: level, text: text)
            case let .bulletList(items):
                return .bulletList(items.map(inline))
            case let .numberedList(items):
                return .numberedList(items.map(inline))
            case let .blockquote(text):
                return .blockquote(inline(text))
            case let .codeBlock(language, code):
                return .codeBlock(CodeHighlighter.highlight(code, language: language))
            }
        }
    }

    /// Styles one run of inline markdown at `bodySize`: prose in the body font,
    /// inline `` `code` `` as a monospaced, accent-tinted chip. Text that fails
    /// to parse as markdown falls back to plain text in the body font.
    static func prepareInline(_ text: String, bodySize: CGFloat) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            var plain = AttributedString(text)
            plain.font = .system(size: bodySize)
            return plain
        }
        attributed.font = .system(size: bodySize)
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            attributed[run.range].font = .system(size: bodySize, design: .monospaced)
            attributed[run.range].foregroundColor = .accentColor
        }
        return attributed
    }
}

/// A small least-recently-used cache of prepared section bodies, keyed by body
/// and style, so reopening a plan or re-rendering one repeats none of the work.
/// Keyed by content, so an edited body simply misses and is prepared afresh.
@MainActor
final class PreparedMarkdownCache {
    static let shared = PreparedMarkdownCache(capacity: 256)

    private struct Key: Hashable {
        let body: String
        let style: MarkdownStyle
    }

    private struct Entry {
        let blocks: [PreparedMarkdownBlock]
        var lastUsed: UInt64
    }

    private let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    /// The finished blocks for `body` at `style`, preparing and storing them
    /// on a miss.
    func preparedBlocks(forBody body: String, style: MarkdownStyle) -> [PreparedMarkdownBlock] {
        if let cached = blocks(forBody: body, style: style) { return cached }
        let prepared = MarkdownPreparer.prepare(body, style: style)
        store(prepared, forBody: body, style: style)
        return prepared
    }

    /// The prepared blocks for `body` at `style`, or `nil` on a miss. A hit
    /// counts as a use for eviction.
    func blocks(forBody body: String, style: MarkdownStyle) -> [PreparedMarkdownBlock]? {
        let key = Key(body: body, style: style)
        guard entries[key] != nil else { return nil }
        clock += 1
        entries[key]?.lastUsed = clock
        return entries[key]?.blocks
    }

    /// Stores `blocks`, evicting the least-recently-used entry when full.
    func store(_ blocks: [PreparedMarkdownBlock], forBody body: String, style: MarkdownStyle) {
        clock += 1
        entries[Key(body: body, style: style)] = Entry(blocks: blocks, lastUsed: clock)
        if entries.count > capacity,
           let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            entries[oldest] = nil
        }
    }
}
