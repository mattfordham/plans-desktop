import Foundation

/// Which projects the browser's "All projects" card stack shows (#072) — the
/// single, labelled "view mode" that REPLACES the previous pile of overlapping
/// rule-toggles. It consolidates the old "Hide Empty" gate (#021) into two
/// named, mutually-exclusive states: `.all` and `.active`.
///
/// `.active` means exactly what it says — outstanding work, with no starred
/// rescue clause. A third `.starred` mode existed until #096; it was dropped
/// because the sidebar's Favourites section already lists the starred
/// projects. A stale persisted `"starred"` value fails `init(rawValue:)` and
/// `PlansStore` falls back to `.all`.
///
/// Persisted on `PlansStore.projectViewMode` (its `rawValue` is the wire form)
/// and driven from the card stack's toolbar control that renders `label` as
/// visible TEXT — the readability of the current state is the whole point.
///
/// `CaseIterable` so the toolbar can enumerate the modes; the UI properties
/// below use an exhaustive `switch self` with no `default:` (house style —
/// adding a future mode forces a compile error here rather than a silent
/// fallthrough).
enum ProjectViewMode: String, CaseIterable {
    /// Every project, filtered by nothing. The default.
    case all
    /// Only projects with outstanding work (`ProjectTasks.hasOutstandingWork`).
    /// Absorbs the old "Hide Empty" rule — WITHOUT its starred exception.
    case active

    /// A short, human-friendly label for the mode, rendered as text on the
    /// toolbar control so the current state is readable at a glance.
    var label: String {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        }
    }

    /// The SF Symbol accompanying the label on the toolbar control: a full
    /// stack for everything, a bolt for outstanding work.
    var symbolName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .active: return "bolt.fill"
        }
    }

    /// The next mode for a single-button cycle: all → active → all.
    var next: ProjectViewMode {
        switch self {
        case .all: return .active
        case .active: return .all
        }
    }
}
