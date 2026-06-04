import XCTest
import SwiftUI
@testable import Plans

/// Tests for the glance color + ordering on `TaskStatus`. Colors and order are
/// taken verbatim from the plans-cc TUI dashboard (`lib/render-dashboard.js`):
/// the Gruvbox `COLORS` hex palette and the `STAT_CARDS` ordering (which omits
/// `completed`). Each `glanceColor` is asserted against a `Color(hex:)` built
/// from the same literal, so equality holds exactly.
final class TaskStatusGlanceTests: XCTestCase {
    func testPendingMatchesTUIHex() {
        XCTAssertEqual(TaskStatus.pending.glanceColor, Color(hex: 0x665c54))
    }

    func testElaboratedMatchesTUIHex() {
        XCTAssertEqual(TaskStatus.elaborated.glanceColor, Color(hex: 0xd5c4a1))
    }

    func testInProgressMatchesTUIHex() {
        XCTAssertEqual(TaskStatus.inProgress.glanceColor, Color(hex: 0xebdbb2))
    }

    func testReviewMatchesTUIHex() {
        XCTAssertEqual(TaskStatus.review.glanceColor, Color(hex: 0x458588))
    }

    func testInReviewMatchesTUIHex() {
        XCTAssertEqual(TaskStatus.inReview.glanceColor, Color(hex: 0xd3869b))
    }

    func testCompletedMatchesTUIHex() {
        XCTAssertEqual(TaskStatus.completed.glanceColor, Color(hex: 0x8ec07c))
    }

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
