import SwiftUI

/// Per-task type badge (§6 Type Glyphs) for the browser (Surface B). Kept
/// separate from `TaskParser.swift` (which is Foundation-only) so the enum stays
/// SwiftUI-free; this extension layers the presentation on top, mirroring how
/// `TaskStatus+Glance.swift` layers `glanceColor` onto `TaskStatus`.
///
/// Glyphs are taken VERBATIM from the §6 type table so the desktop browser's
/// type badges read identically to the plans-cc convention.
extension TaskType {
    /// The emoji glyph for this task type (§6 type table). The `switch` is
    /// exhaustive over `self` with no `default:` so that adding a future case to
    /// `TaskType` forces a compile error here rather than silently rendering a
    /// placeholder glyph.
    var glyph: String {
        switch self {
        case .bug: return "🐞"
        case .feature: return "✨"
        case .refactor: return "♻️"
        case .chore: return "🔧"
        }
    }

    /// A short human label for this task type, shown as a `[label]` tag next to
    /// the status glyph in the browser (mirroring the TUI dashboard's
    /// `[type]` tag). Exhaustive, no `default:`, for the same compile-safety
    /// reason as `glyph`.
    var label: String {
        switch self {
        case .bug: return "bug"
        case .feature: return "feature"
        case .refactor: return "refactor"
        case .chore: return "chore"
        }
    }
}

/// A short display label per status for the browser's status-filter sidebar
/// (Surface B). Lives here alongside the type badge so all browser presentation
/// helpers are co-located; the menu-bar glance helpers stay in
/// `TaskStatus+Glance.swift`. Exhaustive `switch` with no `default:` so a future
/// status forces a compile error.
extension TaskStatus {
    /// A short, human-friendly label for the status filter (e.g. "In progress").
    /// Distinct from the enum `rawValue` (which is the wire string) so the UI can
    /// read naturally without leaking the hyphenated raw form.
    var filterLabel: String {
        switch self {
        case .pending: return "Pending"
        case .elaborated: return "Elaborated"
        case .inProgress: return "In progress"
        case .review: return "Review"
        case .inReview: return "In review"
        case .completed: return "Completed"
        }
    }
}
