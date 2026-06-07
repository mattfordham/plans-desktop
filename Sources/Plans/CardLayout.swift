import Foundation

/// The card-grid layout mode for the browser dashboard (#033): whether the cards
/// flow into a responsive, vertically-scrolling grid (`.scroll`, the default) or
/// are packed into a near-square grid sized to fit every card on screen at once
/// (`.fit`). Persisted on `PlansStore.cardLayoutMode` (its `rawValue` is the wire
/// form) and toggled from a browser-window toolbar control.
///
/// `CaseIterable` so the toolbar can enumerate the modes; the UI properties below
/// use an exhaustive `switch self` with no `default:` (house style — adding a
/// future mode forces a compile error here rather than a silent fallthrough).
enum CardLayoutMode: String, CaseIterable {
    /// Responsive, vertically-scrolling grid: column count derived from viewport
    /// width (`BrowserWindow.columnCount(forWidth:)`). The historical behavior.
    case scroll
    /// Near-square grid sized so every card fits on screen at once: column count
    /// derived from the card count (`BrowserWindow.fitColumnCount(forCount:)`).
    case fit

    /// A short, human-friendly label for the mode, shown on the toolbar control.
    var label: String {
        switch self {
        case .scroll: return "Scroll"
        case .fit: return "Fit to Screen"
        }
    }

    /// The SF Symbol for a toolbar toggle reflecting this mode.
    var symbolName: String {
        switch self {
        case .scroll: return "arrow.up.arrow.down"
        case .fit: return "rectangle.split.3x3"
        }
    }

    /// The opposite mode, for a single-button toggle that flips `.scroll` ⇄ `.fit`.
    var toggled: CardLayoutMode {
        switch self {
        case .scroll: return .fit
        case .fit: return .scroll
        }
    }
}
