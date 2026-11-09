import SwiftUI

/// A `MarkdownBlock` with all of its per-block work already done: inline
/// markdown turned into styled `AttributedString`s and code highlighted. The
/// view only wraps these finished values, so nothing expensive runs in a view
/// body (#113). `Sendable` so it can be built on a detached task.
enum PreparedMarkdownBlock: Equatable, Sendable {
    case paragraph(AttributedString)
    case heading(level: Int, text: String)
    case bulletList([AttributedString])
    case numberedList([AttributedString])
    case blockquote(AttributedString)
    case codeBlock(AttributedString)
}

/// Pure helpers backing the detail view's "suspense boundary" for section
/// bodies: parse markdown OFF the main thread, then decide whether a finished
/// parse is still the newest one before applying its result on the main thread.
///
/// Both helpers are pure and side-effect free so they can be driven from a
/// background queue and unit-tested without any SwiftUI. The parse delegates to
/// `MarkdownBlockRenderer.parse` — this type adds no parsing logic of its own;
/// it exists only to give callers a thread-agnostic entry point plus the
/// newest-wins generation guard.
enum AsyncMarkdownParser {
    /// Parse a section body into block-level elements. This is identical to
    /// `MarkdownBlockRenderer.parse(_:)` and is safe to call off the main
    /// thread (the renderer is a pure function).
    static func parse(_ body: String) -> [MarkdownBlock] {
        MarkdownBlockRenderer.parse(body)
    }

    /// Builds the finished render model for a section body. Safe to call off
    /// the main thread.
    static func prepare(_ body: String, style: MarkdownStyle) -> [PreparedMarkdownBlock] {
        let inline: (String) -> AttributedString = { prepareInline($0, bodySize: style.bodySize) }
        return parse(body).map { block in
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

    /// The most characters of a section body the loading placeholder shows.
    /// Enough to fill the visible part of a section; the rest is not worth
    /// laying out for the moment the placeholder is on screen.
    static let placeholderCharacterLimit = 600

    /// The text shown while a section body is being prepared, capped so the
    /// first frame's text layout does not grow with the size of the plan.
    static func placeholder(for body: String) -> String {
        String(body.prefix(placeholderCharacterLimit))
    }

    /// Newest-wins guard for out-of-order background completions. Given a
    /// monotonically-increasing generation counter, a completed parse should be
    /// applied only when its generation exactly matches the current one; any
    /// older (stale) — or, defensively, newer — generation is dropped.
    static func shouldApply(completed: Int, current: Int) -> Bool {
        completed == current
    }
}

/// A small least-recently-used cache of prepared section bodies, keyed by body
/// and style. Consulted synchronously when a section first renders, so a plan
/// that has been opened before shows its final content straight away (#113).
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
