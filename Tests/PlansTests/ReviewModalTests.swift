import XCTest
@testable import Plans

/// Tests for `ReviewModal`'s pure/static helpers (#083): the per-project default
/// `UserDefaults` key, the saved-default round-trip, the dirty-tree warning
/// decision, and the `main`-disabled decision given a `mainCheckoutOccupant`.
///
/// SwiftUI view bodies are not unit-tested; every decision the body renders comes
/// from one of these tested helpers. A per-test `UserDefaults` suite (named by a
/// fresh UUID) isolates the default-persistence tests from the real defaults.
final class ReviewModalTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "ReviewModalTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    // MARK: - Per-project default key

    /// The default key is namespaced and incorporates the project path so two
    /// projects keep independent review-location defaults.
    func testDefaultLocationKeyIsPerProject() {
        let keyA = ReviewModal.defaultLocationKey(projectPath: "/a/one")
        let keyB = ReviewModal.defaultLocationKey(projectPath: "/a/two")
        XCTAssertNotEqual(keyA, keyB)
        XCTAssertTrue(keyA.contains("/a/one"))
    }

    // MARK: - Saved default round-trip (UserDefaults, NOT config.json)

    func testSavedDefaultLocationNilWhenUnset() {
        XCTAssertNil(ReviewModal.savedDefaultLocation(projectPath: "/p", defaults: defaults))
    }

    func testSaveAndReadDefaultLocationRoundTrips() {
        ReviewModal.saveDefaultLocation(.main, projectPath: "/p", defaults: defaults)
        XCTAssertEqual(ReviewModal.savedDefaultLocation(projectPath: "/p", defaults: defaults), .main)

        ReviewModal.saveDefaultLocation(.worktree, projectPath: "/p", defaults: defaults)
        XCTAssertEqual(ReviewModal.savedDefaultLocation(projectPath: "/p", defaults: defaults), .worktree)
    }

    func testSavedDefaultLocationIsPerProject() {
        ReviewModal.saveDefaultLocation(.kept, projectPath: "/p1", defaults: defaults)
        XCTAssertEqual(ReviewModal.savedDefaultLocation(projectPath: "/p1", defaults: defaults), .kept)
        XCTAssertNil(ReviewModal.savedDefaultLocation(projectPath: "/p2", defaults: defaults))
    }

    func testSavedDefaultLocationNilForUnknownRawValue() {
        defaults.set("garbage", forKey: ReviewModal.defaultLocationKey(projectPath: "/p"))
        XCTAssertNil(ReviewModal.savedDefaultLocation(projectPath: "/p", defaults: defaults))
    }

    // MARK: - Initial location selection

    /// The initial selection prefers the saved default (when it is among the
    /// available locations), else falls back to the first available location.
    func testInitialLocationPrefersSavedDefaultWhenAvailable() {
        XCTAssertEqual(
            ReviewModal.initialLocation(saved: .main, available: [.worktree, .main]),
            .main)
    }

    func testInitialLocationFallsBackToFirstWhenSavedUnavailable() {
        // Saved `.kept` but the task no longer offers a kept worktree.
        XCTAssertEqual(
            ReviewModal.initialLocation(saved: .kept, available: [.worktree, .main]),
            .worktree)
    }

    func testInitialLocationFallsBackToFirstWhenNoSavedDefault() {
        XCTAssertEqual(
            ReviewModal.initialLocation(saved: nil, available: [.kept, .worktree, .main]),
            .kept)
    }

    // MARK: - Dirty-tree warning decision

    func testDirtyTreeWarningShownWhenDirty() {
        let warning = ReviewModal.dirtyTreeWarning(isDirty: true)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.lowercased().contains("uncommitted"))
    }

    func testDirtyTreeWarningHiddenWhenCleanOrUnknown() {
        XCTAssertNil(ReviewModal.dirtyTreeWarning(isDirty: false))
        // Unknown (nil) must not assert "dirty".
        XCTAssertNil(ReviewModal.dirtyTreeWarning(isDirty: nil))
    }

    // MARK: - Main-disabled decision (occupant held main checkout)

    func testMainDisabledReasonNamesTheOccupantTask() {
        let reason = ReviewModal.mainDisabledReason(occupantTaskID: "042")
        XCTAssertEqual(reason, "Main is held by #042")
    }

    func testMainDisabledReasonNilWhenNoOccupant() {
        XCTAssertNil(ReviewModal.mainDisabledReason(occupantTaskID: nil))
    }

    func testLocationDisabledOnlyMainAndOnlyWithOccupant() {
        // Main disabled when an occupant holds it.
        XCTAssertTrue(ReviewModal.isLocationDisabled(.main, mainOccupantTaskID: "042"))
        // Main enabled when no occupant.
        XCTAssertFalse(ReviewModal.isLocationDisabled(.main, mainOccupantTaskID: nil))
        // Non-main locations are never disabled by a main occupant.
        XCTAssertFalse(ReviewModal.isLocationDisabled(.kept, mainOccupantTaskID: "042"))
        XCTAssertFalse(ReviewModal.isLocationDisabled(.worktree, mainOccupantTaskID: "042"))
    }

    // MARK: - Main-checkout warning copy

    /// A main-checkout review leaves main on the task branch until
    /// `/plan-complete`; the modal surfaces that note for the `.main` location.
    func testMainCheckoutNoteShownOnlyForMain() {
        XCTAssertNotNil(ReviewModal.mainCheckoutNote(for: .main))
        XCTAssertNil(ReviewModal.mainCheckoutNote(for: .worktree))
        XCTAssertNil(ReviewModal.mainCheckoutNote(for: .kept))
    }
}
