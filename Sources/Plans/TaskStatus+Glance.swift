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
