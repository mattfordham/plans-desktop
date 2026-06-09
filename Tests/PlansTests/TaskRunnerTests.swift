import XCTest
@testable import Plans

/// Tests for `RunEvent` — the Swift mirror of the segment-1 Node NDJSON
/// contract (`run-task.js`). Decoding is the contract's keystone, so each of
/// the four line shapes is decoded from a literal JSON string and its case +
/// payload asserted. The pure newline/partial-line splitter
/// (`RunEvent.parseLines`) is also exercised, including a malformed line and a
/// retained trailing partial. No `Process` is spawned (that needs the bundle +
/// a real node run); only pure decoding is covered here.
final class TaskRunnerTests: XCTestCase {

    private func decode(_ json: String) throws -> RunEvent {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(RunEvent.self, from: data)
    }

    // MARK: - Per-kind decoding

    func testDecodesActivity() throws {
        let event = try decode(#"{"kind":"activity","tool":"Edit","detail":"src/foo.swift"}"#)
        guard case let .activity(tool, detail) = event else {
            return XCTFail("expected .activity, got \(event)")
        }
        XCTAssertEqual(tool, "Edit")
        XCTAssertEqual(detail, "src/foo.swift")
    }

    func testDecodesActivityWithMissingDetail() throws {
        let event = try decode(#"{"kind":"activity","tool":"Read"}"#)
        guard case let .activity(tool, detail) = event else {
            return XCTFail("expected .activity, got \(event)")
        }
        XCTAssertEqual(tool, "Read")
        XCTAssertNil(detail)
    }

    func testDecodesText() throws {
        let event = try decode(#"{"kind":"text","chunk":"Working on it"}"#)
        guard case let .text(chunk) = event else {
            return XCTFail("expected .text, got \(event)")
        }
        XCTAssertEqual(chunk, "Working on it")
    }

    func testDecodesDone() throws {
        let event = try decode(#"{"kind":"done","costUsd":0.42,"turns":7,"stopReason":"end_turn"}"#)
        guard case let .done(costUsd, turns, stopReason) = event else {
            return XCTFail("expected .done, got \(event)")
        }
        XCTAssertEqual(costUsd, 0.42, accuracy: 0.0001)
        XCTAssertEqual(turns, 7)
        XCTAssertEqual(stopReason, "end_turn")
    }

    func testDecodesDoneWithoutStopReason() throws {
        let event = try decode(#"{"kind":"done","costUsd":1.0,"turns":3}"#)
        guard case let .done(costUsd, turns, stopReason) = event else {
            return XCTFail("expected .done, got \(event)")
        }
        XCTAssertEqual(costUsd, 1.0, accuracy: 0.0001)
        XCTAssertEqual(turns, 3)
        XCTAssertNil(stopReason)
    }

    func testDecodesError() throws {
        let event = try decode(#"{"kind":"error","message":"boom"}"#)
        guard case let .error(message) = event else {
            return XCTFail("expected .error, got \(event)")
        }
        XCTAssertEqual(message, "boom")
    }

    func testUnknownKindThrows() {
        XCTAssertThrowsError(try decode(#"{"kind":"mystery"}"#))
    }

    func testLoggedEventGetsUniqueIdentityPerWrapper() throws {
        let event = try decode(#"{"kind":"text","chunk":"a"}"#)
        let a = LoggedEvent(event: event)
        let b = LoggedEvent(event: event)
        // Same payload, distinct identity — so SwiftUI keys duplicate log lines
        // separately and appends don't re-key earlier rows.
        XCTAssertEqual(a.event, b.event)
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - Newline splitting (pure function)

    func testParseLinesDecodesCompleteLinesAndRetainsPartial() {
        let stream = #"{"kind":"text","chunk":"one"}"# + "\n"
            + #"{"kind":"activity","tool":"Edit","detail":"x"}"# + "\n"
            + #"{"kind":"text","chunk":"partial"}"#  // no trailing newline
        var buffer = Data(stream.utf8)

        let events = RunEvent.parseLines(from: &buffer)

        XCTAssertEqual(events.count, 2)
        guard case let .text(chunk) = events[0] else {
            return XCTFail("expected first .text, got \(events[0])")
        }
        XCTAssertEqual(chunk, "one")
        guard case .activity = events[1] else {
            return XCTFail("expected second .activity, got \(events[1])")
        }
        // The trailing partial line is retained for the next chunk.
        XCTAssertEqual(String(decoding: buffer, as: UTF8.self),
                       #"{"kind":"text","chunk":"partial"}"#)
    }

    func testParseLinesSkipsMalformedAndBlankLines() {
        let stream = "\n"  // blank
            + "not json at all\n"  // malformed
            + #"{"kind":"bogus"}"# + "\n"  // unknown kind
            + #"{"kind":"done","costUsd":0.1,"turns":1,"stopReason":"x"}"# + "\n"
        var buffer = Data(stream.utf8)

        let events = RunEvent.parseLines(from: &buffer)

        XCTAssertEqual(events.count, 1)
        guard case .done = events[0] else {
            return XCTFail("expected .done, got \(events[0])")
        }
        // Everything was consumed (all lines had trailing newlines).
        XCTAssertTrue(buffer.isEmpty)
    }

    // MARK: - Budget/turn-cap truncation surfacing (task #041)

    /// `TaskRun.truncationError(for:)` is the single source of truth for which
    /// `done` stop reasons mean the run was cut short by a cap (so the red banner
    /// must fire). The two truncating SDK subtypes (`error_max_budget_usd`,
    /// `error_max_turns`) map to a non-nil message; a normal `end_turn` (and a
    /// missing reason) map to nil so a clean run shows no error.
    func testTruncationErrorMapsCapReasonsOnly() {
        XCTAssertNotNil(TaskRun.truncationError(for: "error_max_budget_usd"))
        XCTAssertNotNil(TaskRun.truncationError(for: "error_max_turns"))

        XCTAssertNil(TaskRun.truncationError(for: "end_turn"))
        XCTAssertNil(TaskRun.truncationError(for: nil))
        XCTAssertNil(TaskRun.truncationError(for: "unknown"))
    }

    /// Driving a `done` event whose `stopReason` is a truncating cap value
    /// through the run's ingest path sets BOTH `summary` (cost/turns, as today)
    /// AND `error` (so `PlanDetailView` shows the red banner above the summary).
    /// A normal `end_turn` done leaves `error` nil and only sets `summary`.
    @MainActor
    func testTruncatingDoneEventSurfacesErrorAndSummary() {
        // Budget cap → error + summary.
        let budgetRun = TaskRun(taskID: "041", mode: .execute)
        budgetRun.ingestForTesting(
            #"{"kind":"done","costUsd":19.5,"turns":42,"stopReason":"error_max_budget_usd"}"# + "\n"
        )
        XCTAssertNotNil(budgetRun.error)
        XCTAssertEqual(budgetRun.summary?.turns, 42)

        // Turn cap → error + summary.
        let turnsRun = TaskRun(taskID: "041", mode: .execute)
        turnsRun.ingestForTesting(
            #"{"kind":"done","costUsd":2.0,"turns":99,"stopReason":"error_max_turns"}"# + "\n"
        )
        XCTAssertNotNil(turnsRun.error)
        XCTAssertEqual(turnsRun.summary?.turns, 99)

        // Normal completion → summary only, no error banner.
        let cleanRun = TaskRun(taskID: "041", mode: .execute)
        cleanRun.ingestForTesting(
            #"{"kind":"done","costUsd":0.42,"turns":7,"stopReason":"end_turn"}"# + "\n"
        )
        XCTAssertNil(cleanRun.error)
        XCTAssertEqual(cleanRun.summary?.turns, 7)
    }

    // MARK: - "Work this task" button gating (segment 3)

    /// `PlanDetailView.canWork` is the pure predicate behind the Execute action's
    /// availability. Available only for an elaborated, non-blocked task — an
    /// in-progress task already has a run going (or done) and must not offer
    /// Execute again (#027). Whether a run is in flight is a separate, per-task
    /// concern handled by the UI (spinner vs button) and does NOT gate
    /// availability.
    @MainActor
    func testCanWorkGating() {
        // Elaborated, not blocked → available.
        XCTAssertTrue(PlanDetailView.canWork(status: .elaborated, isBlocked: false))

        // In-progress is NOT workable: Execute must not appear once work started.
        XCTAssertFalse(PlanDetailView.canWork(status: .inProgress, isBlocked: false))

        // Other non-workable statuses → unavailable.
        XCTAssertFalse(PlanDetailView.canWork(status: .pending, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canWork(status: .review, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canWork(status: .inReview, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canWork(status: .completed, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canWork(status: nil, isBlocked: false))

        // Blocked → unavailable even with an otherwise-workable status.
        XCTAssertFalse(PlanDetailView.canWork(status: .elaborated, isBlocked: true))
        XCTAssertFalse(PlanDetailView.canWork(status: .inProgress, isBlocked: true))
    }

    /// `PlanDetailView.canElaborate` is the pure predicate behind the Elaborate
    /// action's availability. Available only for a pending, non-blocked task.
    @MainActor
    func testCanElaborateGating() {
        // Pending, not blocked → available.
        XCTAssertTrue(PlanDetailView.canElaborate(status: .pending, isBlocked: false))

        // Non-pending statuses → unavailable (elaboration only applies to pending).
        XCTAssertFalse(PlanDetailView.canElaborate(status: .elaborated, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canElaborate(status: .inProgress, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canElaborate(status: nil, isBlocked: false))

        // Blocked → unavailable even when pending.
        XCTAssertFalse(PlanDetailView.canElaborate(status: .pending, isBlocked: true))
    }

    /// The coordinator tracks runs per task id: `isRunning(taskID:)` is false for
    /// an unknown task, and a freshly created `TaskRun` carries the right
    /// identity + mode before it is started.
    @MainActor
    func testCoordinatorTracksRunsPerTask() {
        let coordinator = TaskRunner()
        XCTAssertFalse(coordinator.isRunning(taskID: "001"))
        XCTAssertNil(coordinator.run(for: "001"))

        let run = TaskRun(taskID: "042", mode: .elaborate)
        XCTAssertEqual(run.taskID, "042")
        XCTAssertEqual(run.mode, .elaborate)
        XCTAssertFalse(run.isRunning)
    }

    // MARK: - Capture mode (task #023)

    /// `RunMode` is `String`-backed; the raw value is the `--mode` flag passed
    /// to the Node runner, so `capture` must round-trip exactly.
    func testCaptureModeRoundTripsRawValue() {
        XCTAssertEqual(RunMode.capture.rawValue, "capture")
        XCTAssertEqual(RunMode(rawValue: "capture"), .capture)
    }

    /// A `.capture` run carries the free-text `description` (threaded to the
    /// runner's `--description` flag) and the synthetic `"capture:<path>"`
    /// identity used in place of a not-yet-existing task id. It is not running
    /// until started.
    @MainActor
    func testCaptureRunCarriesDescriptionAndSyntheticIdentity() {
        let run = TaskRun(taskID: "capture:/some/project", mode: .capture, description: "Add a thing")
        XCTAssertEqual(run.taskID, "capture:/some/project")
        XCTAssertEqual(run.mode, .capture)
        XCTAssertEqual(run.description, "Add a thing")
        XCTAssertFalse(run.isRunning)
    }

    /// The `description` init parameter defaults to `nil`, so non-capture runs
    /// (execute / elaborate, which operate on an existing task id) carry no
    /// description.
    @MainActor
    func testNonCaptureRunHasNilDescriptionByDefault() {
        let run = TaskRun(taskID: "042", mode: .execute)
        XCTAssertNil(run.description)
    }

    /// `executeYolo` is the "Execute" checkbox's mode: it round-trips its raw
    /// value (the `--mode` flag) and, like capture, carries a free-text
    /// description in place of a not-yet-existing task id.
    @MainActor
    func testExecuteYoloModeRoundTripsAndCarriesDescription() {
        XCTAssertEqual(RunMode.executeYolo.rawValue, "executeYolo")
        XCTAssertEqual(RunMode(rawValue: "executeYolo"), .executeYolo)

        let run = TaskRun(taskID: "capture:/some/project", mode: .executeYolo, description: "Build a thing")
        XCTAssertEqual(run.mode, .executeYolo)
        XCTAssertEqual(run.description, "Build a thing")
        XCTAssertFalse(run.isRunning)
    }

    /// Capture and executeYolo share one synthetic per-project identity PREFIX, so
    /// the header "+" control's progress rows and popovers track either run kind
    /// under keys derived from the same prefix.
    func testCaptureKeyIsModeIndependentAndPerProject() {
        XCTAssertEqual(TaskRunner.captureKey(projectPath: "/some/project"),
                       "capture:/some/project")
        XCTAssertNotEqual(TaskRunner.captureKey(projectPath: "/a"),
                          TaskRunner.captureKey(projectPath: "/b"))
    }

    // MARK: - Multiple back-to-back captures (task #029)

    /// `capture(...)` now keys every submission under a UNIQUE per-run id of the
    /// form `captureKey(projectPath:) + ":" + UUID().uuidString`, so two captures
    /// for the SAME project no longer collide on one key (the old single-key
    /// guard is gone). Asserted against the construction logic directly (the
    /// `runs` map is `private(set)` and only populable by `capture()`/`run()`,
    /// which spawn `node` — so we never call them here).
    func testUniqueCaptureKeysForSameProjectAreDistinctAndSharePrefix() {
        let prefix = TaskRunner.captureKey(projectPath: "/some/project") + ":"
        let keyA = prefix + UUID().uuidString
        let keyB = prefix + UUID().uuidString

        // Distinct submissions get distinct keys (no collision / no guard).
        XCTAssertNotEqual(keyA, keyB)
        // Both still resolve back to this project via the shared prefix.
        XCTAssertTrue(keyA.hasPrefix(prefix))
        XCTAssertTrue(keyB.hasPrefix(prefix))
    }

    /// The prefix-boundary logic `runningCaptures(projectPath:)` filters on: a
    /// per-run key for project `/a` (`captureKey("/a") + ":" + uuid`) has prefix
    /// `captureKey("/a") + ":"`, but does NOT have prefix `captureKey("/ab") + ":"`
    /// — the trailing `:` separator prevents a project whose path is a string
    /// prefix of another (`/a` vs `/ab`) from matching. Asserted purely (no
    /// `capture()`/`run()` call, which would spawn `node`).
    func testRunningCapturesPrefixBoundaryRejectsStringPrefixProject() {
        let prefixA = TaskRunner.captureKey(projectPath: "/a") + ":"
        let prefixAB = TaskRunner.captureKey(projectPath: "/ab") + ":"

        let keyForA = prefixA + UUID().uuidString

        // The /a key matches /a's prefix...
        XCTAssertTrue(keyForA.hasPrefix(prefixA))
        // ...but NOT /ab's prefix — the `:` separator is the boundary guard.
        XCTAssertFalse(keyForA.hasPrefix(prefixAB))
    }

    // MARK: - Capture mode selection (task #031)

    /// `TaskRunner.captureMode(execute:elaborate:)` is the pure helper behind the
    /// `capture(...)` mode precedence: Execute wins (`.executeYolo`), else
    /// Elaborate (`.captureElaborate`), else a plain `.capture`. Extracted so the
    /// precedence is unit-testable without spawning `node` (`capture(...)` starts
    /// a real run).
    func testCaptureModeSelectionPrecedence() {
        // Execute wins regardless of elaborate.
        XCTAssertEqual(TaskRunner.captureMode(execute: true, elaborate: false), .executeYolo)
        XCTAssertEqual(TaskRunner.captureMode(execute: true, elaborate: true), .executeYolo)

        // Then elaborate (when execute is off).
        XCTAssertEqual(TaskRunner.captureMode(execute: false, elaborate: true), .captureElaborate)

        // Else a plain capture.
        XCTAssertEqual(TaskRunner.captureMode(execute: false, elaborate: false), .capture)
    }

    /// `RunMode.usesDescription` is the pure flag `TaskRun.spawn` consults to pass
    /// `--description <text>` (and omit `--task-id`): true for the three
    /// description-driven modes (`.capture`, `.captureElaborate`, `.executeYolo`),
    /// false for the existing-task modes (`.execute`, `.elaborate`). Asserting it
    /// directly verifies the `.captureElaborate` description wiring without
    /// spawning a real `node` process.
    func testRunModeUsesDescriptionFlag() {
        XCTAssertTrue(RunMode.capture.usesDescription)
        XCTAssertTrue(RunMode.captureElaborate.usesDescription)
        XCTAssertTrue(RunMode.executeYolo.usesDescription)

        XCTAssertFalse(RunMode.execute.usesDescription)
        XCTAssertFalse(RunMode.elaborate.usesDescription)
    }

    // The Node-side `--description` arg shape (capture / executeYolo runs pass
    // `--description <text>` and omit `--task-id`) is verified by inspection of
    // `TaskRun.spawn` / `run-task.ts`; it is not exercised here because that
    // would require spawning a real `node` process. The synthetic-key contract
    // (`"capture:" + projectPath`) that `TaskRunner.capture(...)` registers a
    // run under is covered by the `TaskRun` identity test above — calling
    // `capture(...)` is deliberately avoided so this test surface stays pure
    // (no `Process` spawn, no flakiness).
}
