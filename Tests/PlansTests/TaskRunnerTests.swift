import SwiftUI
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

    // MARK: - Denied tool calls (task #092)

    /// A `{"kind":"denied","tool":"…"}` line decodes into `.denied(tool:)`,
    /// reusing the existing `tool` coding key — the Swift mirror of the segment-1
    /// Node contract addition. This is the keystone the run's accumulation path
    /// depends on.
    func testDecodesDenied() throws {
        let event = try decode(#"{"kind":"denied","tool":"mcp__sentry__get_sentry_resource"}"#)
        guard case let .denied(tool) = event else {
            return XCTFail("expected .denied, got \(event)")
        }
        XCTAssertEqual(tool, "mcp__sentry__get_sentry_resource")
    }

    /// A `.denied` event round-trips through encode → decode unchanged, so the
    /// NDJSON contract is symmetric (mirrors the other per-kind shapes).
    func testDeniedRoundTripsThroughEncodeDecode() throws {
        let original = RunEvent.denied(tool: "mcp__sentry__search_issues")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RunEvent.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// `parseLines` decodes a `denied` line interleaved with other kinds, so the
    /// non-terminal denial signal flows through the exact splitter the live
    /// stream uses.
    func testParseLinesDecodesDeniedAmongOtherKinds() {
        let stream = #"{"kind":"text","chunk":"thinking"}"# + "\n"
            + #"{"kind":"denied","tool":"mcp__sentry__search_errors"}"# + "\n"
            + #"{"kind":"done","costUsd":0.1,"turns":2,"stopReason":"end_turn"}"# + "\n"
        var buffer = Data(stream.utf8)

        let events = RunEvent.parseLines(from: &buffer)

        XCTAssertEqual(events.count, 3)
        guard case let .denied(tool) = events[1] else {
            return XCTFail("expected .denied at index 1, got \(events[1])")
        }
        XCTAssertEqual(tool, "mcp__sentry__search_errors")
    }

    /// Feeding several `denied` lines (with a repeat) through the run's ingest
    /// path accumulates `deniedTools` in arrival order WITH duplicates (so the
    /// count preserves retries) while `deniedToolNames` dedups to the distinct
    /// set. This is exactly what the UI count + name-list render from.
    @MainActor
    func testDeniedLinesAccumulateWithDuplicateCountAndDistinctSet() {
        let run = TaskRun(taskID: "092", mode: .elaborate)
        run.ingestForTesting(
            #"{"kind":"denied","tool":"mcp__sentry__search_issues"}"# + "\n"
            + #"{"kind":"denied","tool":"mcp__sentry__search_issues"}"# + "\n"
            + #"{"kind":"denied","tool":"mcp__sentry__search_errors"}"# + "\n"
        )

        // Ordered, duplicates kept → per-call count is 3.
        XCTAssertEqual(run.deniedTools,
                       ["mcp__sentry__search_issues",
                        "mcp__sentry__search_issues",
                        "mcp__sentry__search_errors"])
        XCTAssertEqual(run.deniedTools.count, 3)
        // Distinct set dedups the retried tool → 2 names.
        XCTAssertEqual(run.deniedToolNames,
                       ["mcp__sentry__search_issues", "mcp__sentry__search_errors"])
        XCTAssertEqual(run.deniedToolNames.count, 2)
    }

    /// A `denied` line is NON-fatal: it must not set the run's `error` nor
    /// populate `summary` (those are reserved for the terminal `error`/`done`
    /// events). The run continues as if the tool simply wasn't used.
    @MainActor
    func testDeniedLineDoesNotSetErrorOrSummary() {
        let run = TaskRun(taskID: "092", mode: .elaborate)
        run.ingestForTesting(
            #"{"kind":"denied","tool":"mcp__sentry__update_issue"}"# + "\n"
        )
        XCTAssertFalse(run.deniedTools.isEmpty)
        XCTAssertNil(run.error, "a denial is non-fatal and must not latch an error")
        XCTAssertNil(run.summary, "a denial must not populate the run summary")
    }

    /// Regression guard for `parseLines`: now that `.denied` is a real kind, an
    /// UNKNOWN `kind` must STILL be skipped gracefully (not decoded, not fatal),
    /// so a future contract addition degrades to "fewer lines" rather than
    /// aborting the whole stream.
    func testParseLinesStillSkipsUnknownKindAlongsideDenied() {
        let stream = #"{"kind":"denied","tool":"mcp__sentry__find_projects"}"# + "\n"
            + #"{"kind":"future_kind","payload":"x"}"# + "\n"  // unknown → skipped
            + #"{"kind":"text","chunk":"after"}"# + "\n"
        var buffer = Data(stream.utf8)

        let events = RunEvent.parseLines(from: &buffer)

        // The unknown line is dropped; the denied and text lines survive.
        XCTAssertEqual(events.count, 2)
        guard case .denied = events[0] else {
            return XCTFail("expected .denied at index 0, got \(events[0])")
        }
        guard case let .text(chunk) = events[1] else {
            return XCTFail("expected .text at index 1, got \(events[1])")
        }
        XCTAssertEqual(chunk, "after")
        XCTAssertTrue(buffer.isEmpty)
    }

    /// On finish, a run with denials carries the tally into its durable
    /// `RunOutcome`: `deniedToolCount` preserves the per-call count (retries
    /// included) while `deniedTools` is the sorted DISTINCT set — the diagnostic
    /// "this run finished but couldn't reach Sentry" that survives the sheet.
    @MainActor
    func testFinishWritesDeniedToolTallyIntoOutcome() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("run-outcomes.log")
        let run = TaskRun(
            taskID: "092", mode: .elaborate,
            outcomeLog: RunOutcomeLog(fileURL: tmp), now: { "t" }
        )
        run.ingestForTesting(
            #"{"kind":"denied","tool":"mcp__sentry__search_issues"}"# + "\n"
            + #"{"kind":"denied","tool":"mcp__sentry__search_issues"}"# + "\n"
            + #"{"kind":"denied","tool":"mcp__sentry__search_errors"}"# + "\n"
            + #"{"kind":"done","costUsd":0.5,"turns":9,"stopReason":"end_turn"}"# + "\n"
        )
        run.finishForTesting(projectPath: "/proj")

        let outcome = try JSONDecoder().decode(
            RunOutcome.self,
            from: Data(try String(contentsOf: tmp, encoding: .utf8).split(separator: "\n")[0].utf8)
        )
        // A denial is non-fatal, so the run is still classified `.completed`.
        XCTAssertEqual(outcome.classification, .completed)
        XCTAssertEqual(outcome.deniedToolCount, 3, "per-call count keeps retries")
        XCTAssertEqual(outcome.deniedTools,
                       ["mcp__sentry__search_errors", "mcp__sentry__search_issues"],
                       "distinct set, sorted")
    }

    // MARK: - Completion gating (exit + stdout EOF)

    private func tempOutcomeLog() -> RunOutcomeLog {
        RunOutcomeLog(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("run-outcomes.log"))
    }

    /// The process can exit before its last stdout chunk is read. The run must
    /// stay live until EOF so that chunk (here, a reply split across reads plus
    /// the `done`) is still decoded and delivered.
    @MainActor
    func testRunWaitsForStdoutEOFAfterProcessExit() {
        let run = TaskRun(taskID: "049", mode: .discuss, description: "q",
                          outcomeLog: tempOutcomeLog())
        var finished = 0
        var events: [RunEvent] = []
        run.onEvent = { events.append($0) }
        run.markRunningForTesting(projectPath: "/proj", onFinish: { finished += 1 })

        run.ingestForTesting(#"{"kind":"session","sessionId":"s1"}"# + "\n" + #"{"kind":"reply","te"#)
        run.processExitedForTesting(status: 0)
        XCTAssertTrue(run.isRunning, "exit alone must not finish the run")
        XCTAssertEqual(finished, 0)

        run.ingestForTesting(#"xt":"The answer","sessionId":"s1"}"# + "\n"
            + #"{"kind":"done","costUsd":0.1,"turns":2,"stopReason":"end_turn"}"#)
        run.streamClosedForTesting()

        XCTAssertFalse(run.isRunning)
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(run.reply, "The answer")
        XCTAssertNotNil(run.summary, "unterminated trailing done is drained at completion")
        XCTAssertTrue(events.contains { if case .reply = $0 { return true } else { return false } })
    }

    @MainActor
    func testRunFinishesWhenEOFPrecedesExit() {
        let run = TaskRun(taskID: "049", mode: .discuss, description: "q",
                          outcomeLog: tempOutcomeLog())
        var finished = 0
        run.markRunningForTesting(projectPath: "/proj", onFinish: { finished += 1 })
        run.ingestForTesting(#"{"kind":"done","costUsd":0.1,"turns":2}"# + "\n")
        run.streamClosedForTesting()
        XCTAssertTrue(run.isRunning)
        run.processExitedForTesting(status: 0)
        XCTAssertFalse(run.isRunning)
        XCTAssertEqual(finished, 1)
    }

    /// A grandchild can hold stdout open after the runner exits; the run still
    /// finishes after the grace period rather than hanging forever.
    @MainActor
    func testRunFinishesAfterGracePeriodWhenEOFNeverArrives() async throws {
        let run = TaskRun(taskID: "049", mode: .discuss, description: "q",
                          outcomeLog: tempOutcomeLog())
        run.streamCloseGracePeriod = .milliseconds(20)
        var finished = 0
        run.markRunningForTesting(projectPath: "/proj", onFinish: { finished += 1 })
        run.processExitedForTesting(status: 0)
        XCTAssertTrue(run.isRunning)
        try await _Concurrency.Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(run.isRunning)
        XCTAssertEqual(finished, 1)
        run.streamClosedForTesting()
        XCTAssertEqual(finished, 1, "late EOF does not finish twice")
    }

    @MainActor
    func testNonzeroExitWithoutTerminalSurfacesErrorOnceGateCompletes() {
        let run = TaskRun(taskID: "049", mode: .execute, outcomeLog: tempOutcomeLog())
        run.markRunningForTesting(projectPath: "/proj")
        run.processExitedForTesting(status: 2)
        XCTAssertNil(run.error)
        run.streamClosedForTesting()
        XCTAssertEqual(run.error, "Work-task process exited unexpectedly (code 2).")
    }

    /// `stop()` finishes immediately; the stopped process's later exit/EOF must
    /// not finish (or write an outcome) a second time.
    @MainActor
    func testStopFinishesOnceEvenWhenExitAndEOFFollow() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("run-outcomes.log")
        let run = TaskRun(taskID: "049", mode: .execute,
                          outcomeLog: RunOutcomeLog(fileURL: tmp), now: { "t" })
        var finished = 0
        run.markRunningForTesting(projectPath: "/proj", onFinish: { finished += 1 })
        run.stop()
        XCTAssertEqual(finished, 1)
        run.processExitedForTesting(status: 15)
        run.streamClosedForTesting()
        XCTAssertEqual(finished, 1)
        let lines = try String(contentsOf: tmp, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "exactly one outcome record")
    }

    // MARK: - Session / reply (discussion)

    func testDecodesSession() throws {
        let event = try decode(#"{"kind":"session","sessionId":"abc"}"#)
        XCTAssertEqual(event, .session(id: "abc"))
    }

    func testDecodesReply() throws {
        let event = try decode(#"{"kind":"reply","text":"Because it is simpler.","sessionId":"abc"}"#)
        XCTAssertEqual(event, .reply(text: "Because it is simpler.", sessionID: "abc"))
    }

    func testSessionAndReplyRoundTripThroughEncodeDecode() throws {
        for original in [RunEvent.session(id: "s-1"), .reply(text: "answer", sessionID: "s-1")] {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(RunEvent.self, from: data)
            XCTAssertEqual(decoded, original)
        }
    }

    func testParseLinesDecodesSessionAndReplyAmongOtherKinds() {
        let stream = #"{"kind":"session","sessionId":"abc"}"# + "\n"
            + #"{"kind":"activity","tool":"Read","detail":"plan.md"}"# + "\n"
            + #"{"kind":"text","chunk":"Let me look."}"# + "\n"
            + #"{"kind":"reply","text":"Final answer","sessionId":"abc"}"# + "\n"
            + #"{"kind":"done","costUsd":0.2,"turns":3,"stopReason":"end_turn"}"# + "\n"
        var buffer = Data(stream.utf8)

        let events = RunEvent.parseLines(from: &buffer)

        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events[0], .session(id: "abc"))
        XCTAssertEqual(events[3], .reply(text: "Final answer", sessionID: "abc"))
        guard case .done = events[4] else {
            return XCTFail("expected .done at index 4, got \(events[4])")
        }
    }

    @MainActor
    func testRunExposesSessionIDAndReplyWithoutTouchingErrorOrSummary() {
        let run = TaskRun(taskID: "099", mode: .discuss, description: "why?")
        XCTAssertNil(run.sessionID)
        XCTAssertNil(run.reply)

        run.ingestForTesting(
            #"{"kind":"session","sessionId":"abc"}"# + "\n"
            + #"{"kind":"reply","text":"Because.","sessionId":"abc"}"# + "\n"
        )

        XCTAssertEqual(run.sessionID, "abc")
        XCTAssertEqual(run.reply, "Because.")
        XCTAssertNil(run.error)
        XCTAssertNil(run.summary)
    }

    @MainActor
    func testReplySessionIDUpdatesRunSessionID() {
        let run = TaskRun(taskID: "099", mode: .discuss, description: "why?")
        run.ingestForTesting(
            #"{"kind":"session","sessionId":"first"}"# + "\n"
            + #"{"kind":"reply","text":"ok","sessionId":"second"}"# + "\n"
        )
        XCTAssertEqual(run.sessionID, "second")
    }

    // MARK: - Argument builder

    func testArgumentsForExecute() {
        let args = TaskRun.arguments(
            scriptPath: "/b/run-task.js", projectPath: "/proj", taskID: "019",
            mode: .execute, description: nil, deep: false, keep: true, resume: nil
        )
        XCTAssertEqual(args, [
            "/b/run-task.js", "--project-root", "/proj",
            "--task-id", "019", "--mode", "execute", "--keep",
        ])
    }

    func testArgumentsForDiscussWithoutResume() {
        let args = TaskRun.arguments(
            scriptPath: "/b/run-task.js", projectPath: "/proj", taskID: "099",
            mode: .discuss, description: "why?", deep: false, keep: false, resume: nil
        )
        XCTAssertEqual(args, [
            "/b/run-task.js", "--project-root", "/proj",
            "--task-id", "099", "--description", "why?", "--mode", "discuss",
        ])
    }

    func testArgumentsForDiscussWithApplyEmitsApplyAfterMode() {
        let args = TaskRun.arguments(
            scriptPath: "/b/run-task.js", projectPath: "/proj", taskID: "099",
            mode: .discuss, description: "apply it", deep: false, keep: false,
            resume: nil, apply: true
        )
        XCTAssertEqual(args, [
            "/b/run-task.js", "--project-root", "/proj",
            "--task-id", "099", "--description", "apply it", "--mode", "discuss",
            "--apply",
        ])
    }

    func testArgumentsForDiscussWithApplyAndResumeEmitsApplyBeforeResume() {
        let args = TaskRun.arguments(
            scriptPath: "/b/run-task.js", projectPath: "/proj", taskID: "099",
            mode: .discuss, description: "apply it", deep: false, keep: false,
            resume: "sess-1", apply: true
        )
        XCTAssertEqual(args, [
            "/b/run-task.js", "--project-root", "/proj",
            "--task-id", "099", "--description", "apply it", "--mode", "discuss",
            "--apply", "--resume", "sess-1",
        ])
    }

    func testArgumentsForDiscussWithoutApplyOmitsApply() {
        let args = TaskRun.arguments(
            scriptPath: "/b/run-task.js", projectPath: "/proj", taskID: "099",
            mode: .discuss, description: "why?", deep: false, keep: false,
            resume: nil, apply: false
        )
        XCTAssertFalse(args.contains("--apply"), "default discuss must omit --apply")
    }

    func testArgumentsIgnoreApplyForNonDiscussModes() {
        for mode in [RunMode.execute, .elaborate, .reElaborate] {
            let args = TaskRun.arguments(
                scriptPath: "/s", projectPath: "/p", taskID: "1",
                mode: mode, description: "d", deep: false, keep: false,
                resume: nil, apply: true
            )
            XCTAssertFalse(args.contains("--apply"), "\(mode) must not pass --apply")
        }
    }

    func testArgumentsForDiscussWithResumeAppendResumeAfterMode() {
        let args = TaskRun.arguments(
            scriptPath: "/b/run-task.js", projectPath: "/proj", taskID: "099",
            mode: .discuss, description: "and then?", deep: false, keep: false, resume: "sess-1"
        )
        XCTAssertEqual(args, [
            "/b/run-task.js", "--project-root", "/proj",
            "--task-id", "099", "--description", "and then?", "--mode", "discuss",
            "--resume", "sess-1",
        ])
    }

    func testArgumentsIgnoreResumeForNonDiscussModes() {
        for mode in [RunMode.execute, .elaborate, .reElaborate] {
            let args = TaskRun.arguments(
                scriptPath: "/s", projectPath: "/p", taskID: "1",
                mode: mode, description: "d", deep: true, keep: false, resume: "sess-1"
            )
            XCTAssertFalse(args.contains("--resume"), "\(mode) must not pass --resume")
            XCTAssertEqual(args.last, "--deep")
        }
    }

    func testArgumentsIgnoreEmptyResume() {
        let args = TaskRun.arguments(
            scriptPath: "/s", projectPath: "/p", taskID: "1",
            mode: .discuss, description: "q", deep: false, keep: false, resume: ""
        )
        XCTAssertFalse(args.contains("--resume"))
    }

    @MainActor
    func testDiscussRunCarriesResume() {
        let run = TaskRun(taskID: "099", mode: .discuss, description: "q", resume: "sess-1")
        XCTAssertEqual(run.resume, "sess-1")
        XCTAssertNil(TaskRun(taskID: "099", mode: .discuss, description: "q").resume)
    }

    @MainActor
    func testFinishWritesNoOutcomeForDiscuss() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("run-outcomes.log")
        let run = TaskRun(
            taskID: "099", mode: .discuss, description: "q",
            outcomeLog: RunOutcomeLog(fileURL: tmp), now: { "t" }
        )
        run.ingestForTesting(
            #"{"kind":"error","message":"boom"}"# + "\n"
        )
        run.finishForTesting(projectPath: "/proj")

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path),
                       "a discuss turn must never raise or mask a task failure badge")
        XCTAssertFalse(run.isRunning)
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

    /// `TaskRun.truncationError(for:)` also maps the #058 stranded stop reason
    /// (`stranded_at_in_progress`) to a non-nil, stranded-specific message so the
    /// red banner fires when an execute run finished cleanly but left the task at
    /// in-progress. The existing clean/missing/unknown reasons still map to nil.
    func testTruncationErrorMapsStrandedReason() {
        XCTAssertNotNil(TaskRun.truncationError(for: TaskRun.strandedStopReason))

        // Unchanged: a clean finish (and an unrelated reason) surfaces no error.
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

    /// #081 regression: a `done` event carrying a failing (stranded) stop reason
    /// latches `error` via `handle`, but a `done` does NOT clear `isRunning`
    /// (only `finish()` does). So a run can simultaneously be live (`isRunning ==
    /// true`) AND carry a non-nil `error` — the exact state that armed the red
    /// banner mid-run. This asserts that co-existing state directly so the
    /// banner predicate (which must NOT fire in this state) has a proven basis.
    @MainActor
    func testDoneDerivedErrorLatchesWhileStillRunning() {
        let run = TaskRun(taskID: "081", mode: .execute)
        run.markRunningForTesting()
        run.ingestForTesting(
            #"{"kind":"done","costUsd":3.1,"turns":22,"stopReason":"stranded_at_in_progress"}"# + "\n"
        )

        // The done classification latched an error message...
        XCTAssertNotNil(run.error)
        XCTAssertEqual(run.lastStopReason, "stranded_at_in_progress")
        // ...yet the run is still live: a `done` does not clear `isRunning`.
        XCTAssertTrue(run.isRunning)
    }

    // MARK: - Durable run-outcome logging

    /// On finish, a run writes exactly one `RunOutcome` line to its injected log
    /// capturing the stop reason, cost/turns, and the derived classification —
    /// the durable answer to "why did this task strand?" that survives the
    /// progress sheet closing. A budget-cap done is classified `truncated`.
    @MainActor
    func testFinishWritesTruncatedOutcomeFromBudgetCap() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("run-outcomes.log")
        let run = TaskRun(
            taskID: "410", mode: .execute,
            outcomeLog: RunOutcomeLog(fileURL: tmp),
            now: { "2026-06-16T11:06:46Z" }
        )
        run.ingestForTesting(
            #"{"kind":"done","costUsd":19.9,"turns":58,"stopReason":"error_max_budget_usd"}"# + "\n"
        )
        run.finishForTesting(projectPath: "/proj")

        let contents = try String(contentsOf: tmp, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1)
        let outcome = try JSONDecoder().decode(RunOutcome.self, from: Data(lines[0].utf8))
        XCTAssertEqual(outcome.taskID, "410")
        XCTAssertEqual(outcome.mode, "execute")
        XCTAssertEqual(outcome.projectPath, "/proj")
        XCTAssertEqual(outcome.stopReason, "error_max_budget_usd")
        XCTAssertEqual(outcome.turns, 58)
        XCTAssertEqual(outcome.classification, .truncated)
    }

    /// Driving a `done` event whose `stopReason` is the #058 stranded signal
    /// through the run's ingest path (a) surfaces a non-nil `error` (so the run
    /// reads as non-success — the red banner fires above the summary) and (b) on
    /// finish writes a `RunOutcome` classified `.stranded` carrying the
    /// `stranded_at_in_progress` stop reason — the durable answer to "why did
    /// this task strand at in-progress?".
    @MainActor
    func testFinishWritesStrandedOutcomeFromStrandedReason() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("run-outcomes.log")
        let run = TaskRun(
            taskID: "058", mode: .execute,
            outcomeLog: RunOutcomeLog(fileURL: tmp),
            now: { "2026-06-24T09:00:00Z" }
        )
        run.ingestForTesting(
            #"{"kind":"done","costUsd":3.1,"turns":22,"stopReason":"stranded_at_in_progress"}"# + "\n"
        )
        // (a) Surfaced as non-success: a stranded run sets `error`.
        XCTAssertNotNil(run.error)
        XCTAssertEqual(run.summary?.turns, 22)

        run.finishForTesting(projectPath: "/proj")

        // (b) Exactly one outcome written, classified `.stranded`.
        let contents = try String(contentsOf: tmp, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1)
        let outcome = try JSONDecoder().decode(RunOutcome.self, from: Data(lines[0].utf8))
        XCTAssertEqual(outcome.taskID, "058")
        XCTAssertEqual(outcome.classification, .stranded)
        XCTAssertEqual(outcome.stopReason, "stranded_at_in_progress")
    }

    /// A clean `end_turn` done is classified `completed`.
    @MainActor
    func testFinishWritesCompletedOutcomeForCleanRun() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("run-outcomes.log")
        let run = TaskRun(
            taskID: "411", mode: .execute,
            outcomeLog: RunOutcomeLog(fileURL: tmp), now: { "t" }
        )
        run.ingestForTesting(
            #"{"kind":"done","costUsd":0.4,"turns":7,"stopReason":"end_turn"}"# + "\n"
        )
        run.finishForTesting(projectPath: "/proj")

        let outcome = try JSONDecoder().decode(
            RunOutcome.self,
            from: Data(try String(contentsOf: tmp, encoding: .utf8).split(separator: "\n")[0].utf8)
        )
        XCTAssertEqual(outcome.classification, .completed)
        XCTAssertNil(outcome.errorMessage)
    }

    /// A nonzero exit with no terminal line is classified `crashed`.
    @MainActor
    func testFinishWritesCrashedOutcome() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("run-outcomes.log")
        let run = TaskRun(
            taskID: "412", mode: .execute,
            outcomeLog: RunOutcomeLog(fileURL: tmp), now: { "t" }
        )
        run.finishForTesting(projectPath: "/proj", error: "exited unexpectedly", nonzeroCrash: true)

        let outcome = try JSONDecoder().decode(
            RunOutcome.self,
            from: Data(try String(contentsOf: tmp, encoding: .utf8).split(separator: "\n")[0].utf8)
        )
        XCTAssertEqual(outcome.classification, .crashed)
        XCTAssertEqual(outcome.errorMessage, "exited unexpectedly")
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

    /// `PlanDetailView.canReElaborate` is the pure predicate behind the
    /// Re-elaborate action's availability. Available only for an already-elaborated,
    /// non-blocked task — re-elaboration refines an existing How checklist, so it
    /// applies once a first elaboration produced one and not after work started.
    @MainActor
    func testCanReElaborateGating() {
        // Elaborated, not blocked → available.
        XCTAssertTrue(PlanDetailView.canReElaborate(status: .elaborated, isBlocked: false))

        // Non-elaborated statuses → unavailable.
        XCTAssertFalse(PlanDetailView.canReElaborate(status: .pending, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canReElaborate(status: .inProgress, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canReElaborate(status: .review, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canReElaborate(status: .inReview, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canReElaborate(status: .completed, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canReElaborate(status: nil, isBlocked: false))

        // Blocked → unavailable even when elaborated.
        XCTAssertFalse(PlanDetailView.canReElaborate(status: .elaborated, isBlocked: true))
    }

    /// The coordinator tracks runs per task: `isRunning(taskID:in:)` is false for
    /// an unknown task, and a freshly created `TaskRun` carries the right
    /// identity + mode before it is started.
    @MainActor
    func testCoordinatorTracksRunsPerTask() {
        let coordinator = TaskRunner()
        XCTAssertFalse(coordinator.isRunning(taskID: "001", in: "/p"))
        XCTAssertNil(coordinator.run(for: "001", in: "/p"))

        let run = TaskRun(taskID: "042", mode: .elaborate)
        XCTAssertEqual(run.taskID, "042")
        XCTAssertEqual(run.mode, .elaborate)
        XCTAssertFalse(run.isRunning)
    }

    // MARK: - Running-run accounting (task #044)

    /// The quit-confirmation hook (`applicationShouldTerminate`) queries
    /// `runningRunCount` / `hasRunningRuns` as its single source of truth for
    /// "are spinners running?". A fresh coordinator has no runs, so the count is
    /// zero and `hasRunningRuns` is false — the delegate must then terminate
    /// immediately without prompting. We assert only the empty case here because
    /// populating `runs` with an *actually running* `TaskRun` requires spawning a
    /// real `node` process; the helper is a trivial filter over `isRunning`, so
    /// the empty case plus the existing per-task tracking tests cover it.
    @MainActor
    func testRunningRunCountIsZeroForFreshCoordinator() {
        let coordinator = TaskRunner()
        XCTAssertEqual(coordinator.runningRunCount, 0)
        XCTAssertFalse(coordinator.hasRunningRuns)
    }

    // MARK: - Per-project run lookup

    @MainActor
    func testRunProjectPathIsNilBeforeStartForExistingTaskRun() {
        let run = TaskRun(taskID: "042", mode: .execute)
        XCTAssertNil(run.runProjectPath)
    }

    @MainActor
    func testRunProjectPathUsesCaptureProjectPath() {
        let run = TaskRun(taskID: "capture:/p:1", mode: .capture, description: "x", projectPath: "/p")
        XCTAssertEqual(run.runProjectPath, "/p")
    }

    @MainActor
    func testRunProjectPathUsesStartedPathForExecuteRun() {
        let run = TaskRun(taskID: "042", mode: .execute)
        run.markRunningForTesting(projectPath: "/proj")
        XCTAssertEqual(run.runProjectPath, "/proj")
    }

    @MainActor
    func testHasRunningRunInProjectMatchesOnlyLiveRunsInThatProject() {
        let coordinator = TaskRunner()
        let execute = TaskRun(taskID: "042", mode: .execute)
        execute.markRunningForTesting(projectPath: "/alpha")
        coordinator.ingestRunForTesting(execute)

        let capture = TaskRun(taskID: "capture:/beta:1", mode: .capture, description: "x", projectPath: "/beta")
        coordinator.ingestRunForTesting(capture)

        XCTAssertTrue(coordinator.hasRunningRun(inProject: "/alpha"))
        XCTAssertTrue(coordinator.hasRunningRun(inProject: "/alpha/"), "trailing slash is the same project")
        XCTAssertFalse(coordinator.hasRunningRun(inProject: "/beta"), "a not-yet-running capture is not in flight")
        XCTAssertFalse(coordinator.hasRunningRun(inProject: "/gamma"))
    }

    @MainActor
    func testHasRunningRunInProjectFalseAfterRunFinishes() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("run-outcomes.log")
        let coordinator = TaskRunner()
        let run = TaskRun(taskID: "043", mode: .elaborate, outcomeLog: RunOutcomeLog(fileURL: tmp))
        run.markRunningForTesting(projectPath: "/alpha")
        coordinator.ingestRunForTesting(run)
        XCTAssertTrue(coordinator.hasRunningRun(inProject: "/alpha"))

        run.finishForTesting()
        XCTAssertFalse(coordinator.hasRunningRun(inProject: "/alpha"))
        XCTAssertEqual(run.runProjectPath, "/alpha", "the path stays readable after finishing")
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

    // MARK: - Deep flag (#065)

    /// A `TaskRun` built with `deep: true` carries the flag on the run — this is
    /// exactly the stored property `TaskRun.spawn` reads to emit the valueless
    /// `--deep` argument. Asserted on the stored property rather than by spawning
    /// a process (mirroring the `usesTaskID`/`usesDescription` precedent, which
    /// verify arg shape via pure flags to avoid launching a real `node` run).
    @MainActor
    func testDeepRunCarriesDeepFlag() {
        let run = TaskRun(taskID: "042", mode: .elaborate, deep: true)
        XCTAssertTrue(run.deep)
    }

    /// `TaskRun.deep` defaults to false when the init param is omitted, so every
    /// existing call site (which never passes `deep`) is unaffected — no `--deep`
    /// is emitted for them.
    @MainActor
    func testDeepRunDefaultsToFalse() {
        let run = TaskRun(taskID: "042", mode: .elaborate)
        XCTAssertFalse(run.deep)
    }

    /// `deep` is ORTHOGONAL to `RunMode`: it composes with any mode rather than
    /// being a mode of its own, so `TaskRunner.captureMode(execute:elaborate:)`
    /// (which has no `deep` input) selects the same mode regardless. Deep is a
    /// separate valueless flag threaded through `TaskRun`, not a mode.
    func testDeepDoesNotAlterSelectedRunMode() {
        // captureMode has no `deep` parameter — the elaborate selection stands.
        XCTAssertEqual(TaskRunner.captureMode(execute: false, elaborate: true), .captureElaborate)
        XCTAssertEqual(TaskRunner.captureMode(execute: true, elaborate: true), .executeYolo)
        XCTAssertEqual(TaskRunner.captureMode(execute: false, elaborate: false), .capture)
    }

    // MARK: - Keep flag (#078)

    /// A `TaskRun` built with `keep: true` carries the flag on the run — this is
    /// exactly the stored property `TaskRun.spawn` reads to emit the valueless
    /// `--keep` argument. Asserted on the stored property rather than by spawning
    /// a process (mirroring the `usesTaskID`/`usesDescription` precedent, which
    /// verify arg shape via pure flags to avoid launching a real `node` run).
    @MainActor
    func testKeepRunCarriesKeepFlag() {
        let run = TaskRun(taskID: "042", mode: .execute, keep: true)
        XCTAssertTrue(run.keep)
    }

    /// `TaskRun.keep` defaults to false when the init param is omitted, so every
    /// existing call site (which never passes `keep`) is unaffected — no `--keep`
    /// is emitted for them.
    @MainActor
    func testKeepRunDefaultsToFalse() {
        let run = TaskRun(taskID: "042", mode: .execute)
        XCTAssertFalse(run.keep)
    }

    /// `keep` is ORTHOGONAL to `RunMode`: it composes with any mode rather than
    /// being a mode of its own, so `TaskRunner.captureMode(execute:elaborate:)`
    /// (which has no `keep` input) selects the same mode regardless. Keep is a
    /// separate valueless flag threaded through `TaskRun`, not a mode.
    func testKeepDoesNotAlterSelectedRunMode() {
        // captureMode has no `keep` parameter — the selection stands.
        XCTAssertEqual(TaskRunner.captureMode(execute: false, elaborate: true), .captureElaborate)
        XCTAssertEqual(TaskRunner.captureMode(execute: true, elaborate: true), .executeYolo)
        XCTAssertEqual(TaskRunner.captureMode(execute: false, elaborate: false), .capture)
    }

    // MARK: - Keep via the existing-task run path (#078, ExecuteModal)

    /// `ExecuteModal`'s submit path: `TaskRunner.run(... mode: .execute, keep: true)`
    /// must register a `TaskRun` that carries `keep`, since that stored property
    /// is exactly what `TaskRun.spawn` reads to emit the valueless `--keep`
    /// argument. This covers the `run(...)` entry point specifically — distinct
    /// from the `capture(...)` coverage above, which is the New Plan modal's
    /// brand-new-task path. Asserted on the registered run's stored properties
    /// rather than by inspecting a real process (the `testDeepRunCarriesDeepFlag`
    /// precedent — spawning a real `node` run is deliberately avoided).
    @MainActor
    func testExecuteRunViaRunCarriesKeepFlag() {
        let runner = TaskRunner()
        runner.run(projectPath: "/some/project", taskID: "078", mode: .execute, keep: true)

        let run = runner.run(for: "078", in: "/some/project")
        XCTAssertNotNil(run)
        XCTAssertEqual(run?.mode, .execute)
        XCTAssertEqual(run?.taskID, "078")
        XCTAssertEqual(run?.keep, true)
    }

    /// The sheet's no-regression path: submitting with Keep OFF must produce the
    /// byte-for-byte run the bare Execute button fired before #078 — `keep`
    /// false, so `spawn` omits `--keep` entirely and the launcher emits the
    /// unchanged `/plan-execute <id> worktree` command line.
    @MainActor
    func testExecuteRunViaRunOmitsKeepWhenFalse() {
        let runner = TaskRunner()
        runner.run(projectPath: "/some/project", taskID: "078", mode: .execute, keep: false)

        let run = runner.run(for: "078", in: "/some/project")
        XCTAssertNotNil(run)
        XCTAssertEqual(run?.mode, .execute)
        XCTAssertEqual(run?.keep, false)
        // No guidance channel exists for `.execute` — the sheet passes none.
        XCTAssertNil(run?.description)
    }

    /// `run(...)`'s `keep` parameter is DEFAULTED, so every pre-#078 call site
    /// (the other actions that still fire `run(...)` bare) keeps its exact
    /// argument shape — no `--keep`, no source change required.
    @MainActor
    func testExecuteRunViaRunDefaultsKeepToFalse() {
        let runner = TaskRunner()
        runner.run(projectPath: "/some/project", taskID: "078", mode: .execute)

        XCTAssertEqual(runner.run(for: "078", in: "/some/project")?.keep, false)
    }

    // MARK: - Optional elaborate guidance + Deep (#074)

    /// The Elaborate dialog's fullest submission: an `.elaborate` run carrying
    /// BOTH the user's optional free-text guidance AND `deep: true` retains each
    /// independently, so `TaskRun.spawn` emits `--task-id` + `--description` +
    /// the valueless `--deep` together. This is the composition #074 opened up —
    /// before it, `.elaborate` was id-only and the two channels could never be
    /// exercised at once. Asserted on the stored properties rather than by
    /// spawning a process (the `testDeepRunCarriesDeepFlag` precedent).
    @MainActor
    func testElaborateRunCarriesDescriptionAndDeepTogether() {
        let run = TaskRun(taskID: "074", mode: .elaborate,
                          description: "Focus on the offline path", deep: true)
        XCTAssertEqual(run.taskID, "074")
        XCTAssertEqual(run.mode, .elaborate)
        XCTAssertEqual(run.description, "Focus on the offline path")
        XCTAssertTrue(run.deep)
        XCTAssertFalse(run.isRunning)
    }

    /// The dialog's OTHER first-class path: submitting an empty guidance box maps
    /// to `nil` (not `""`), and the bare-elaborate run is byte-for-byte what the
    /// old button fired — a nil description and `deep` false. `spawn`'s
    /// `let description, !description.isEmpty` binding then omits `--description`
    /// entirely, so the pre-#074 arg shape is preserved for the common case.
    @MainActor
    func testBareElaborateRunHasNilDescriptionAndNoDeep() {
        let run = TaskRun(taskID: "074", mode: .elaborate)
        XCTAssertNil(run.description)
        XCTAssertFalse(run.deep)
    }

    /// Deep is orthogonal to guidance: an `.elaborate` run may go deep with NO
    /// description at all (ticking only the sheet's Deep box), and may carry
    /// guidance WITHOUT going deep. Pins that #074 did not accidentally couple
    /// the two dialog controls into a single flag.
    @MainActor
    func testElaborateDeepAndDescriptionAreIndependent() {
        // Deep only — no guidance typed.
        let deepOnly = TaskRun(taskID: "074", mode: .elaborate, deep: true)
        XCTAssertNil(deepOnly.description)
        XCTAssertTrue(deepOnly.deep)

        // Guidance only — Deep left off.
        let guidanceOnly = TaskRun(taskID: "074", mode: .elaborate,
                                   description: "Cover the retry case")
        XCTAssertEqual(guidanceOnly.description, "Cover the retry case")
        XCTAssertFalse(guidanceOnly.deep)
    }

    // MARK: - Direct-execute of pending plans (#088)

    /// #088 opened `.execute`'s description channel so the direct-Execute dialog's
    /// optional guidance can ride into the inline auto-elaboration pass. The pure
    /// `RunMode.usesDescription` flag is exactly what `TaskRun.spawn` consults to
    /// emit `--description`, so it MUST now report true for `.execute`. Asserted
    /// directly — no `node` process is spawned.
    func testExecuteUsesDescription() {
        XCTAssertTrue(RunMode.execute.usesDescription)
    }

    /// `PlanDetailView.canExecutePending` is the pure predicate behind the pending
    /// direct-Execute action's availability (#088). Available only for a
    /// `pending`, non-blocked, non-backlogged task — the same gate as
    /// `canElaborate`, and intentionally DISJOINT from `canWork` (which stays
    /// elaborated-only, preserving #027's in-progress exclusion). Asserted true for
    /// the one eligible shape and false for every other status, when blocked, and
    /// when backlogged.
    @MainActor
    func testCanExecutePendingGating() {
        // Pending, not blocked, not backlogged → available.
        XCTAssertTrue(PlanDetailView.canExecutePending(status: .pending, isBlocked: false))

        // Every non-pending status → unavailable (direct-execute only applies to
        // an un-elaborated, pending plan).
        XCTAssertFalse(PlanDetailView.canExecutePending(status: .elaborated, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canExecutePending(status: .inProgress, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canExecutePending(status: .review, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canExecutePending(status: .inReview, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canExecutePending(status: .completed, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canExecutePending(status: nil, isBlocked: false))

        // Blocked → unavailable even when pending.
        XCTAssertFalse(PlanDetailView.canExecutePending(status: .pending, isBlocked: true))

        // Backlogged → unavailable even when pending and non-blocked (a parked
        // plan must be restored before it can be driven).
        XCTAssertFalse(PlanDetailView.canExecutePending(status: .pending, isBlocked: false, isBacklogged: true))
    }

    /// `PlanDetailView.canExecuteReview` is the pure predicate behind the
    /// review-state "execute more" action's availability (#091). Available only
    /// for a plan in `review` or `inReview`, non-blocked and non-backlogged — the
    /// two statuses that mean an Execute run has finished and the result is awaiting
    /// the user's eye. Asserted true for both eligible shapes and false for every
    /// other status, when blocked, and when backlogged.
    @MainActor
    func testCanExecuteReviewGating() {
        // Both review states, not blocked, not backlogged → available.
        XCTAssertTrue(PlanDetailView.canExecuteReview(status: .review, isBlocked: false))
        XCTAssertTrue(PlanDetailView.canExecuteReview(status: .inReview, isBlocked: false))

        // Every non-review status → unavailable.
        XCTAssertFalse(PlanDetailView.canExecuteReview(status: .pending, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canExecuteReview(status: .elaborated, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canExecuteReview(status: .inProgress, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canExecuteReview(status: .completed, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canExecuteReview(status: nil, isBlocked: false))

        // Blocked → unavailable even in a review state.
        XCTAssertFalse(PlanDetailView.canExecuteReview(status: .review, isBlocked: true))
        XCTAssertFalse(PlanDetailView.canExecuteReview(status: .inReview, isBlocked: true))

        // Backlogged → unavailable even in a review state and non-blocked.
        XCTAssertFalse(PlanDetailView.canExecuteReview(status: .review, isBlocked: false, isBacklogged: true))
        XCTAssertFalse(PlanDetailView.canExecuteReview(status: .inReview, isBlocked: false, isBacklogged: true))
    }

    /// `PlanDetailView.canReElaborateReview` is the pure predicate behind the
    /// review-state "re-elaborate" action's availability (#091). It shares the
    /// SAME eligibility as `canExecuteReview`: a plan in `review` or `inReview`,
    /// non-blocked and non-backlogged. Asserted true for both eligible shapes and
    /// false for every other status, when blocked, and when backlogged.
    @MainActor
    func testCanReElaborateReviewGating() {
        // Both review states, not blocked, not backlogged → available.
        XCTAssertTrue(PlanDetailView.canReElaborateReview(status: .review, isBlocked: false))
        XCTAssertTrue(PlanDetailView.canReElaborateReview(status: .inReview, isBlocked: false))

        // Every non-review status → unavailable.
        XCTAssertFalse(PlanDetailView.canReElaborateReview(status: .pending, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canReElaborateReview(status: .elaborated, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canReElaborateReview(status: .inProgress, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canReElaborateReview(status: .completed, isBlocked: false))
        XCTAssertFalse(PlanDetailView.canReElaborateReview(status: nil, isBlocked: false))

        // Blocked → unavailable even in a review state.
        XCTAssertFalse(PlanDetailView.canReElaborateReview(status: .review, isBlocked: true))
        XCTAssertFalse(PlanDetailView.canReElaborateReview(status: .inReview, isBlocked: true))

        // Backlogged → unavailable even in a review state and non-blocked.
        XCTAssertFalse(PlanDetailView.canReElaborateReview(status: .review, isBlocked: false, isBacklogged: true))
        XCTAssertFalse(PlanDetailView.canReElaborateReview(status: .inReview, isBlocked: false, isBacklogged: true))
    }

    /// `ExecutePendingModal`'s submit path: `TaskRunner.run(... mode: .execute,
    /// description:, deep:, keep:)` must register a `TaskRun` that carries ALL
    /// THREE channels, since they are exactly what `TaskRun.spawn` reads to emit
    /// `--description`, the valueless `--deep`, and the valueless `--keep`. This
    /// covers the `run(...)` entry point (distinct from the composition test
    /// below), mirroring `testExecuteRunViaRunCarriesKeepFlag`. Asserted on the
    /// registered run's stored properties rather than by spawning a real process.
    @MainActor
    func testExecutePendingRunViaRunCarriesDescriptionDeepAndKeep() {
        let runner = TaskRunner()
        runner.run(projectPath: "/some/project", taskID: "088", mode: .execute,
                   description: "Prioritise the migration path", deep: true, keep: true)

        let run = runner.run(for: "088", in: "/some/project")
        XCTAssertNotNil(run)
        XCTAssertEqual(run?.mode, .execute)
        XCTAssertEqual(run?.taskID, "088")
        XCTAssertEqual(run?.description, "Prioritise the migration path")
        XCTAssertEqual(run?.deep, true)
        XCTAssertEqual(run?.keep, true)
    }

    /// The Re-Elaborate-Review dialog (#091) registers a `.reElaborateReview`
    /// run through `run(...)`, carrying optional guidance and `deep` the same way
    /// the pending-execute path does. Mirrors
    /// `testExecutePendingRunViaRunCarriesDescriptionDeepAndKeep`.
    @MainActor
    func testReElaborateReviewRunViaRunCarriesDescriptionAndDeep() {
        let runner = TaskRunner()
        runner.run(projectPath: "/some/project", taskID: "091",
                   mode: .reElaborateReview, description: "note", deep: true)

        let run = runner.run(for: "091", in: "/some/project")
        XCTAssertNotNil(run)
        XCTAssertEqual(run?.mode, .reElaborateReview)
        XCTAssertEqual(run?.taskID, "091")
        XCTAssertEqual(run?.description, "note")
        XCTAssertEqual(run?.deep, true)
    }

    /// The direct-Execute dialog's fullest submission at the `TaskRun` level: an
    /// `.execute` run carrying guidance AND `deep: true` AND `keep: true` retains
    /// each independently, so `spawn` emits `--task-id` + `--description` + the
    /// valueless `--deep` + the valueless `--keep` together. This is the
    /// composition #088 opened up — before it, `.execute` was id (+keep) only and
    /// could carry no guidance or deep. Mirrors
    /// `testElaborateRunCarriesDescriptionAndDeepTogether`.
    @MainActor
    func testExecuteRunCarriesDescriptionDeepAndKeepTogether() {
        let run = TaskRun(taskID: "088", mode: .execute,
                          description: "Honour the offline-first guidance",
                          deep: true, keep: true)
        XCTAssertEqual(run.taskID, "088")
        XCTAssertEqual(run.mode, .execute)
        XCTAssertEqual(run.description, "Honour the offline-first guidance")
        XCTAssertTrue(run.deep)
        XCTAssertTrue(run.keep)
        XCTAssertFalse(run.isRunning)
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

    // MARK: - Backlog / restore modes (#077 follow-up)

    /// `RunMode` is `String`-backed and the raw value IS the `--mode` flag handed
    /// to the Node runner, so both new modes must round-trip exactly — the
    /// runner's `parseArgs` rejects any `--mode` value it doesn't recognize.
    func testBacklogAndRestoreModesRoundTripRawValues() {
        XCTAssertEqual(RunMode.backlog.rawValue, "backlog")
        XCTAssertEqual(RunMode(rawValue: "backlog"), .backlog)

        XCTAssertEqual(RunMode.restore.rawValue, "restore")
        XCTAssertEqual(RunMode(rawValue: "restore"), .restore)
    }

    /// Both modes operate on an EXISTING task identified by id alone (they just
    /// move its file between `pending/` and `backlog/`), so they pass
    /// `--task-id` and carry no free text — the same arg shape as `.delete`.
    func testBacklogAndRestoreUseTaskIDWithoutDescription() {
        XCTAssertTrue(RunMode.backlog.usesTaskID)
        XCTAssertTrue(RunMode.restore.usesTaskID)

        XCTAssertFalse(RunMode.backlog.usesDescription)
        XCTAssertFalse(RunMode.restore.usesDescription)
    }

    /// A `.backlog` / `.restore` run is keyed by the real task id (not a
    /// synthetic capture identity) and carries no description.
    @MainActor
    func testBacklogAndRestoreRunsCarryTaskIDAndNoDescription() {
        let backlogRun = TaskRun(taskID: "077", mode: .backlog)
        XCTAssertEqual(backlogRun.taskID, "077")
        XCTAssertEqual(backlogRun.mode, .backlog)
        XCTAssertNil(backlogRun.description)
        XCTAssertFalse(backlogRun.isRunning)

        let restoreRun = TaskRun(taskID: "077", mode: .restore)
        XCTAssertEqual(restoreRun.mode, .restore)
        XCTAssertNil(restoreRun.description)
        XCTAssertFalse(restoreRun.isRunning)
    }

    /// `RunMode.usesDescription` is the pure flag `TaskRun.spawn` consults to pass
    /// `--description <text>`: true for the three description-driven modes
    /// (`.capture`, `.captureElaborate`, `.executeYolo`), the two existing-task
    /// modes that can carry guidance (`.reElaborate`, `.elaborate`), AND — since
    /// #088 — `.execute`, whose description is OPTIONAL (it carries the direct-
    /// execute dialog's guidance folded into an inline elaboration pass); false
    /// for `.delete`, which is fully identified by its task id alone. Asserting it
    /// directly verifies the description wiring without spawning a real `node`
    /// process.
    func testRunModeUsesDescriptionFlag() {
        XCTAssertTrue(RunMode.capture.usesDescription)
        XCTAssertTrue(RunMode.captureElaborate.usesDescription)
        XCTAssertTrue(RunMode.executeYolo.usesDescription)
        // reElaborate is the hybrid: it carries a description alongside its id.
        XCTAssertTrue(RunMode.reElaborate.usesDescription)
        // elaborate opens the same channel, but its description is OPTIONAL —
        // the flag only says `spawn` MAY emit `--description`, and it does so
        // solely when a non-empty one was actually supplied.
        XCTAssertTrue(RunMode.elaborate.usesDescription)
        // #088: execute now opens the same OPTIONAL channel — the direct-Execute
        // dialog's guidance rides it into the inline auto-elaboration pass.
        XCTAssertTrue(RunMode.execute.usesDescription)
        // #091: re-elaborating a review-state plan resets it to pending and
        // re-elaborates it, carrying the user's free-text guidance.
        XCTAssertTrue(RunMode.reElaborateReview.usesDescription)

        // delete names an EXISTING task by id; there is no free text to pass.
        XCTAssertFalse(RunMode.delete.usesDescription)
    }

    /// `RunMode.usesTaskID` is the pure flag `TaskRun.spawn` consults to pass
    /// `--task-id <id>`: true for the existing-task modes (`.execute`,
    /// `.elaborate`, `.reElaborate`, `.delete`), false for the description-driven
    /// modes (`.capture`, `.captureElaborate`, `.executeYolo`) whose task does not
    /// exist yet. Asserting it directly verifies the arg-shape split without
    /// spawning a real `node` process.
    func testRunModeUsesTaskIDFlag() {
        XCTAssertTrue(RunMode.execute.usesTaskID)
        XCTAssertTrue(RunMode.elaborate.usesTaskID)
        XCTAssertTrue(RunMode.reElaborate.usesTaskID)
        // #091: re-elaborating a review-state plan names that EXISTING task by id.
        XCTAssertTrue(RunMode.reElaborateReview.usesTaskID)
        // delete targets an existing task file, so it is id-addressed too.
        XCTAssertTrue(RunMode.delete.usesTaskID)

        XCTAssertFalse(RunMode.capture.usesTaskID)
        XCTAssertFalse(RunMode.captureElaborate.usesTaskID)
        XCTAssertFalse(RunMode.executeYolo.usesTaskID)
    }

    // MARK: - Child environment (#084)

    /// A Dock-launched app inherits launchd's bare PATH, so `spawn` hands the
    /// child an explicit environment built by the pure
    /// `TaskRun.buildChildEnvironment`. The login-shell PATH replaces the base
    /// PATH; every other inherited key rides along untouched.
    func testChildEnvironmentReplacesPathAndKeepsOtherKeys() {
        let base = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": "/Users/me",
            "USER": "me",
            "TMPDIR": "/var/folders/xx/T/",
        ]
        let env = TaskRun.buildChildEnvironment(
            base: base,
            loginPath: "/opt/homebrew/bin:/usr/bin:/bin",
            nodePath: "/opt/homebrew/bin/node"
        )
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/bin:/bin")
        XCTAssertEqual(env["HOME"], "/Users/me")
        XCTAssertEqual(env["USER"], "me")
        XCTAssertEqual(env["TMPDIR"], "/var/folders/xx/T/")
    }

    /// With no login PATH (shell failed or timed out), the fallback is node's
    /// own directory, then the common Homebrew prefixes, then the base PATH —
    /// with duplicates dropped (first occurrence wins).
    func testChildEnvironmentFallsBackWhenLoginPathMissing() {
        let base = ["PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": "/Users/me"]
        let nodePath = "/Users/me/.nvm/versions/node/v22.0.0/bin/node"
        let expected = [
            "/Users/me/.nvm/versions/node/v22.0.0/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ].joined(separator: ":")

        for loginPath in [nil, "", "   \n"] as [String?] {
            let env = TaskRun.buildChildEnvironment(
                base: base, loginPath: loginPath, nodePath: nodePath)
            XCTAssertEqual(env["PATH"], expected, "loginPath=\(String(describing: loginPath))")
            XCTAssertEqual(env["HOME"], "/Users/me")
        }
    }

    /// The fallback still works when node itself is unknown and the base has
    /// no PATH at all.
    func testChildEnvironmentFallbackWithoutNodeOrBasePath() {
        let env = TaskRun.buildChildEnvironment(base: [:], loginPath: nil, nodePath: nil)
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/local/bin")
    }

    /// Node's directory goes first when the login PATH lacks it (e.g. nvm is
    /// only initialized in an interactive rc file) so `#!/usr/bin/env node`
    /// shebangs like `npx`'s resolve to the same node the runner uses.
    func testChildEnvironmentPrependsNodeDirWhenMissingFromLoginPath() {
        let env = TaskRun.buildChildEnvironment(
            base: ["PATH": "/usr/bin:/bin"],
            loginPath: "/usr/local/bin:/usr/bin:/bin",
            nodePath: "/Users/me/.nvm/versions/node/v22.0.0/bin/node"
        )
        XCTAssertEqual(
            env["PATH"],
            "/Users/me/.nvm/versions/node/v22.0.0/bin:/usr/local/bin:/usr/bin:/bin"
        )
    }

    /// When the login PATH already contains node's directory it is left as-is
    /// (not moved to the front, not duplicated).
    func testChildEnvironmentLeavesLoginPathWhenNodeDirPresent() {
        let env = TaskRun.buildChildEnvironment(
            base: [:],
            loginPath: "/usr/bin:/opt/homebrew/bin:/bin",
            nodePath: "/opt/homebrew/bin/node"
        )
        XCTAssertEqual(env["PATH"], "/usr/bin:/opt/homebrew/bin:/bin")
    }

    /// The login-shell lookup prints marked `__NODE__`/`__PATH__` lines; profile
    /// scripts may print arbitrary noise (including lines that look similar).
    /// The parser keeps only the LAST marked line of each kind.
    func testParseLoginShellOutputTakesLastMarkedLinesAndIgnoresNoise() {
        let output = """
        Welcome back! Last login: today
        __NODE__/usr/bin/stale-node
        some rc noise __PATH__not-a-marker
        __NODE__/opt/homebrew/bin/node
        __PATH__/early:/path
        more noise
        __PATH__/opt/homebrew/bin:/usr/bin:/bin

        """
        let parsed = TaskRun.parseLoginShellOutput(output)
        XCTAssertEqual(parsed.nodePath, "/opt/homebrew/bin/node")
        XCTAssertEqual(parsed.path, "/opt/homebrew/bin:/usr/bin:/bin")
    }

    /// `command -v node` prints nothing when node isn't installed, so there is
    /// no `__NODE__` line: node is nil but the PATH is still returned.
    func testParseLoginShellOutputToleratesMissingNodeLine() {
        let parsed = TaskRun.parseLoginShellOutput("noise\n__PATH__/usr/bin:/bin\n")
        XCTAssertNil(parsed.nodePath)
        XCTAssertEqual(parsed.path, "/usr/bin:/bin")
    }

    /// Empty marked values (and empty output) parse to nil, not "".
    func testParseLoginShellOutputTreatsEmptyValuesAsNil() {
        let parsed = TaskRun.parseLoginShellOutput("__NODE__\n__PATH__  \n")
        XCTAssertNil(parsed.nodePath)
        XCTAssertNil(parsed.path)
        let empty = TaskRun.parseLoginShellOutput("")
        XCTAssertNil(empty.nodePath)
        XCTAssertNil(empty.path)
    }

    /// A stderr chunk is split into trimmed, non-empty lines for logging.
    /// Blank lines and surrounding whitespace are dropped.
    func testStderrLogLinesSplitsAndTrimsChunk() {
        let chunk = Data("  first error  \n\n\tsecond line\r\n   \n".utf8)
        XCTAssertEqual(TaskRun.stderrLogLines(from: chunk), ["first error", "second line"])
    }

    /// An empty or whitespace-only chunk yields no lines to log.
    func testStderrLogLinesIgnoresBlankChunk() {
        XCTAssertEqual(TaskRun.stderrLogLines(from: Data()), [])
        XCTAssertEqual(TaskRun.stderrLogLines(from: Data(" \n\t\n".utf8)), [])
    }

    /// Bytes that aren't valid UTF-8 are decoded lossily, not dropped, so a
    /// partial multi-byte sequence split across chunks still gets logged.
    func testStderrLogLinesDecodesInvalidUTF8Lossily() {
        var chunk = Data("bad ".utf8)
        chunk.append(0xFF)
        let lines = TaskRun.stderrLogLines(from: chunk)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("bad"))
    }

    /// `.reElaborate` is the mode that REQUIRES both arg flags: it refines an
    /// EXISTING already-elaborated task (so `spawn` emits `--task-id`) using the
    /// user's free-text guidance (so `spawn` also emits `--description`). The two
    /// flags are independent — this is the hybrid that proves they are not an
    /// either/or (`.elaborate` is the other both-true mode, but its description is
    /// optional). It round-trips its raw value (the `--mode` flag) too.
    func testReElaborateModeUsesBothTaskIDAndDescription() {
        XCTAssertEqual(RunMode.reElaborate.rawValue, "reElaborate")
        XCTAssertEqual(RunMode(rawValue: "reElaborate"), .reElaborate)

        XCTAssertTrue(RunMode.reElaborate.usesTaskID)
        XCTAssertTrue(RunMode.reElaborate.usesDescription)
    }

    /// `.elaborate` is the OTHER both-flags-true mode (#074), and the only one
    /// where the description is OPTIONAL rather than required: it always names an
    /// existing pending task (`--task-id`) and MAY carry the dialog's free-text
    /// guidance (`--description`). `usesDescription` opens the channel; whether
    /// the flag is actually emitted is decided per-run by `spawn`'s non-nil,
    /// non-empty check — which is why a bare elaborate still spawns id-only. Its
    /// raw value is the literal `run-task.ts` switches on for its `--mode` flag,
    /// so the round-trip pins the Swift-TypeScript contract against that file's
    /// `elaborate` branch (which now returns `description` too).
    func testElaborateModeUsesTaskIDAndOptionalDescription() {
        XCTAssertEqual(RunMode.elaborate.rawValue, "elaborate")
        XCTAssertEqual(RunMode(rawValue: "elaborate"), .elaborate)

        XCTAssertTrue(RunMode.elaborate.usesTaskID)
        XCTAssertTrue(RunMode.elaborate.usesDescription)
    }

    /// `.delete` is id-only: it names an EXISTING task (so `spawn` emits
    /// `--task-id`) and carries no free text (so no `--description`). Its raw
    /// value is the literal the runner switches on for its `--mode` flag, so the
    /// round-trip pins the Swift↔TypeScript contract with
    /// `Tools/work-task/run-task.ts`'s `"delete"` branch — a rename on either
    /// side would otherwise fail only at runtime.
    func testDeleteModeIsTaskIDOnlyAndRoundTripsRawValue() {
        XCTAssertEqual(RunMode.delete.rawValue, "delete")
        XCTAssertEqual(RunMode(rawValue: "delete"), .delete)

        XCTAssertTrue(RunMode.delete.usesTaskID)
        XCTAssertFalse(RunMode.delete.usesDescription)
    }

    /// `.discuss` (#099) is a both-flags-true mode, modeled exactly on
    /// `.reElaborate`: it works an EXISTING task (so `spawn` emits `--task-id`)
    /// AND carries the user's free-text question (so `spawn` also emits
    /// `--description`), driving the `plan-discuss` skill. Its raw value is the
    /// literal the runner switches on for its `--mode` flag, so the round-trip
    /// pins the Swift↔TypeScript contract against `run-task.ts`'s `"discuss"`
    /// branch — a rename on either side would otherwise fail only at runtime.
    func testDiscussModeUsesBothTaskIDAndDescription() {
        XCTAssertEqual(RunMode.discuss.rawValue, "discuss")
        XCTAssertEqual(RunMode(rawValue: "discuss"), .discuss)

        XCTAssertTrue(RunMode.discuss.usesTaskID)
        XCTAssertTrue(RunMode.discuss.usesDescription)
    }

    /// A `.reElaborate` run carries BOTH an existing task id and the free-text
    /// refinement `description` (threaded to the runner's `--description` flag),
    /// so `TaskRun.spawn` can emit `--task-id <id>` and `--description <text>`
    /// together. It is not running until started.
    @MainActor
    func testReElaborateRunCarriesTaskIDAndDescription() {
        let run = TaskRun(taskID: "056", mode: .reElaborate, description: "Cover the offline case")
        XCTAssertEqual(run.taskID, "056")
        XCTAssertEqual(run.mode, .reElaborate)
        XCTAssertEqual(run.description, "Cover the offline case")
        XCTAssertFalse(run.isRunning)
    }

    /// The Refine dialog's fullest submission (#075): a `.reElaborate` run may go
    /// deep, carrying its refinement `description` AND `deep: true` independently,
    /// so `TaskRun.spawn` emits `--task-id` + `--description` + the valueless
    /// `--deep` together. `deep` composes orthogonally with `.reElaborate` — this
    /// codifies the contract the sheet's new Deep checkbox relies on. Asserted on
    /// the stored properties rather than by spawning a process (the
    /// `testDeepRunCarriesDeepFlag` precedent).
    @MainActor
    func testReElaborateRunCarriesDeepFlag() {
        let run = TaskRun(taskID: "075", mode: .reElaborate,
                          description: "Cover the offline case", deep: true)
        XCTAssertEqual(run.mode, .reElaborate)
        XCTAssertTrue(run.deep)
        XCTAssertEqual(run.description, "Cover the offline case")
        XCTAssertFalse(run.isRunning)
    }

    /// The common Refine path leaves the Deep box unticked: a `.reElaborate` run
    /// built WITHOUT `deep:` defaults `deep` to false, so `spawn` omits `--deep`
    /// and the pre-#075 arg shape is preserved.
    @MainActor
    func testReElaborateRunDefaultsDeepToFalse() {
        let run = TaskRun(taskID: "075", mode: .reElaborate, description: "Cover the offline case")
        XCTAssertFalse(run.deep)
    }

    // MARK: - Hand-off reconciliation (task #051)

    /// Builds a bare `Task` fixture (only `id` matters for reconciliation, which
    /// matches on task ids appearing in a project).
    private func makeTask(id: String) -> Task {
        Task(
            id: id,
            title: nil,
            type: nil,
            status: nil,
            created: nil,
            branch: nil,
            isKeptWorktree: false,
            blockedBy: [],
            sections: [],
            howProgress: (done: 0, total: 0),
            isBlocked: false,
            isCompletedDir: false,
            isBacklogged: false
        )
    }

    /// Builds a `ProjectTasks` fixture with the given task ids for `projectPath`.
    private func makeProject(path: String, taskIDs: [String]) -> ProjectTasks {
        ProjectTasks(
            projectPath: path,
            projectName: (path as NSString).lastPathComponent,
            lastSeen: "",
            tasks: taskIDs.map { makeTask(id: $0) },
            counts: [:],
            activeTasks: [],
            gitBranch: nil,
            gitIsDirty: nil
        )
    }

    /// Builds a FINISHED (not running) capture run for `projectPath` with the
    /// given reconciliation baseline. A fresh `TaskRun` has `isRunning == false`
    /// (it only flips true inside `start()`, which spawns a process), so this is
    /// exactly the "finished capture awaiting its plan row" state reconciliation
    /// participates in — without spawning `node`.
    @MainActor
    private func makeFinishedCapture(
        path: String,
        baseline: Set<String>,
        id: String = "capture:/p:" + UUID().uuidString
    ) -> TaskRun {
        TaskRun(taskID: id, mode: .capture, description: "Add a thing",
                projectPath: path, baselineTaskIDs: baseline)
    }

    /// (#117) A finished capture whose single new id is now known MIGRATES to the
    /// real task id (carrying its agent + transcript) rather than being dropped,
    /// so the placeholder dock's history follows the plan. It is therefore in
    /// `toMigrate`, not `toDismiss`.
    @MainActor
    func testFinishedCaptureMigratesWhenNewTaskIDAppears() {
        let run = makeFinishedCapture(path: "/p", baseline: ["001", "002"])
        let projects = [makeProject(path: "/p", taskIDs: ["001", "002", "003"])]

        let decision = TaskRunner.reconcile(
            runs: [run.taskID: run], projects: projects
        )
        XCTAssertEqual(decision.toMigrate[run.taskID], "003")
        XCTAssertFalse(decision.toDismiss.contains(run.taskID))
    }

    /// (#117, instance-method seam) Driving the full `ingestRunForTesting` →
    /// `reconcileFinishedCaptures` path MIGRATES a finished capture's agent to the
    /// real task id once the new plan appears: the synthetic placeholder row is
    /// gone, and the real plan's run (the migrated, finished capture run) is now
    /// resolvable under `project/realID` — so its transcript follows the plan.
    @MainActor
    func testReconcileMigratesFinishedCaptureWhenNewPlanAppears() {
        let runner = TaskRunner()
        let run = makeFinishedCapture(path: "/p", baseline: ["001"])
        runner.ingestRunForTesting(run)

        // Before reconciliation the row is visible (a finished-but-not-yet-
        // reconciled capture is still returned).
        XCTAssertEqual(runner.runningCaptures(projectPath: "/p").map(\.taskID),
                       [run.taskID])

        runner.reconcileFinishedCaptures(
            against: [makeProject(path: "/p", taskIDs: ["001", "002"])]
        )

        // The new id (002) appeared → the agent migrated → the synthetic row is
        // gone, and the run (now re-keyed to 002) is resolvable at the real key.
        XCTAssertTrue(runner.runningCaptures(projectPath: "/p").isEmpty)
        XCTAssertNotNil(runner.run(for: "002", in: "/p"))
        XCTAssertEqual(runner.run(for: "002", in: "/p")?.taskID, "002")
    }

    /// (Step 6.2) Only FINISHED capture runs participate. `isRunning` cannot be
    /// forced true in a unit test (it flips only inside `start()`, which spawns a
    /// `node` process — deliberately avoided here, mirroring the file's other
    /// limitation notes). We instead assert the documented contract from the
    /// other side: a run that is `isRunning == false` but whose project shows NO
    /// new id is NOT dismissed on the first pass (so a still-creating row would
    /// likewise survive), and the pure helper's `guard !run.isRunning` is the
    /// only gate — verified by the new-id case above firing and this no-new-id
    /// case not firing. A run still in flight (were one constructible) would hit
    /// the `guard !run.isRunning` continue and be excluded identically.
    @MainActor
    func testNoNewTaskIDIsNotDismissedOnFirstPass() {
        let run = makeFinishedCapture(path: "/p", baseline: ["001", "002"])
        // Project is unchanged from the baseline — no new id appeared yet.
        let projects = [makeProject(path: "/p", taskIDs: ["001", "002"])]

        let toDismiss = TaskRunner.taskIDsToDismiss(
            runs: [run.taskID: run], projects: projects
        )
        XCTAssertFalse(toDismiss.contains(run.taskID))
        // One fruitless pass advanced the bounded-fallback counter (documented
        // side effect of the pure helper).
        XCTAssertEqual(run.reconcileAttempts, 1)
    }

    /// (Step 6.3) Back-to-back captures for ONE project resolve independently.
    /// Two finished captures with DIFFERENT baselines: runA started when only
    /// "001" existed; runB started after "002" was already captured. When "002"
    /// appears in the project, ONLY runA (whose baseline lacks "002") is
    /// dismissed — runB, whose baseline already contained "002", sees no NEW id
    /// and is left alone (no cross-dismiss). Per-run isolation comes from each
    /// carrying its own baseline.
    @MainActor
    func testBackToBackCapturesResolveIndependently() {
        let runA = makeFinishedCapture(path: "/p", baseline: ["001"],
                                       id: "capture:/p:A")
        let runB = makeFinishedCapture(path: "/p", baseline: ["001", "002"],
                                       id: "capture:/p:B")
        let projects = [makeProject(path: "/p", taskIDs: ["001", "002"])]

        let decision = TaskRunner.reconcile(
            runs: [runA.taskID: runA, runB.taskID: runB], projects: projects
        )

        // runA's plan ("002") landed → it MIGRATES to 002 (#117); runB, whose
        // baseline already had 002, sees no new id and is neither migrated nor
        // dismissed (no cross-dismiss).
        XCTAssertEqual(decision.toMigrate[runA.taskID], "002")
        XCTAssertNil(decision.toMigrate[runB.taskID])
        XCTAssertFalse(decision.toDismiss.contains(runA.taskID))
        XCTAssertFalse(decision.toDismiss.contains(runB.taskID))
    }

    /// (Step 6.4) A finished capture that never observes a new id is NOT
    /// dismissed prematurely (passes 1 and 2 leave it pinned), but the bounded
    /// fallback DOES eventually clear it on the `maxReconcileAttempts`-th pass so
    /// the spinner row can never get stuck forever (e.g. the run failed before
    /// writing a plan).
    @MainActor
    func testBoundedFallbackDismissesAfterMaxAttempts() {
        let run = makeFinishedCapture(path: "/p", baseline: ["001"])
        // Project NEVER gains a new id.
        let projects = [makeProject(path: "/p", taskIDs: ["001"])]
        let runs = [run.taskID: run]

        // Passes before the ceiling: not dismissed, counter advancing.
        for pass in 1..<TaskRun.maxReconcileAttempts {
            let toDismiss = TaskRunner.taskIDsToDismiss(runs: runs, projects: projects)
            XCTAssertFalse(toDismiss.contains(run.taskID),
                           "should not dismiss before the ceiling (pass \(pass))")
            XCTAssertEqual(run.reconcileAttempts, pass)
        }

        // The ceiling pass dismisses it anyway.
        let final = TaskRunner.taskIDsToDismiss(runs: runs, projects: projects)
        XCTAssertEqual(run.reconcileAttempts, TaskRun.maxReconcileAttempts)
        XCTAssertTrue(final.contains(run.taskID))
    }

    /// (Step 6.4, instance-method seam) The same bounded fallback driven through
    /// `reconcileFinishedCaptures` actually removes the run from `runs` once the
    /// ceiling is hit, so a never-resolving spinner row eventually clears.
    @MainActor
    func testReconcileBoundedFallbackClearsRowAfterMaxAttempts() {
        let runner = TaskRunner()
        let run = makeFinishedCapture(path: "/p", baseline: ["001"])
        runner.ingestRunForTesting(run)
        let projects = [makeProject(path: "/p", taskIDs: ["001"])]

        for _ in 0..<TaskRun.maxReconcileAttempts {
            runner.reconcileFinishedCaptures(against: projects)
        }
        XCTAssertTrue(runner.runningCaptures(projectPath: "/p").isEmpty)
        XCTAssertNil(runner.run(for: run.taskID, in: "/p"))
    }

    /// (Step 6.5) Step-4 visibility: a finished-but-not-yet-dismissed capture is
    /// returned by `runningCaptures(projectPath:)` (so the spinner row persists
    /// across the hand-off window), and disappears exactly when `dismiss` removes
    /// it from `runs`. Uses the `ingestRunForTesting` seam to place a finished
    /// run without spawning `node`.
    @MainActor
    func testRunningCapturesReturnsFinishedRunUntilDismissed() {
        let runner = TaskRunner()
        let run = makeFinishedCapture(path: "/p", baseline: ["001"],
                                      id: "capture:/p:" + UUID().uuidString)
        runner.ingestRunForTesting(run)

        // Finished (isRunning == false) but still in the map → still visible.
        XCTAssertFalse(run.isRunning)
        XCTAssertEqual(runner.runningCaptures(projectPath: "/p").map(\.taskID),
                       [run.taskID])

        // dismiss removes it (it is finished + present) → row gone.
        runner.dismiss(taskID: run.taskID, in: "/p")
        XCTAssertTrue(runner.runningCaptures(projectPath: "/p").isEmpty)
    }

    /// (#103 pinning) The capture-row SOURCE the project card reads — and the
    /// single-project task list currently lacks — is exactly
    /// `runningCaptures(projectPath:)`: an in-flight capture surfaces here even
    /// though the project has NO parsed task yet (the capture has no `.plans/`
    /// file, only its synthetic `capture:<path>:<uuid>` run). This pins the
    /// Diagnosis before the fix wires the same source into `TaskListView`.
    @MainActor
    func testRunningCapturesReturnsInFlightCaptureForProjectWithNoParsedTask() {
        let runner = TaskRunner()
        let run = makeRunningCapture(path: "/p", baseline: [],
                                     id: "capture:/p:" + UUID().uuidString)
        runner.ingestRunForTesting(run)

        // The capture is in flight; the project has no parsed task (empty
        // baseline, no on-disk plan) — yet the card's row source still returns
        // it, which is the surface `TaskListView` does not consult.
        XCTAssertTrue(run.isRunning)
        XCTAssertEqual(runner.runningCaptures(projectPath: "/p").map(\.taskID),
                       [run.taskID])
    }

    /// (Step 5) The manual popover-dismiss path and reconciliation do not fight:
    /// `dismiss(taskID:in:)` is idempotent. (a) Reconciliation dismissing first,
    /// then a later manual `dismiss` (popover `onDisappear`) is a safe no-op —
    /// the run is already gone. (b) A manual dismiss BEFORE reconciliation simply
    /// removes the run early, and the next reconcile pass finds nothing to do.
    @MainActor
    func testManualDismissAndReconcileAreIdempotent() {
        // (a) reconcile-then-manual: the capture MIGRATES to its real id (#117),
        // so the synthetic row is gone; a later manual dismiss of the (now
        // vanished) synthetic key is a safe no-op.
        let runnerA = TaskRunner()
        let runA = makeFinishedCapture(path: "/p", baseline: ["001"])
        let syntheticA = runA.taskID
        runnerA.ingestRunForTesting(runA)
        runnerA.reconcileFinishedCaptures(
            against: [makeProject(path: "/p", taskIDs: ["001", "002"])]
        )
        // The synthetic placeholder is gone; the migrated run lives at the real id.
        XCTAssertNil(runnerA.run(for: syntheticA, in: "/p"))
        XCTAssertNotNil(runnerA.run(for: "002", in: "/p"))
        runnerA.dismiss(taskID: syntheticA, in: "/p")  // manual popover close, already gone
        XCTAssertNil(runnerA.run(for: syntheticA, in: "/p"))

        // (b) manual-then-reconcile: early manual dismiss removes the finished
        // capture before any new id appears, so the next reconcile finds nothing.
        let runnerB = TaskRunner()
        let runB = makeFinishedCapture(path: "/p", baseline: ["001"])
        let syntheticB = runB.taskID
        runnerB.ingestRunForTesting(runB)
        runnerB.dismiss(taskID: syntheticB, in: "/p")  // user closes popover first
        XCTAssertNil(runnerB.run(for: syntheticB, in: "/p"))
        // Next reconcile pass: the run is gone, so it is a clean no-op (and the
        // new id can't migrate a vanished agent).
        runnerB.reconcileFinishedCaptures(
            against: [makeProject(path: "/p", taskIDs: ["001", "002"])]
        )
        XCTAssertNil(runnerB.run(for: syntheticB, in: "/p"))
        XCTAssertNil(runnerB.run(for: "002", in: "/p"))
    }

    // MARK: - Errored captures persist until manual dismissal

    /// Builds a finished capture run that ENDED IN ERROR (e.g. the launcher's
    /// API call failed before any task was written), with its outcome log
    /// pointed at a throwaway temp file so the test never touches the real
    /// `~/.claude/plans-cc/run-outcomes.log`.
    @MainActor
    private func makeErroredCapture(
        path: String,
        baseline: Set<String>,
        id: String = "capture:/p:" + UUID().uuidString
    ) -> TaskRun {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("run-outcomes.log")
        let run = TaskRun(taskID: id, mode: .captureElaborate,
                          description: "Add a thing", projectPath: path,
                          baselineTaskIDs: baseline,
                          outcomeLog: RunOutcomeLog(fileURL: tmp))
        run.finishForTesting(projectPath: path, error: "API Error: 400")
        return run
    }

    /// A capture that finished with an error must NOT be cleared by the bounded
    /// reconcile fallback — auto-dismissal is exactly what made failed captures
    /// vanish before the user could see the error. The counter must not even
    /// advance: an errored run does not participate in the fallback at all.
    @MainActor
    func testErroredCaptureIsNotDismissedByBoundedFallback() {
        let run = makeErroredCapture(path: "/p", baseline: ["001"])
        // Project never gains a new id (the failed run wrote no task).
        let projects = [makeProject(path: "/p", taskIDs: ["001"])]
        let runs = [run.taskID: run]

        for pass in 1...(TaskRun.maxReconcileAttempts + 1) {
            let toDismiss = TaskRunner.taskIDsToDismiss(runs: runs, projects: projects)
            XCTAssertFalse(toDismiss.contains(run.taskID),
                           "errored capture must survive pass \(pass)")
        }
        XCTAssertEqual(run.reconcileAttempts, 0)
    }

    /// Even when a NEW task id appears (e.g. captureElaborate wrote the plan and
    /// then errored during elaboration), an errored capture row is kept so the
    /// error is surfaced — the new-id hand-off only auto-dismisses clean runs.
    @MainActor
    func testErroredCaptureIsNotDismissedWhenNewTaskIDAppears() {
        let run = makeErroredCapture(path: "/p", baseline: ["001"])
        let projects = [makeProject(path: "/p", taskIDs: ["001", "002"])]

        let toDismiss = TaskRunner.taskIDsToDismiss(
            runs: [run.taskID: run], projects: projects
        )
        XCTAssertFalse(toDismiss.contains(run.taskID))
    }

    /// Instance-seam proof of the full contract: reconcile passes leave an
    /// errored capture's row visible (`runningCaptures` still returns it), and
    /// only the manual popover-dismiss path clears it.
    @MainActor
    func testErroredCaptureRemainsVisibleUntilManualDismiss() {
        let runner = TaskRunner()
        let run = makeErroredCapture(path: "/p", baseline: ["001"])
        runner.ingestRunForTesting(run)
        let projects = [makeProject(path: "/p", taskIDs: ["001"])]

        for _ in 0...(TaskRun.maxReconcileAttempts + 1) {
            runner.reconcileFinishedCaptures(against: projects)
        }
        XCTAssertEqual(runner.runningCaptures(projectPath: "/p").map(\.taskID),
                       [run.taskID])

        runner.dismiss(taskID: run.taskID, in: "/p")
        XCTAssertTrue(runner.runningCaptures(projectPath: "/p").isEmpty)
    }

    // MARK: - Hand-off re-key (task #053)

    /// Builds a RUNNING capture run for `projectPath` with the given baseline.
    /// Mirrors `makeFinishedCapture` but flips the run live via the DEBUG
    /// `markRunningForTesting()` seam so the re-key path (which only fires for a
    /// STILL-RUNNING capture) is exercised without spawning `node`.
    @MainActor
    private func makeRunningCapture(
        path: String,
        baseline: Set<String>,
        id: String = "capture:/p:" + UUID().uuidString
    ) -> TaskRun {
        let run = TaskRun(taskID: id, mode: .capture, description: "Add a thing",
                          projectPath: path, baselineTaskIDs: baseline)
        run.markRunningForTesting()
        return run
    }

    /// A still-running capture whose project gained a new task id is RE-KEYED
    /// (not dismissed): the live run moves from its synthetic key to the real
    /// task id so the spinner hands off to the real plan row while the process
    /// keeps running.
    @MainActor
    func testRunningCaptureRekeysToNewTaskID() {
        let run = makeRunningCapture(path: "/p", baseline: ["001"])
        let projects = [makeProject(path: "/p", taskIDs: ["001", "002"])]

        let decision = TaskRunner.reconcile(
            runs: [run.taskID: run], projects: projects
        )
        XCTAssertEqual(decision.toRekey, [run.taskID: "002"])
        XCTAssertTrue(decision.toDismiss.isEmpty)
    }

    /// Driving the instance-method path re-keys the live run IN PLACE: the same
    /// object instance is now reachable under the real id, `isRunning(taskID:in:)`
    /// is true for the real id, the synthetic capture row is gone, the live
    /// process still counts toward `runningRunCount`, and the synthetic key no
    /// longer resolves.
    @MainActor
    func testReconcileRekeysRunningCaptureInMap() {
        let runner = TaskRunner()
        let run = makeRunningCapture(path: "/p", baseline: ["001"])
        let syntheticKey = run.taskID
        runner.ingestRunForTesting(run)

        runner.reconcileFinishedCaptures(
            against: [makeProject(path: "/p", taskIDs: ["001", "002"])]
        )

        XCTAssertTrue(runner.run(for: "002", in: "/p") === run)
        XCTAssertTrue(runner.isRunning(taskID: "002", in: "/p"))
        XCTAssertTrue(runner.runningCaptures(projectPath: "/p").isEmpty)
        XCTAssertEqual(runner.runningRunCount, 1)
        XCTAssertNil(runner.run(for: syntheticKey, in: "/p"))
    }

    /// A still-running capture whose project gained NO new id is neither
    /// re-keyed nor dismissed, and (unlike a finished run) its bounded-fallback
    /// counter does NOT advance — a live run must never be force-dismissed.
    @MainActor
    func testRunningCaptureNotRekeyedWithoutNewID() {
        let run = makeRunningCapture(path: "/p", baseline: ["001"])
        let projects = [makeProject(path: "/p", taskIDs: ["001"])]

        let decision = TaskRunner.reconcile(
            runs: [run.taskID: run], projects: projects
        )
        XCTAssertTrue(decision.toRekey.isEmpty)
        XCTAssertTrue(decision.toDismiss.isEmpty)
        XCTAssertEqual(run.reconcileAttempts, 0)
    }

    /// Baseline-diff FALLBACK, ambiguous case (#100): when TWO running captures
    /// exist for one project and NEITHER reported its real id (no `captured`
    /// event), a single new id cannot be attributed to a specific run, so neither
    /// is re-keyed. This is the DEMOTED fallback path — the `reportedTaskID`
    /// preference (covered by `testConcurrentRunningCapturesRekeyViaReportedTaskID`)
    /// is what now lets overlapping captures hand off; absent that signal the
    /// re-key still only fires under the single-running-capture + single-new-id
    /// guard, so ambiguous overlaps are left to resolve at process exit rather
    /// than mis-attributed. (Renamed from `testConcurrentRunningCapturesAreNotRekeyed`
    /// to make the "no reported id" precondition explicit.)
    @MainActor
    func testConcurrentRunningCapturesWithoutReportedIDAreNotRekeyed() {
        let runA = makeRunningCapture(path: "/p", baseline: ["001"],
                                      id: "capture:/p:A")
        let runB = makeRunningCapture(path: "/p", baseline: ["001"],
                                      id: "capture:/p:B")
        // Neither run reports an id — the fallback baseline-diff path governs.
        XCTAssertNil(runA.reportedTaskID)
        XCTAssertNil(runB.reportedTaskID)
        let projects = [makeProject(path: "/p", taskIDs: ["001", "002"])]

        let decision = TaskRunner.reconcile(
            runs: [runA.taskID: runA, runB.taskID: runB], projects: projects
        )
        XCTAssertTrue(decision.toRekey.isEmpty)
    }

    /// Baseline-diff FALLBACK, unambiguous case (#100 regression): a SINGLE
    /// running capture with NO `reportedTaskID` still re-keys via the baseline
    /// diff — exactly the pre-#100 behavior — when its project gained exactly one
    /// new id. This proves the reported-id preference did not break or bypass the
    /// fallback for runs that report nothing (older launcher / decode skew). The
    /// twin `…AreNotRekeyed` test above covers the ambiguous no-report case; this
    /// covers the unambiguous no-report case.
    @MainActor
    func testSingleRunningCaptureWithoutReportedIDRekeysViaBaselineDiff() {
        let run = makeRunningCapture(path: "/p", baseline: ["001"])
        XCTAssertNil(run.reportedTaskID, "fallback path: no id reported")
        let projects = [makeProject(path: "/p", taskIDs: ["001", "002"])]

        let decision = TaskRunner.reconcile(
            runs: [run.taskID: run], projects: projects
        )
        // The single-running-capture + single-new-id guard still fires.
        XCTAssertEqual(decision.toRekey, [run.taskID: "002"])
        XCTAssertTrue(decision.toDismiss.isEmpty)
    }

    /// #100: TWO overlapping running captures for one project, each reporting its
    /// OWN real id via a `captured` NDJSON event, BOTH re-key off their synthetic
    /// keys to their real ids. This is the bug `testConcurrentRunningCapturesAreNotRekeyed`
    /// deliberately left stranded: with two running captures and both new ids
    /// present at reconcile time, the ambiguous baseline-diff guard
    /// (`runningCapturesByProject == 1 && newIDs.count == 1`) is doubly false, so
    /// neither live run ever hands off and both spinner rows strand beside their
    /// real plan rows until the processes exit. The authoritative per-run
    /// `reportedTaskID` (from the `captured` event) breaks the ambiguity: each run
    /// re-keys directly to the id IT reported, bypassing the baseline-diff guard.
    @MainActor
    func testConcurrentRunningCapturesRekeyViaReportedTaskID() {
        // Each capture snapshotted a baseline lacking the OTHER's not-yet-written
        // id — the real-world overlap that produced the bug. Both ids land on disk
        // (["001","002","003"]) while both processes keep running.
        let runA = makeRunningCapture(path: "/p", baseline: ["001"],
                                      id: "capture:/p:A")
        let runB = makeRunningCapture(path: "/p", baseline: ["001", "002"],
                                      id: "capture:/p:B")
        // Each run reports its OWN real id through the new `captured` event, fed
        // through the exact private ingest path.
        runA.ingestForTesting(#"{"kind":"captured","taskId":"002"}"# + "\n")
        runB.ingestForTesting(#"{"kind":"captured","taskId":"003"}"# + "\n")

        let projects = [makeProject(path: "/p", taskIDs: ["001", "002", "003"])]

        let decision = TaskRunner.reconcile(
            runs: [runA.taskID: runA, runB.taskID: runB], projects: projects
        )

        // Both live runs re-key off their synthetic keys to the id each reported —
        // never to each other's id, and never stranded.
        XCTAssertEqual(decision.toRekey[runA.taskID], "002")
        XCTAssertEqual(decision.toRekey[runB.taskID], "003")
        XCTAssertEqual(decision.toRekey.count, 2)
        XCTAssertTrue(decision.toDismiss.isEmpty)
    }

    /// After a re-key the live process stays tracked, so the quit guard still
    /// sees a running run under the real id.
    @MainActor
    func testRekeyedRunStillCountsForQuitGuard() {
        let runner = TaskRunner()
        let run = makeRunningCapture(path: "/p", baseline: ["001"])
        runner.ingestRunForTesting(run)

        runner.reconcileFinishedCaptures(
            against: [makeProject(path: "/p", taskIDs: ["001", "002"])]
        )

        XCTAssertTrue(runner.hasRunningRuns)
        XCTAssertEqual(runner.runningRunCount, 1)
    }

    /// `rekey(to:)` changes ONLY the run's identity; mode, description,
    /// baseline, and projectPath are intact (the live process and all other
    /// state ride along unchanged).
    @MainActor
    func testRekeyChangesIdentityOnly() {
        let run = makeRunningCapture(path: "/p", baseline: ["001"],
                                     id: "capture:/p:X")
        run.rekey(to: "002")

        XCTAssertEqual(run.taskID, "002")
        XCTAssertEqual(run.mode, .capture)
        XCTAssertEqual(run.description, "Add a thing")
        XCTAssertEqual(run.baselineTaskIDs, ["001"])
        XCTAssertEqual(run.projectPath, "/p")
    }

    // MARK: - Run identity is (project path, full task id) (#090)

    /// Builds an existing-task run for `taskID` in `projectPath` without spawning
    /// `node`: `markRunningForTesting(projectPath:)` records the run's project so
    /// `ingestRunForTesting` keys it on (path, id).
    @MainActor
    private func makeTaskRun(_ taskID: String, in projectPath: String, running: Bool) -> TaskRun {
        // A temp outcome log so a finished fixture never appends to the real
        // `~/.claude/plans-cc/run-outcomes.log`.
        let log = RunOutcomeLog(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("run-outcomes.log"))
        let run = TaskRun(taskID: taskID, mode: .execute, outcomeLog: log)
        if running {
            run.markRunningForTesting(projectPath: projectPath)
        } else {
            run.finishForTesting(projectPath: projectPath)
        }
        return run
    }

    /// The same task id in two projects is two independent runs: lookups,
    /// running state and dismissal never cross projects.
    @MainActor
    func testSameTaskIDAcrossProjectsTrackedIndependently() {
        let runner = TaskRunner()
        let runA = makeTaskRun("042", in: "/a", running: true)
        let runB = makeTaskRun("042", in: "/b", running: false)
        runner.ingestRunForTesting(runA)
        runner.ingestRunForTesting(runB)

        XCTAssertTrue(runner.run(for: "042", in: "/a") === runA)
        XCTAssertTrue(runner.run(for: "042", in: "/b") === runB)
        XCTAssertTrue(runner.isRunning(taskID: "042", in: "/a"))
        XCTAssertFalse(runner.isRunning(taskID: "042", in: "/b"))
        XCTAssertNil(runner.run(for: "042", in: "/c"))

        runner.dismiss(taskID: "042", in: "/b")
        XCTAssertNil(runner.run(for: "042", in: "/b"))
        XCTAssertTrue(runner.run(for: "042", in: "/a") === runA)
        XCTAssertEqual(runner.runningRunCount, 1)
    }

    /// Ids past 999 are distinct run identities: a run for `1000` is not a run
    /// for `100` (the pre-#090 truncation collapsed them).
    @MainActor
    func testFourDigitTaskIDDoesNotShareRunWithThreeDigitPrefix() {
        let runner = TaskRunner()
        let run1000 = makeTaskRun("1000", in: "/p", running: true)
        runner.ingestRunForTesting(run1000)

        XCTAssertTrue(runner.isRunning(taskID: "1000", in: "/p"))
        XCTAssertFalse(runner.isRunning(taskID: "100", in: "/p"))
        XCTAssertNil(runner.run(for: "100", in: "/p"))

        let run100 = makeTaskRun("100", in: "/p", running: false)
        runner.ingestRunForTesting(run100)
        XCTAssertTrue(runner.run(for: "100", in: "/p") === run100)
        XCTAssertTrue(runner.run(for: "1000", in: "/p") === run1000)
    }

    /// Capture reconciliation sees a brand-new `1002` (alongside existing 999,
    /// 1000, 1001) as the new plan: a running capture re-keys to it, a finished
    /// one MIGRATES to it (#117).
    @MainActor
    func testCaptureReconcileDetectsNewFourDigitTaskID() {
        let baseline: Set<String> = ["999", "1000", "1001"]
        let project = makeProject(path: "/p", taskIDs: ["999", "1000", "1001", "1002"])

        let running = makeRunningCapture(path: "/p", baseline: baseline)
        let decision = TaskRunner.reconcile(runs: [running.taskID: running], projects: [project])
        XCTAssertEqual(decision.toRekey, [running.taskID: "1002"])

        let finished = makeFinishedCapture(path: "/p", baseline: baseline)
        let finishedDecision = TaskRunner.reconcile(runs: [finished.taskID: finished], projects: [project])
        XCTAssertEqual(finishedDecision.toMigrate[finished.taskID], "1002")

        let runner = TaskRunner()
        runner.ingestRunForTesting(running)
        runner.reconcileFinishedCaptures(against: [project])
        XCTAssertTrue(runner.run(for: "1002", in: "/p") === running)
        XCTAssertNil(runner.run(for: "100", in: "/p"))
    }

    /// An existing-task run only claims its id within ITS project: a run for
    /// `002` in `/q` must not stop a `/p` capture from handing off to `/p`'s new
    /// `002`, while a run for `002` in `/p` itself still does.
    @MainActor
    func testRekeyClaimIsScopedToProject() {
        let project = makeProject(path: "/p", taskIDs: ["001", "002"])

        let runner = TaskRunner()
        runner.ingestRunForTesting(makeTaskRun("002", in: "/q", running: true))
        let capture = makeRunningCapture(path: "/p", baseline: ["001"])
        runner.ingestRunForTesting(capture)
        runner.reconcileFinishedCaptures(against: [project])
        XCTAssertTrue(runner.run(for: "002", in: "/p") === capture)

        let sameProject = TaskRunner()
        sameProject.ingestRunForTesting(makeTaskRun("002", in: "/p", running: true))
        let capture2 = makeRunningCapture(path: "/p", baseline: ["001"])
        sameProject.ingestRunForTesting(capture2)
        sameProject.reconcileFinishedCaptures(against: [project])
        XCTAssertEqual(capture2.taskID.hasPrefix("capture:"), true)
        XCTAssertFalse(sameProject.run(for: "002", in: "/p") === capture2)
    }

    // The Node-side `--description` arg shape (capture / executeYolo runs pass
    // `--description <text>` and omit `--task-id`) is verified by inspection of
    // `TaskRun.spawn` / `run-task.ts`; it is not exercised here because that
    // would require spawning a real `node` process. The synthetic-key contract
    // (`"capture:" + projectPath`) that `TaskRunner.capture(...)` registers a
    // run under is covered by the `TaskRun` identity test above — calling
    // `capture(...)` is deliberately avoided so this test surface stays pure
    // (no `Process` spawn, no flakiness).

    // MARK: - Project-wide discuss (#110)

    /// A `.discuss` run with an EMPTY `taskID` (the whole-project discuss case)
    /// OMITS `--task-id` entirely — the id-bearing flag is only emitted for a
    /// real, non-empty id — while still carrying the free-text `--description`
    /// question and `--mode discuss`.
    func testArgumentsForProjectDiscussOmitsTaskID() {
        let args = TaskRun.arguments(
            scriptPath: "/b/run-task.js", projectPath: "/proj", taskID: "",
            mode: .discuss, description: "why?", deep: false, keep: false, resume: nil
        )
        XCTAssertEqual(args, [
            "/b/run-task.js", "--project-root", "/proj",
            "--description", "why?", "--mode", "discuss",
        ])
        XCTAssertFalse(args.contains("--task-id"), "empty id must omit --task-id")
    }

    /// Focused companion to `testArgumentsForDiscussWithoutResume`: a NON-empty
    /// id still emits `--task-id <id>` (the empty-id guard only suppresses the
    /// flag when the id is actually blank).
    func testArgumentsForProjectDiscussEmitsTaskIDWhenIDNonEmpty() {
        let args = TaskRun.arguments(
            scriptPath: "/b/run-task.js", projectPath: "/proj", taskID: "099",
            mode: .discuss, description: "why?", deep: false, keep: false, resume: nil
        )
        XCTAssertTrue(args.contains("--task-id"))
        let idx = args.firstIndex(of: "--task-id")
        XCTAssertEqual(idx.map { args[args.index(after: $0)] }, "099")
    }

    private final class ProjectDiscussLaunchRecorder {
        var runs: [TaskRun] = []
        var paths: [String] = []
        var finishers: [() -> Void] = []
    }

    @MainActor
    private func makeProjectDiscussRunner() -> (TaskRunner, ProjectDiscussLaunchRecorder) {
        let runner = TaskRunner()
        let recorder = ProjectDiscussLaunchRecorder()
        runner.discussLauncherForTesting = { run, path, onFinish in
            recorder.runs.append(run)
            recorder.paths.append(path)
            recorder.finishers.append(onFinish)
        }
        return (runner, recorder)
    }

    /// A long whole-project reply must scroll inside the sheet rather than grow
    /// the sheet to the reply's full height.
    @MainActor
    func testProjectDiscussionSheetHeightIsCappedForLongReply() {
        let (runner, _) = makeProjectDiscussRunner()
        runner.askProject(projectPath: "/p", question: "What should I do next?")
        let longReply = Array(repeating: "A paragraph of discussion about the backlog.", count: 200)
            .joined(separator: "\n\n")
        runner.projectThread(projectPath: "/p")?.apply(.reply(text: longReply, sessionID: "s"))

        let host = NSHostingView(
            rootView: ProjectDiscussionView(projectPath: "/p", projectName: "P").environment(runner)
        )

        XCTAssertLessThanOrEqual(host.fittingSize.height, ProjectDiscussionView.maxSheetHeight)
    }

    /// Closing the sheet ends the conversation: the thread is gone, so reopening
    /// starts empty, and a turn still in flight is stopped.
    @MainActor
    func testEndProjectDiscussionDropsThreadAndStopsInFlightTurn() {
        let (runner, recorder) = makeProjectDiscussRunner()
        runner.askProject(projectPath: "/p", question: "q")
        recorder.runs[0].markRunningForTesting(projectPath: "/p")

        runner.endProjectDiscussion(projectPath: "/p")

        XCTAssertNil(runner.projectThread(projectPath: "/p"))
        XCTAssertFalse(recorder.runs[0].isRunning)
    }

    /// Ending the whole-project conversation must not touch per-plan discussions.
    @MainActor
    func testEndProjectDiscussionLeavesPerTaskThreadIntact() {
        let (runner, _) = makeProjectDiscussRunner()
        runner.askProject(projectPath: "/p", question: "project question")
        runner.ask(projectPath: "/p", taskID: "7", question: "task question")

        runner.endProjectDiscussion(projectPath: "/p")

        XCTAssertEqual(runner.discussion(projectPath: "/p", taskID: "7")?.turns.map(\.question),
                       ["task question"])
    }

    /// `askProject(projectPath:question:)` creates a project-scoped
    /// `DiscussionThread` resolvable via the read-only `projectThread(projectPath:)`
    /// accessor, launches a `.discuss` run with an EMPTY `taskID` carrying the
    /// question as `description`, and holds the run OFF `runs`.
    @MainActor
    func testAskProjectLaunchesProjectScopedDiscussRunOutsideRuns() {
        let (runner, recorder) = makeProjectDiscussRunner()
        runner.askProject(projectPath: "/p", question: "  How is this organised?  ")

        let thread = runner.projectThread(projectPath: "/p")
        XCTAssertNotNil(thread)
        XCTAssertEqual(thread?.turns.map(\.question), ["How is this organised?"])
        XCTAssertEqual(thread?.isBusy, true)

        XCTAssertEqual(recorder.runs.count, 1)
        let run = recorder.runs[0]
        XCTAssertEqual(run.mode, .discuss)
        XCTAssertEqual(run.taskID, "", "a project discuss run carries an empty task id")
        XCTAssertEqual(run.description, "How is this organised?")
        XCTAssertEqual(recorder.paths, ["/p"])

        XCTAssertTrue(runner.runs.isEmpty, "a discuss run never enters runs")
    }

    /// The project-scoped thread is DISTINCT from a per-task thread for the same
    /// project (keyed on an empty id vs a real id), and `projectThread` never
    /// resolves a per-task thread (and vice versa).
    @MainActor
    func testProjectThreadIsDistinctFromPerTaskThread() {
        let (runner, _) = makeProjectDiscussRunner()
        runner.askProject(projectPath: "/p", question: "project question")
        let taskThread = runner.thread(projectPath: "/p", taskID: "099")

        let projectThread = runner.projectThread(projectPath: "/p")
        XCTAssertNotNil(projectThread)
        XCTAssertFalse(projectThread === taskThread,
                       "project thread and per-task thread are separate conversations")
        // The project thread holds the project question; the per-task thread is
        // untouched (no turns), confirming they are keyed apart.
        XCTAssertEqual(projectThread?.turns.map(\.question), ["project question"])
        XCTAssertTrue(taskThread.turns.isEmpty)
    }

    /// `projectThread(projectPath:)` is read-only: it never creates a thread.
    @MainActor
    func testProjectThreadLookupDoesNotCreateThread() {
        let runner = TaskRunner()
        XCTAssertNil(runner.projectThread(projectPath: "/p"))
        XCTAssertTrue(runner.discussions.isEmpty)
    }

    // MARK: - #083 review mode: RunMode shape

    func testReviewModeFlags() {
        XCTAssertTrue(RunMode.review.usesTaskID, "review names an existing task")
        XCTAssertFalse(RunMode.review.usesDescription,
                       "review carries no --description; Q&A flows over stdin")
        XCTAssertEqual(RunMode.review.activityVerb, "Reviewing")
    }

    // MARK: - #083 review mode: .question decoding

    @MainActor
    func testDecodesQuestionViaIngest() {
        let run = TaskRun(taskID: "083", mode: .review)
        let json = #"{"kind":"question","toolUseId":"tu-1","questions":[{"question":"Does the toolbar look right?","header":"Observation 1","multiSelect":false,"options":[{"label":"Looks good","description":"Matches the plan"},{"label":"Something's wrong","description":"Describe it"}]}]}"#
        run.ingestForTesting(json + "\n")

        guard case let .question(toolUseId, questions) = run.lines.last?.event else {
            return XCTFail("expected .question, got \(String(describing: run.lines.last?.event))")
        }
        XCTAssertEqual(toolUseId, "tu-1")
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].question, "Does the toolbar look right?")
        XCTAssertEqual(questions[0].header, "Observation 1")
        XCTAssertFalse(questions[0].multiSelect)
        XCTAssertEqual(questions[0].options.map(\.label),
                       ["Looks good", "Something's wrong"])
    }

    /// `multiSelect` defaults to false when absent from the wire shape.
    @MainActor
    func testQuestionMultiSelectDefaultsFalse() {
        let run = TaskRun(taskID: "083", mode: .review)
        let json = #"{"kind":"question","toolUseId":"tu-2","questions":[{"question":"Q","header":"H","options":[{"label":"A"}]}]}"#
        run.ingestForTesting(json + "\n")
        guard case let .question(_, questions) = run.lines.last?.event else {
            return XCTFail("expected .question")
        }
        XCTAssertFalse(questions[0].multiSelect,
                       "absent multiSelect must decode as false")
    }

    /// A `.question` line split across two ingest chunks (partial-line case,
    /// mirroring the captured/reply split tests) still decodes once complete.
    @MainActor
    func testQuestionDecodesWhenSplitAcrossChunks() {
        let run = TaskRun(taskID: "083", mode: .review)
        run.ingestForTesting(#"{"kind":"question","toolUseId":"tu-3","questi"#)
        XCTAssertNil(run.lines.last, "no complete line yet")
        run.ingestForTesting(#"ons":[{"question":"Q","header":"H","options":[{"label":"A"}]}]}"# + "\n")
        guard case let .question(toolUseId, _) = run.lines.last?.event else {
            return XCTFail("expected .question after the second chunk")
        }
        XCTAssertEqual(toolUseId, "tu-3")
    }

    /// `.question` round-trips through encode → decode unchanged (Codable).
    func testQuestionRoundTrips() throws {
        let original = RunEvent.question(
            toolUseId: "tu-4",
            questions: [
                ReviewQuestion(
                    question: "Q", header: "H", multiSelect: true,
                    options: [ReviewQuestionOption(label: "A", description: "d", preview: "p")]
                )
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RunEvent.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - #083 review mode: argument shape

    func testArgumentsForReviewKept() {
        let args = TaskRun.arguments(
            scriptPath: "/b/run-task.js", projectPath: "/proj", taskID: "083",
            mode: .review, description: nil, deep: false, keep: false,
            resume: nil, reviewLocation: .kept
        )
        XCTAssertEqual(args, [
            "/b/run-task.js", "--project-root", "/proj",
            "--task-id", "083", "--mode", "review", "--review-location", "kept",
        ])
    }

    func testArgumentsForReviewWorktreeAndMain() {
        for loc in [ReviewLocation.worktree, .main] {
            let args = TaskRun.arguments(
                scriptPath: "/s", projectPath: "/p", taskID: "1",
                mode: .review, description: nil, deep: false, keep: false,
                resume: nil, reviewLocation: loc
            )
            XCTAssertEqual(args, [
                "/s", "--project-root", "/p",
                "--task-id", "1", "--mode", "review", "--review-location", loc.rawValue,
            ])
        }
    }

    /// A non-review mode never emits `--review-location`, even if a location is
    /// passed (it defaults nil for every existing call site).
    func testArgumentsIgnoreReviewLocationForNonReviewModes() {
        let args = TaskRun.arguments(
            scriptPath: "/s", projectPath: "/p", taskID: "1",
            mode: .execute, description: nil, deep: false, keep: false,
            resume: nil, reviewLocation: .kept
        )
        XCTAssertFalse(args.contains("--review-location"),
                       "execute must not pass --review-location")
    }

    // MARK: - #083 review mode: stdin pipe + pendingQuestion + answer

    /// The review-only stdin pipe is created for a `.review` run and left nil for
    /// every other mode.
    @MainActor
    func testStandardInputPipeCreatedOnlyForReview() {
        let reviewRun = TaskRun(taskID: "083", mode: .review)
        reviewRun.makeStandardInputForTesting()
        XCTAssertNotNil(reviewRun.standardInputForTesting,
                        "review run gets a stdin pipe")

        let executeRun = TaskRun(taskID: "019", mode: .execute)
        executeRun.makeStandardInputForTesting()
        XCTAssertNil(executeRun.standardInputForTesting,
                     "non-review run never gets a stdin pipe")
    }

    /// A running run's snapshot reports whether it is parked on a question, so
    /// the toolbar's active-runs popover can surface it even when the plan has
    /// left the list (e.g. /plan-complete archived it before asking).
    @MainActor
    func testRunSnapshotReportsNeedsInputWhileParked() {
        let run = TaskRun(taskID: "078", mode: .complete, outcomeLog: tempOutcomeLog())
        run.markRunningForTesting(projectPath: "/proj")
        XCTAssertEqual(TaskRunner.snapshot(of: run)?.needsInput, false)

        let json = #"{"kind":"question","toolUseId":"tu-1","questions":[{"question":"Merge?","header":"Merge branch","options":[{"label":"Merge"}]}]}"#
        run.ingestForTesting(json + "\n")
        XCTAssertEqual(TaskRunner.snapshot(of: run)?.needsInput, true)

        run.finishForTesting(projectPath: "/proj")
        XCTAssertNil(TaskRunner.snapshot(of: run), "a finished run has no snapshot")
    }

    /// A `.question` event sets `pendingQuestion`; `finish` clears it.
    @MainActor
    func testPendingQuestionSetOnQuestionAndClearedOnFinish() {
        let run = TaskRun(taskID: "083", mode: .review, outcomeLog: tempOutcomeLog())
        run.markRunningForTesting(projectPath: "/proj")
        let json = #"{"kind":"question","toolUseId":"tu-9","questions":[{"question":"Q","header":"H","options":[{"label":"A"}]}]}"#
        run.ingestForTesting(json + "\n")
        XCTAssertEqual(run.pendingQuestion?.toolUseId, "tu-9")

        run.finishForTesting(projectPath: "/proj")
        XCTAssertNil(run.pendingQuestion, "finish must clear the pending question")
    }

    /// `answer(...)` serializes exactly one NDJSON line matching the wire shape.
    func testAnswerSerialization() throws {
        let line = TaskRun.answerLine(toolUseId: "tu-7",
                                      answers: ["Observation 1": "Looks good"])
        XCTAssertTrue(line.hasSuffix("\n"), "answer line must be newline-terminated")
        let obj = try JSONSerialization.jsonObject(
            with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["kind"] as? String, "answer")
        XCTAssertEqual(obj?["toolUseId"] as? String, "tu-7")
        let answers = obj?["answers"] as? [String: String]
        XCTAssertEqual(answers?["Observation 1"], "Looks good")
    }

    /// The `TaskRunner.review(...)` launcher keys a `.review` run the normal way.
    @MainActor
    func testReviewLauncherKeysRunNormally() {
        let runner = TaskRunner()
        runner.review(projectPath: "/proj", taskID: "083", location: .worktree)
        let run = runner.run(for: "083", in: "/proj")
        XCTAssertNotNil(run, "review run is keyed in runs like any other")
        XCTAssertEqual(run?.mode, .review)
    }

    // MARK: - Complete mode (interactive plan-complete)

    func testCompleteModeFlags() {
        XCTAssertTrue(RunMode.complete.usesTaskID, "complete names an existing task")
        XCTAssertFalse(RunMode.complete.usesDescription,
                       "complete carries no --description; a trailer would become skill arguments")
        XCTAssertEqual(RunMode.complete.activityVerb, "Completing")
    }

    /// Only review and complete answer questions over stdin; every other mode is
    /// autonomous.
    func testOnlyReviewAndCompleteAreInteractive() {
        XCTAssertTrue(RunMode.review.isInteractive)
        XCTAssertTrue(RunMode.complete.isInteractive)
        for mode in [RunMode.execute, .elaborate, .capture, .captureElaborate, .executeYolo,
                     .reElaborate, .reElaborateReview, .delete, .backlog, .restore, .discuss] {
            XCTAssertFalse(mode.isInteractive, "\(mode) must stay autonomous")
        }
    }

    func testArgumentsForComplete() {
        let args = TaskRun.arguments(
            scriptPath: "/s", projectPath: "/p", taskID: "083",
            mode: .complete, description: "ignored", deep: false, keep: false,
            resume: "ignored", reviewLocation: .kept
        )
        XCTAssertEqual(args, [
            "/s", "--project-root", "/p", "--task-id", "083", "--mode", "complete",
        ])
    }

    @MainActor
    func testStandardInputPipeCreatedForComplete() {
        let run = TaskRun(taskID: "083", mode: .complete)
        run.makeStandardInputForTesting()
        XCTAssertNotNil(run.standardInputForTesting, "complete answers questions over stdin")
    }

    @MainActor
    func testCompleteLauncherKeysRunNormally() {
        let runner = TaskRunner()
        runner.complete(projectPath: "/proj", taskID: "083")
        let run = runner.run(for: "083", in: "/proj")
        XCTAssertEqual(run?.mode, .complete)
    }

    // MARK: - Mode-specific truncation copy

    func testTruncationErrorCopyIsModeSpecific() {
        let execute = TaskRun.truncationError(for: "error_max_budget_usd", mode: .execute)
        XCTAssertEqual(execute, TaskRun.truncationError(for: "error_max_budget_usd"),
                       "execute keeps the existing copy")
        let review = TaskRun.truncationError(for: "error_max_budget_usd", mode: .review)
        XCTAssertNotNil(review)
        XCTAssertTrue(review?.contains("/plan-review") == true)
        XCTAssertFalse(review?.contains("/plan-execute") == true)
        let complete = TaskRun.truncationError(for: "error_max_turns", mode: .complete)
        XCTAssertTrue(complete?.contains("/plan-complete") == true)
        XCTAssertFalse(complete?.contains("/plan-execute") == true)
        XCTAssertNil(TaskRun.truncationError(for: "end_turn", mode: .review))
    }

    @MainActor
    func testReviewRunTruncationUsesReviewCopy() {
        let run = TaskRun(taskID: "083", mode: .review, outcomeLog: tempOutcomeLog())
        run.markRunningForTesting(projectPath: "/proj")
        run.ingestForTesting(#"{"kind":"done","costUsd":1,"turns":3,"stopReason":"error_max_turns"}"# + "\n")
        XCTAssertEqual(run.error, TaskRun.truncationError(for: "error_max_turns", mode: .review))
    }

    // MARK: - Continuing a finished review as a discussion

    @MainActor
    private func finishedReviewRun(location: ReviewLocation,
                                   sessionID: String = "s-rev",
                                   reply: String = "All observations confirmed.") -> TaskRun {
        let run = TaskRun(taskID: "083", mode: .review, reviewLocation: location,
                          outcomeLog: tempOutcomeLog())
        run.markRunningForTesting(projectPath: "/proj")
        run.ingestForTesting(#"{"kind":"session","sessionId":"\#(sessionID)"}"# + "\n"
            + #"{"kind":"reply","text":"\#(reply)","sessionId":"\#(sessionID)"}"# + "\n"
            + #"{"kind":"done","costUsd":0.5,"turns":4,"stopReason":"end_turn"}"# + "\n")
        run.finishForTesting(projectPath: "/proj")
        return run
    }

    @MainActor
    func testContinueReviewInDiscussionResumesReviewSession() {
        let runner = TaskRunner()
        var launched: [TaskRun] = []
        runner.discussLauncherForTesting = { run, _, _ in launched.append(run) }
        runner.ingestRunForTesting(finishedReviewRun(location: .worktree))

        runner.continueReviewInDiscussion(projectPath: "/proj", taskID: "083")

        let thread = runner.discussion(projectPath: "/proj", taskID: "083")
        XCTAssertEqual(thread?.sessionID, "s-rev")
        XCTAssertEqual(thread?.turns.count, 1)
        XCTAssertEqual(thread?.turns.first?.reply, "All observations confirmed.")
        XCTAssertTrue(thread?.turns.first?.isReviewSummary == true)
        XCTAssertNil(runner.run(for: "083", in: "/proj"), "the finished review run is dismissed")

        runner.ask(projectPath: "/proj", taskID: "083", question: "Why step 2?")
        XCTAssertEqual(launched.last?.resume, "s-rev")
        XCTAssertEqual(launched.last?.description, "Why step 2?")
    }

    /// A kept-worktree review ran with the worktree as its cwd, so its session
    /// can't be resumed from the project root; the summary is carried as context
    /// on the first question instead.
    @MainActor
    func testContinueKeptReviewInDiscussionCarriesSummaryAsContext() {
        let runner = TaskRunner()
        var launched: [TaskRun] = []
        runner.discussLauncherForTesting = { run, _, _ in launched.append(run) }
        runner.ingestRunForTesting(finishedReviewRun(location: .kept))

        runner.continueReviewInDiscussion(projectPath: "/proj", taskID: "083")

        let thread = runner.discussion(projectPath: "/proj", taskID: "083")
        XCTAssertNil(thread?.sessionID)
        runner.ask(projectPath: "/proj", taskID: "083", question: "Why step 2?")
        XCTAssertNil(launched.last?.resume)
        XCTAssertTrue(launched.last?.description?.contains("All observations confirmed.") == true)
        XCTAssertTrue(launched.last?.description?.hasSuffix("Why step 2?") == true)
        XCTAssertEqual(thread?.turns.last?.question, "Why step 2?",
                       "the transcript shows the user's question, not the context")
    }

    @MainActor
    func testContinueReviewInDiscussionIgnoresLiveOrNonReviewRuns() {
        let runner = TaskRunner()
        let live = TaskRun(taskID: "083", mode: .review, reviewLocation: .main,
                           outcomeLog: tempOutcomeLog())
        live.markRunningForTesting(projectPath: "/proj")
        runner.ingestRunForTesting(live)
        runner.continueReviewInDiscussion(projectPath: "/proj", taskID: "083")
        // #117: the plan's agent already exists (its live review run lives there),
        // so its thread is non-nil — but `continueReviewInDiscussion` is a no-op
        // for a LIVE run, so the thread was never seeded and the run stays.
        XCTAssertTrue(runner.discussion(projectPath: "/proj", taskID: "083")?.turns.isEmpty ?? true)
        XCTAssertNotNil(runner.run(for: "083", in: "/proj"))
    }

    // MARK: - #117: single-gate routing through agents

    private final class RunLaunchRecorder {
        var runs: [TaskRun] = []
        var paths: [String] = []
        var finishers: [() -> Void] = []
    }

    @MainActor
    private func makeRunLauncherRunner() -> (TaskRunner, RunLaunchRecorder, RunLaunchRecorder) {
        let runner = TaskRunner()
        let runRec = RunLaunchRecorder()
        let discussRec = RunLaunchRecorder()
        runner.runLauncherForTesting = { run, path, onFinish in
            runRec.runs.append(run); runRec.paths.append(path); runRec.finishers.append(onFinish)
        }
        runner.discussLauncherForTesting = { run, path, onFinish in
            discussRec.runs.append(run); discussRec.paths.append(path); discussRec.finishers.append(onFinish)
        }
        return (runner, runRec, discussRec)
    }

    /// Every non-discuss mode routes through the `runLauncherForTesting` seam, so
    /// it is testable without spawning `node`.
    @MainActor
    func testRunReviewCompleteCaptureRouteThroughRunLauncher() {
        let (runner, runRec, _) = makeRunLauncherRunner()
        runner.run(projectPath: "/p", taskID: "1", mode: .execute)
        runner.review(projectPath: "/p", taskID: "2", location: .main)
        runner.complete(projectPath: "/p", taskID: "3")
        runner.capture(projectPath: "/p", description: "new thing")
        XCTAssertEqual(runRec.runs.map(\.mode), [.execute, .review, .complete, .capture])
    }

    /// The single gate: while a plan's agent is working an execute run, a discuss
    /// turn (apply or not) for the SAME plan is refused — and vice versa.
    @MainActor
    func testExecuteAndDiscussAreMutuallyExclusivePerPlan() {
        let (runner, runRec, discussRec) = makeRunLauncherRunner()
        // Execute first, mark it running, then a discuss turn is refused.
        runner.run(projectPath: "/p", taskID: "7", mode: .execute)
        runRec.runs[0].markRunningForTesting(projectPath: "/p")
        runner.ask(projectPath: "/p", taskID: "7", question: "why?")
        runner.ask(projectPath: "/p", taskID: "7", question: "fix it", apply: true)
        XCTAssertTrue(discussRec.runs.isEmpty, "discuss refused while execute runs")

        // Finish the execute run → agent idle → discuss is accepted.
        runRec.finishers[0]()
        runner.ask(projectPath: "/p", taskID: "7", question: "now?")
        XCTAssertEqual(discussRec.runs.count, 1)

        // While the discuss turn is live, an execute run is refused.
        discussRec.runs[0].markRunningForTesting(projectPath: "/p")
        runner.run(projectPath: "/p", taskID: "7", mode: .elaborate)
        XCTAssertEqual(runRec.runs.count, 1, "execute refused while discuss runs")
    }

    /// Discuss turns for a plan agent in the project make an `--apply` project
    /// discuss turn refuse; a read-only project turn is never gated this way.
    @MainActor
    func testProjectApplyRefusedWhileAPlanAgentIsWorking() {
        let (runner, runRec, discussRec) = makeRunLauncherRunner()
        runner.run(projectPath: "/p", taskID: "7", mode: .execute)
        runRec.runs[0].markRunningForTesting(projectPath: "/p")
        XCTAssertTrue(runner.anyPlanAgentWorking(inProject: "/p"))

        // An --apply project turn is refused while the plan agent works.
        runner.askProject(projectPath: "/p", question: "fix all", apply: true)
        XCTAssertTrue(discussRec.runs.isEmpty)

        // A read-only project turn is accepted even while the plan agent works.
        runner.askProject(projectPath: "/p", question: "what next?")
        XCTAssertEqual(discussRec.runs.count, 1)

        // Once the plan agent is idle, an --apply project turn is accepted.
        runRec.finishers[0]()
        discussRec.runs[0].finishForTesting(projectPath: "/p")
        discussRec.finishers[0]()
        runner.askProject(projectPath: "/p", question: "fix all now", apply: true)
        XCTAssertEqual(discussRec.runs.count, 2)
    }

    /// `stopAllRunning` terminates BOTH an agent's execute run and a live discuss
    /// turn across every agent (#117).
    @MainActor
    func testStopAllRunningCoversRunsAndDiscussTurns() {
        let (runner, runRec, discussRec) = makeRunLauncherRunner()
        runner.run(projectPath: "/p", taskID: "7", mode: .execute)
        runRec.runs[0].markRunningForTesting(projectPath: "/p")
        runner.ask(projectPath: "/q", taskID: "9", question: "why?")
        discussRec.runs[0].markRunningForTesting(projectPath: "/q")

        XCTAssertEqual(runner.runningRunCount, 2)
        runner.stopAllRunning()
        XCTAssertFalse(runRec.runs[0].isRunning)
        XCTAssertFalse(discussRec.runs[0].isRunning)
    }
}
