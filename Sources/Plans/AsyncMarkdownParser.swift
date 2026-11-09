import Foundation

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

    /// Newest-wins guard for out-of-order background completions. Given a
    /// monotonically-increasing generation counter, a completed parse should be
    /// applied only when its generation exactly matches the current one; any
    /// older (stale) — or, defensively, newer — generation is dropped.
    static func shouldApply(completed: Int, current: Int) -> Bool {
        completed == current
    }
}
