import Foundation

/// Which projects the browser dashboard shows (#072) — the single, labelled
/// "view mode" that REPLACES the previous pile of overlapping rule-toggles. It
/// consolidates the old "Hide Empty" gate (#021) and the star exception (#035)
/// into three named, mutually-exclusive states: `.all`, `.active`, `.starred`.
///
/// The key change this encodes: star used to be nothing more than an EXCEPTION
/// to Hide Empty (a starred-but-empty project was rescued from the gate), so it
/// did nothing at all while the gate was off. Here `.starred` is a filter in its
/// own right, and `.active` means exactly what it says — outstanding work, with
/// no starred rescue clause. Curated projects live under `.starred` instead.
///
/// Persisted on `PlansStore.projectViewMode` (its `rawValue` is the wire form)
/// and driven from a browser-window toolbar control that renders `label` as
/// visible TEXT — the readability of the current state is the whole point.
///
/// `CaseIterable` so the toolbar can enumerate the modes; the UI properties
/// below use an exhaustive `switch self` with no `default:` (house style —
/// adding a future mode forces a compile error here rather than a silent
/// fallthrough). Modelled on `CardLayoutMode`.
enum ProjectViewMode: String, CaseIterable {
    /// Every project, filtered by nothing. The default.
    case all
    /// Only projects with outstanding work (`ProjectTasks.hasOutstandingWork`).
    /// Absorbs the old "Hide Empty" rule — WITHOUT its starred exception.
    case active
    /// Only projects the user has starred (`PlansStore.starredProjectPaths`),
    /// regardless of whether they have outstanding work.
    case starred

    /// A short, human-friendly label for the mode, rendered as text on the
    /// toolbar control so the current state is readable at a glance.
    var label: String {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        case .starred: return "Starred"
        }
    }

    /// The SF Symbol accompanying the label on the toolbar control. The three
    /// are deliberately distinct metaphors: a full stack, a running task, a star.
    var symbolName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .active: return "bolt.fill"
        case .starred: return "star.fill"
        }
    }

    /// The next mode for a single-button cycle: all → active → starred → all.
    /// The three-case analogue of `CardLayoutMode.toggled`.
    var next: ProjectViewMode {
        switch self {
        case .all: return .active
        case .active: return .starred
        case .starred: return .all
        }
    }
}
