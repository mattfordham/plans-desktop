import XCTest
import SwiftUI
@testable import Plans

/// Tests for the branch-mode sync indicator on the project card: the single
/// display state derived from the `.plans` sync status plus the last sync
/// outcome, its marks (mirroring the plans-cc dashboard `buildPlansLine`),
/// symbol/color, and tooltip copy.
final class PlansSyncStateGlyphTests: XCTestCase {

    private func status(
        upstream: Bool = true,
        ahead: Int = 0,
        behind: Int = 0,
        rebaseStuck: Bool = false
    ) -> PlansSyncStatus {
        PlansSyncStatus(
            branch: "plans", remote: "origin", upstream: upstream,
            ahead: ahead, behind: behind, rebaseStuck: rebaseStuck
        )
    }

    private func resolve(
        mode: PlansStorageMode? = .branch,
        status: PlansSyncStatus?,
        outcome: PlansGitHelper.SyncOutcome? = nil,
        syncing: Bool = false
    ) -> PlansSyncState? {
        PlansSyncState.resolve(mode: mode, status: status, lastOutcome: outcome, isSyncing: syncing)
    }

    // MARK: - Visibility

    func testNothingShownOutsideBranchMode() {
        for mode in [PlansStorageMode?.none, .some(.none), .local, .inline] {
            XCTAssertNil(resolve(mode: mode, status: status()), "mode \(String(describing: mode))")
        }
    }

    func testNothingShownBeforeStatusIsKnown() {
        XCTAssertNil(resolve(status: nil))
        XCTAssertNil(resolve(status: nil, outcome: .conflict))
    }

    // MARK: - Priority order

    func testInSyncWhenNothingToReport() {
        XCTAssertEqual(resolve(status: status()), .inSync)
        XCTAssertEqual(resolve(status: status(), outcome: .synced), .inSync)
    }

    func testAheadAndBehindCarryCounts() {
        XCTAssertEqual(resolve(status: status(ahead: 2)), .aheadBehind(ahead: 2, behind: 0))
        XCTAssertEqual(resolve(status: status(behind: 3)), .aheadBehind(ahead: 0, behind: 3))
        XCTAssertEqual(resolve(status: status(ahead: 1, behind: 4)), .aheadBehind(ahead: 1, behind: 4))
    }

    func testFailedOutranksAheadBehind() {
        XCTAssertEqual(
            resolve(status: status(ahead: 2), outcome: .failed("plans sync failed: offline")),
            .failed("plans sync failed: offline")
        )
    }

    func testMissingHelperReadsAsFailed() {
        guard case .failed = resolve(status: status(), outcome: .helperMissing) else {
            return XCTFail("a missing helper should surface as a failed sync")
        }
    }

    func testLockedOutcomeIsNotAFailure() {
        XCTAssertEqual(resolve(status: status(), outcome: .locked), .inSync)
        XCTAssertEqual(resolve(status: status(behind: 1), outcome: .locked), .aheadBehind(ahead: 0, behind: 1))
    }

    func testNoUpstreamOutranksFailedAndCounts() {
        XCTAssertEqual(
            resolve(status: status(upstream: false, ahead: 3), outcome: .failed("x")),
            .noUpstream
        )
    }

    func testConflictAndStuckRebaseOutrankEverything() {
        XCTAssertEqual(
            resolve(status: status(upstream: false, ahead: 1), outcome: .conflict),
            .conflict
        )
        XCTAssertEqual(
            resolve(status: status(upstream: false, rebaseStuck: true), outcome: .failed("x")),
            .rebaseStuck
        )
    }

    func testSyncingShownWhileSyncRuns() {
        XCTAssertEqual(resolve(status: status(ahead: 1), outcome: .conflict, syncing: true), .syncing)
    }

    // MARK: - Marks (plans-cc dashboard `buildPlansLine`)

    func testMarksMirrorDashboard() {
        XCTAssertEqual(PlansSyncState.rebaseStuck.mark, "⚠ rebase stuck")
        XCTAssertEqual(PlansSyncState.noUpstream.mark, "⚠ no upstream")
        XCTAssertEqual(PlansSyncState.aheadBehind(ahead: 2, behind: 0).mark, "↑2")
        XCTAssertEqual(PlansSyncState.aheadBehind(ahead: 0, behind: 5).mark, "↓5")
        XCTAssertEqual(PlansSyncState.aheadBehind(ahead: 2, behind: 5).mark, "↑2 ↓5")
        XCTAssertEqual(PlansSyncState.inSync.mark, "✓")
    }

    // MARK: - Symbol + color

    func testColorsFollowDashboardPalette() {
        XCTAssertEqual(PlansSyncState.rebaseStuck.color, Color(hex: 0xcc6666))
        XCTAssertEqual(PlansSyncState.conflict.color, Color(hex: 0xcc6666))
        XCTAssertEqual(PlansSyncState.noUpstream.color, Color(hex: 0xfabd2f))
        XCTAssertEqual(PlansSyncState.aheadBehind(ahead: 1, behind: 0).color, Color(hex: 0xfabd2f))
        XCTAssertEqual(PlansSyncState.inSync.color, Color(hex: 0x8ec07c))
    }

    func testSymbolsAreDistinctPerState() {
        let states: [PlansSyncState] = [
            .syncing, .conflict, .rebaseStuck, .noUpstream, .failed("x"),
            .aheadBehind(ahead: 1, behind: 0), .inSync,
        ]
        for state in states {
            XCTAssertFalse(state.symbolName.isEmpty, "empty symbol for \(state)")
        }
        XCTAssertEqual(Set(states.map(\.symbolName)).count, states.count)
    }

    func testOnlyAheadBehindShowsCountText() {
        XCTAssertEqual(PlansSyncState.aheadBehind(ahead: 1, behind: 2).countText, "↑1 ↓2")
        XCTAssertNil(PlansSyncState.inSync.countText)
        XCTAssertNil(PlansSyncState.noUpstream.countText)
    }

    // MARK: - Tooltip

    func testTooltipCarriesWarningsAndRenumbers() {
        let result = PlansGitHelper.SyncResult(
            outcome: .synced,
            renumbered: [PlansGitHelper.Renumber(from: "041", to: "043")],
            warnings: ["plans push to origin/plans failed (committed locally; will retry on next push)"]
        )
        let tooltip = PlansSyncState.tooltip(
            for: .aheadBehind(ahead: 1, behind: 0), status: status(ahead: 1), lastResult: result
        )
        XCTAssertTrue(tooltip.contains("↑1"), tooltip)
        XCTAssertTrue(tooltip.contains("Warning: plans push to origin/plans failed"), tooltip)
        XCTAssertTrue(tooltip.contains("Renumbered #041 → #043"), tooltip)
    }

    func testTooltipDoesNotRepeatTheFailureWarning() {
        let message = "plans sync failed: could not reach origin"
        let result = PlansGitHelper.SyncResult(outcome: .failed(message), warnings: [message])
        let tooltip = PlansSyncState.tooltip(for: .failed(message), status: status(), lastResult: result)
        XCTAssertEqual(tooltip.components(separatedBy: message).count - 1, 1, tooltip)
    }

    func testConflictTooltipExplainsBackoff() {
        let result = PlansGitHelper.SyncResult(outcome: .conflict, warnings: ["conflict text"])
        let tooltip = PlansSyncState.tooltip(for: .conflict, status: status(), lastResult: result)
        XCTAssertTrue(tooltip.contains("Auto-sync is paused"), tooltip)
        XCTAssertTrue(tooltip.contains("Warning: conflict text"), tooltip)
    }

    func testInSyncTooltipNamesBranchAndRemote() {
        let tooltip = PlansSyncState.tooltip(for: .inSync, status: status(), lastResult: nil)
        XCTAssertTrue(tooltip.contains("plans"), tooltip)
        XCTAssertTrue(tooltip.contains("origin"), tooltip)
    }
}
