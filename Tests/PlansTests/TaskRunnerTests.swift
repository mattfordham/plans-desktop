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

    // MARK: - "Work this task" button gating (segment 3)

    /// `PlanDetailView.canWork` is the pure predicate behind the button's
    /// `.disabled(...)`. It is enabled only for an elaborated / in-progress,
    /// non-blocked task while no run is already in flight.
    @MainActor
    func testCanWorkGating() {
        // Workable statuses, not blocked, not running → enabled.
        XCTAssertTrue(PlanDetailView.canWork(status: .elaborated, isBlocked: false, isRunning: false))
        XCTAssertTrue(PlanDetailView.canWork(status: .inProgress, isBlocked: false, isRunning: false))

        // Non-workable status → disabled.
        XCTAssertFalse(PlanDetailView.canWork(status: .pending, isBlocked: false, isRunning: false))
        XCTAssertFalse(PlanDetailView.canWork(status: nil, isBlocked: false, isRunning: false))

        // Blocked → disabled even with a workable status.
        XCTAssertFalse(PlanDetailView.canWork(status: .elaborated, isBlocked: true, isRunning: false))

        // A run already in flight → disabled.
        XCTAssertFalse(PlanDetailView.canWork(status: .inProgress, isBlocked: false, isRunning: true))
    }

    /// `PlanDetailView.canElaborate` is the pure predicate behind the
    /// "Elaborate" button's `.disabled(...)`. It is enabled only for a pending,
    /// non-blocked task while no run is already in flight.
    @MainActor
    func testCanElaborateGating() {
        // Pending, not blocked, not running → enabled.
        XCTAssertTrue(PlanDetailView.canElaborate(status: .pending, isBlocked: false, isRunning: false))

        // Non-pending statuses → disabled (elaboration only applies to pending).
        XCTAssertFalse(PlanDetailView.canElaborate(status: .elaborated, isBlocked: false, isRunning: false))
        XCTAssertFalse(PlanDetailView.canElaborate(status: .inProgress, isBlocked: false, isRunning: false))
        XCTAssertFalse(PlanDetailView.canElaborate(status: nil, isBlocked: false, isRunning: false))

        // Blocked → disabled even when pending.
        XCTAssertFalse(PlanDetailView.canElaborate(status: .pending, isBlocked: true, isRunning: false))

        // A run already in flight → disabled.
        XCTAssertFalse(PlanDetailView.canElaborate(status: .pending, isBlocked: false, isRunning: true))
    }
}
