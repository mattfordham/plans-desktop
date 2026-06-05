import XCTest
import SwiftUI
@testable import Plans

/// Tests for the glance color + symbol + ordering on `TaskStatus`, plus the
/// `TaskStatusIndicator` symbol/color resolution.
///
/// The ORDER (`glanceOrder`) and the text `glanceGlyph` are taken verbatim from
/// the plans-cc TUI dashboard (`lib/render-dashboard.js`): the `STAT_CARDS`
/// ordering (which omits `completed`) and `glyphFor`. The COLOR palette
/// (`glanceColor`), by contrast, is a curated, fixed-hex desktop palette chosen
/// for legibility as icon fills — each `glanceColor` is asserted against a
/// `Color(hex:)` built from the same literal so the palette stays pinned and any
/// drift fails loudly.
final class TaskStatusGlanceTests: XCTestCase {

    // MARK: - glanceColor (curated desktop palette — pinned hexes)

    func testPendingMatchesPinnedHex() {
        XCTAssertEqual(TaskStatus.pending.glanceColor, Color(hex: 0x928374))
    }

    func testElaboratedMatchesPinnedHex() {
        XCTAssertEqual(TaskStatus.elaborated.glanceColor, Color(hex: 0x83a598))
    }

    func testInProgressMatchesPinnedHex() {
        XCTAssertEqual(TaskStatus.inProgress.glanceColor, Color(hex: 0xfabd2f))
    }

    func testReviewMatchesPinnedHex() {
        XCTAssertEqual(TaskStatus.review.glanceColor, Color(hex: 0x458588))
    }

    func testInReviewMatchesPinnedHex() {
        XCTAssertEqual(TaskStatus.inReview.glanceColor, Color(hex: 0xd3869b))
    }

    func testCompletedMatchesPinnedHex() {
        XCTAssertEqual(TaskStatus.completed.glanceColor, Color(hex: 0x8ec07c))
    }

    // MARK: - symbolName (curated SF Symbols — pinned strings)

    func testSymbolNamesMatchExpectedSFSymbols() {
        XCTAssertEqual(TaskStatus.pending.symbolName, "circle.dotted")
        XCTAssertEqual(TaskStatus.elaborated.symbolName, "circle")
        XCTAssertEqual(TaskStatus.inProgress.symbolName, "play.circle.fill")
        XCTAssertEqual(TaskStatus.review.symbolName, "star.circle.fill")
        XCTAssertEqual(TaskStatus.inReview.symbolName, "eye.circle.fill")
        XCTAssertEqual(TaskStatus.completed.symbolName, "checkmark.circle.fill")
    }

    /// Every status maps to a non-empty SF Symbol — totality guard (mirrors the
    /// `glanceGlyph` totality test in `BrowserWindowTests`).
    func testSymbolNameTotalAcrossAllCases() {
        for status in TaskStatus.allCases {
            XCTAssertFalse(status.symbolName.isEmpty, "empty symbolName for \(status)")
        }
    }

    // MARK: - TaskStatusIndicator symbol resolution (blocked precedence)

    /// A non-blocked task passes through its status `symbolName` + `glanceColor`.
    func testIndicatorUsesStatusSymbolAndColorWhenNotBlocked() {
        let indicator = TaskStatusIndicator(status: .inProgress, isBlocked: false)
        XCTAssertEqual(indicator.symbolName, TaskStatus.inProgress.symbolName)
        XCTAssertEqual(indicator.color, TaskStatus.inProgress.glanceColor)
    }

    /// `isBlocked` ALWAYS wins over the status (mirrors the TUI precedence where
    /// the blocked check is first) — even with a non-nil status.
    func testIndicatorBlockedSymbolTakesPrecedenceOverStatus() {
        let indicator = TaskStatusIndicator(status: .inProgress, isBlocked: true)
        XCTAssertEqual(indicator.symbolName, TaskStatusIndicator.blockedSymbol)
        XCTAssertEqual(indicator.color, TaskStatusIndicator.blockedColor)
    }

    /// A blocked task with a `nil` status still shows the blocked symbol + color.
    func testIndicatorBlockedSymbolWithNilStatusStillBlocked() {
        let indicator = TaskStatusIndicator(status: nil, isBlocked: true)
        XCTAssertEqual(indicator.symbolName, TaskStatusIndicator.blockedSymbol)
        XCTAssertEqual(indicator.color, TaskStatusIndicator.blockedColor)
    }

    /// A `nil` status that is not blocked falls back to the neutral symbol +
    /// neutral color.
    func testIndicatorNilStatusFallsBackToNeutralSymbol() {
        let indicator = TaskStatusIndicator(status: nil, isBlocked: false)
        XCTAssertEqual(indicator.symbolName, TaskStatusIndicator.neutralSymbol)
        XCTAssertEqual(indicator.color, TaskStatusIndicator.neutralColor)
    }

    // MARK: - glance order

    /// The glance order mirrors the TUI `STAT_CARDS` order and excludes
    /// `completed` — the menu bar surfaces only outstanding work.
    func testGlanceOrderMatchesTUIStatCardsAndOmitsCompleted() {
        XCTAssertEqual(
            TaskStatus.glanceOrder,
            [.pending, .elaborated, .inProgress, .review, .inReview]
        )
        XCTAssertFalse(TaskStatus.glanceOrder.contains(.completed))
    }
}
