import SwiftUI

/// The glance color + ordering for the menu bar glance (Surface A) and the
/// browser. Kept separate from `TaskParser.swift` (which is Foundation-only)
/// because this extension needs SwiftUI for `Color`.
///
/// Colors and order are taken VERBATIM from the plans-cc TUI dashboard
/// (`lib/render-dashboard.js` — the Gruvbox `COLORS` palette and the
/// `STAT_CARDS` ordering) so the desktop glance reads identically to the
/// terminal dashboard.
extension TaskStatus {
    /// The glance color for this status, matching the exact hex used by the
    /// plans-cc TUI dashboard `COLORS` map in `lib/render-dashboard.js`.
    ///
    /// The `switch` is exhaustive over `self` with no `default:` so that adding a
    /// future status to `TaskStatus` forces a compile error here rather than
    /// silently falling through to a placeholder color.
    var glanceColor: Color {
        switch self {
        case .pending: return Color(hex: 0x665c54)
        case .elaborated: return Color(hex: 0xd5c4a1)
        case .inProgress: return Color(hex: 0xebdbb2)
        case .review: return Color(hex: 0x458588)
        case .inReview: return Color(hex: 0xd3869b)
        case .completed: return Color(hex: 0x8ec07c)
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
}

/// The (glyph, color) indicator for a task, mirroring the plans-cc TUI
/// dashboard's `glyphFor` + `colorForTask` precedence in
/// `lib/render-dashboard.js`: a blocked task ALWAYS shows `⊘` in the blocked
/// color (`#cc6666`) regardless of its status; otherwise the status's own
/// glyph + `glanceColor` are used. A `nil` status falls back to a blank glyph in
/// a neutral color.
///
/// Pure value type so it is unit-testable without SwiftUI views.
struct TaskStatusIndicator: Equatable {
    let glyph: String
    let color: Color

    /// The blocked color from the TUI `COLORS.blocked` (`#cc6666`).
    static let blockedColor = Color(hex: 0xcc6666)
    /// The blocked glyph from the TUI `glyphFor` (`⊘`).
    static let blockedGlyph = "⊘"
    /// The neutral fallback color for a `nil`/unknown status (TUI `COLORS.id`).
    static let neutralColor = Color(hex: 0xebdbb2)

    /// Builds the indicator for a task with the given `status`, honoring the
    /// blocked-takes-precedence rule. `isBlocked` overrides everything (TUI
    /// behavior: `if (task.isBlocked) return …` is the first check in both
    /// `glyphFor` and `colorForTask`).
    init(status: TaskStatus?, isBlocked: Bool) {
        if isBlocked {
            glyph = Self.blockedGlyph
            color = Self.blockedColor
        } else if let status {
            glyph = status.glanceGlyph
            color = status.glanceColor
        } else {
            glyph = " "
            color = Self.neutralColor
        }
    }
}

extension Color {
    /// Builds an opaque `Color` from a 24-bit `0xRRGGBB` hex literal, matching
    /// the hex strings used by the plans-cc TUI dashboard.
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
