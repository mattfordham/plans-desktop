import SwiftUI

/// The glance color + symbol + ordering for the menu bar glance (Surface A) and
/// the browser (Surface B). Kept separate from `TaskParser.swift` (which is
/// Foundation-only) because this extension needs SwiftUI for `Color`.
///
/// The ORDER (`glanceOrder`) and the text `glanceGlyph` remain derived from the
/// plans-cc TUI dashboard (`lib/render-dashboard.js` — the `STAT_CARDS`
/// ordering and `glyphFor`). The COLOR palette (`glanceColor`), by contrast, is
/// now INTENTIONALLY CURATED for the desktop app's clarity and legibility as
/// icon fills on the window background, rather than a verbatim copy of the
/// Gruvbox TUI hexes. Two of the old TUI tans (elaborated vs in-progress) read
/// as near-identical fills, so the desktop palette diverges deliberately to keep
/// all six statuses mutually distinguishable.
extension TaskStatus {
    /// The glance fill color for this status. A curated, fixed-hex palette
    /// chosen for legibility as an icon fill in the desktop app — NOT the exact
    /// plans-cc TUI hexes. Each hue is picked to be mutually distinguishable
    /// from the others (see the table below).
    ///
    /// Curated palette (status → hex → name / rationale):
    ///   pending     → 0x928374 → neutral gray  (muted, recedes; "not started")
    ///   elaborated  → 0x83a598 → teal/aqua     (distinct cool hue, away from inProgress)
    ///   inProgress  → 0xfabd2f → amber/yellow  (strong, active; clearly != elaborated)
    ///   review      → 0x458588 → blue          (ready for review; distinct from teal/aqua)
    ///   inReview    → 0xd3869b → pink           (in-review; unchanged, already distinct)
    ///   completed   → 0x8ec07c → green          (done; distinct from amber inProgress)
    ///
    /// The `switch` is exhaustive over `self` with no `default:` so that adding a
    /// future status to `TaskStatus` forces a compile error here rather than
    /// silently falling through to a placeholder color.
    var glanceColor: Color {
        switch self {
        case .pending: return Color(hex: 0x928374)
        case .elaborated: return Color(hex: 0x83a598)
        case .inProgress: return Color(hex: 0xfabd2f)
        case .review: return Color(hex: 0x458588)
        case .inReview: return Color(hex: 0xd3869b)
        case .completed: return Color(hex: 0x8ec07c)
        }
    }

    /// The SF Symbol (vector icon) for this status, chosen so each reads as its
    /// meaning while keeping the family visually consistent (mostly
    /// `*.circle.fill`). Unlike the text `glanceGlyph` (TUI-derived), these are
    /// curated for the desktop app.
    ///
    ///   pending     → circle.dotted        (outlined, "not started")
    ///   elaborated  → circle                (ready, an empty ring)
    ///   inProgress  → play.circle.fill      (actively running)
    ///   review      → star.circle.fill      (ready for review)
    ///   inReview    → eye.circle.fill        (being reviewed)
    ///   completed   → checkmark.circle.fill  (done)
    ///
    /// Exhaustive `switch` with no `default:` so a future status forces a
    /// compile error here.
    var symbolName: String {
        switch self {
        case .pending: return "circle.dotted"
        case .elaborated: return "circle"
        case .inProgress: return "play.circle.fill"
        case .review: return "star.circle.fill"
        case .inReview: return "eye.circle.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }

    /// The glyph/shape for this status, taken VERBATIM from the plans-cc TUI
    /// dashboard `glyphFor` in `lib/render-dashboard.js` so the desktop reads
    /// identically to the terminal: in-progress ▶, in-review ◉, review ★
    /// (ready for review), elaborated ○ (ready), pending · . `completed` is not
    /// shown as an active row in the TUI legend; we use a check `✓` for the rare
    /// place it must render. The blocked indicator (`⊘`) is NOT a status — it is
    /// derived from `isBlocked` and lives in `TaskStatusIndicator` below.
    ///
    /// Exhaustive `switch` with no `default:` so a future status forces a
    /// compile error here.
    var glanceGlyph: String {
        switch self {
        case .pending: return "·"
        case .elaborated: return "○"
        case .inProgress: return "▶"
        case .review: return "★"
        case .inReview: return "◉"
        case .completed: return "✓"
        }
    }

    /// The statuses shown in the menu bar glance, in the same order as the TUI
    /// dashboard's `STAT_CARDS` (pending → elaborated → in-progress → review →
    /// in-review). `completed` is intentionally EXCLUDED: the menu bar surfaces
    /// only outstanding/active work, so finished tasks are omitted from the
    /// glance (they remain visible in the browser, Surface B).
    static let glanceOrder: [TaskStatus] = [
        .pending,
        .elaborated,
        .inProgress,
        .review,
        .inReview,
    ]

    /// The sidebar "Backlog" smart-view tint color (#094). Backlog is a deferred
    /// state, so it reuses the muted neutral gray of `.pending` (`0x928374`) so it
    /// recedes next to the active-work colors. Kept here alongside the rest of the
    /// glance palette (the label/symbol live in `TaskType+Glyph.swift`).
    static let backlogGlanceColor = Color(hex: 0x928374)
}

/// The (symbol, glyph, color) indicator for a task, mirroring the plans-cc TUI
/// dashboard's `glyphFor` + `colorForTask` precedence in
/// `lib/render-dashboard.js`: a blocked task ALWAYS shows the blocked indicator
/// in the blocked color (`#cc6666`) regardless of its status; a FAILED task
/// (#079) shows its own alarm indicator (`xmark.octagon.fill` in the shared
/// `#cc6666` alarm color) ranked just below blocked; otherwise
/// the status's own symbol/glyph + `glanceColor` are used. A `nil` status falls
/// back to a neutral symbol/glyph in a neutral color.
///
/// Precedence (highest first): blocked → failed → status → neutral. Blocked is
/// kept first to preserve the TUI invariant that the blocked check is the first
/// branch of both `glyphFor` and `colorForTask`: a task that is both blocked and
/// failed shows the blocked symbol.
///
/// Carries BOTH the new SF Symbol (`symbolName`, for the desktop views) and the
/// legacy text `glyph` (for call sites not yet migrated). Pure value type so it
/// is unit-testable without SwiftUI views.
struct TaskStatusIndicator: Equatable {
    let symbolName: String
    let glyph: String
    let color: Color

    /// The blocked color from the TUI `COLORS.blocked` (`#cc6666`).
    static let blockedColor = Color(hex: 0xcc6666)
    /// The blocked glyph from the TUI `glyphFor` (`⊘`).
    static let blockedGlyph = "⊘"
    /// The blocked SF Symbol — a strong stop/halt icon that takes precedence.
    static let blockedSymbol = "exclamationmark.octagon.fill"
    /// The failure color (#079). Reuses the blocked hex (`#cc6666`) verbatim so
    /// both alarm states share a hue (their symbols differ).
    static let failureColor = blockedColor
    /// The failure SF Symbol (#079). An x-octagon, deliberately DISTINCT from
    /// blocked's exclamation-octagon (#102) so the two alarm states can be told
    /// apart while sharing the alarm color.
    static let failureSymbol = "xmark.octagon.fill"
    /// The neutral fallback color for a `nil`/unknown status (TUI `COLORS.id`).
    static let neutralColor = Color(hex: 0xebdbb2)
    /// The neutral fallback SF Symbol for a `nil`/unknown status.
    static let neutralSymbol = "circle.dashed"

    /// The SF Symbol for a task kept in a live worktree (executed with the
    /// `keep` keyword — see `Task.isKeptWorktree`). A house glyph, the desktop
    /// analogue of the plans-cc dashboard TUI's `⌂ kept` badge. Rendered muted
    /// (secondary) next to review-state rows so it reads as chrome, not status.
    static let keptWorktreeSymbol = "house"

    /// Builds the indicator for a task with the given `status`, honoring the
    /// precedence blocked → failed → status → neutral. `isBlocked` overrides
    /// everything (TUI behavior: `if (task.isBlocked) return …` is the first check
    /// in both `glyphFor` and `colorForTask`); `isFailed` (#079) ranks just below
    /// blocked and reuses the same alarm symbol/color. `isFailed` defaults to
    /// false so existing call sites that omit it are unchanged.
    init(status: TaskStatus?, isBlocked: Bool, isFailed: Bool = false) {
        if isBlocked {
            symbolName = Self.blockedSymbol
            glyph = Self.blockedGlyph
            color = Self.blockedColor
        } else if isFailed {
            symbolName = Self.failureSymbol
            glyph = Self.blockedGlyph
            color = Self.failureColor
        } else if let status {
            symbolName = status.symbolName
            glyph = status.glanceGlyph
            color = status.glanceColor
        } else {
            symbolName = Self.neutralSymbol
            glyph = " "
            color = Self.neutralColor
        }
    }
}

extension Color {
    /// Builds an opaque `Color` from a 24-bit `0xRRGGBB` hex literal, used by the
    /// curated desktop glance palette above.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
