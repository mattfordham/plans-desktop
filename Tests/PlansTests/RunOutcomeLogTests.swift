import XCTest
@testable import Plans

/// Tests for `RunOutcome` (the durable record of why a task run ended) and
/// `RunOutcomeLog` (the append-only writer). The classification of a run's
/// terminal state is the keystone — it's the bit a user reads weeks later to
/// answer "why did this task strand at in-progress?" — so it is exercised as a
/// pure function (no `Process`, no `TaskRun`). The writer is exercised against a
/// per-test temp file so the append/format/tolerance behavior is verified
/// without touching the real `~/.claude` log.
final class RunOutcomeLogTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Classification (pure)

    func testClassifyCleanCompletion() {
        // A `done` with a normal stop reason and no error is a clean finish.
        let c = RunOutcome.classify(stopReason: "end_turn", errorMessage: nil, exitedNonzeroWithoutTerminal: false)
        XCTAssertEqual(c, .completed)
    }

    func testClassifyMissingStopReasonIsCompletion() {
        // No stop reason and no error still reads as a clean finish — the run
        // ended without a cap or crash.
        let c = RunOutcome.classify(stopReason: nil, errorMessage: nil, exitedNonzeroWithoutTerminal: false)
        XCTAssertEqual(c, .completed)
    }

    func testClassifyBudgetCapIsTruncated() {
        let c = RunOutcome.classify(stopReason: "error_max_budget_usd", errorMessage: nil, exitedNonzeroWithoutTerminal: false)
        XCTAssertEqual(c, .truncated)
    }

    func testClassifyTurnCapIsTruncated() {
        let c = RunOutcome.classify(stopReason: "error_max_turns", errorMessage: nil, exitedNonzeroWithoutTerminal: false)
        XCTAssertEqual(c, .truncated)
    }

    func testClassifyErrorMessageIsError() {
        // A streamed `error` line beats a benign stop reason.
        let c = RunOutcome.classify(stopReason: "end_turn", errorMessage: "boom", exitedNonzeroWithoutTerminal: false)
        XCTAssertEqual(c, .error)
    }

    func testClassifyNonzeroExitWithoutTerminalIsCrashed() {
        let c = RunOutcome.classify(stopReason: nil, errorMessage: nil, exitedNonzeroWithoutTerminal: true)
        XCTAssertEqual(c, .crashed)
    }

    func testTruncatedClassificationTakesPrecedenceOverPlainExit() {
        // A budget cap surfaces as a truncation even though the process also
        // exits nonzero — the cap is the actionable cause.
        let c = RunOutcome.classify(stopReason: "error_max_budget_usd", errorMessage: nil, exitedNonzeroWithoutTerminal: true)
        XCTAssertEqual(c, .truncated)
    }

    func testClassifyStrandedAtInProgress() {
        // A clean finish (no cap, no error, no crash) whose task never reached
        // review is the #058 stranded case — distinct from `.completed`. The
        // launcher emits the stranded stop reason; `classify` must map it to
        // `.stranded`, NOT mistake it for `.completed`.
        let c = RunOutcome.classify(
            stopReason: TaskRun.strandedStopReason,
            errorMessage: nil,
            exitedNonzeroWithoutTerminal: false
        )
        XCTAssertEqual(c, .stranded)
        XCTAssertNotEqual(c, .completed)
    }

    func testStrandedOutcomeRoundTrips() throws {
        // A `.stranded` outcome (stopReason "stranded_at_in_progress") survives
        // the append/encode/decode cycle just like the other classifications.
        let url = tempDir.appendingPathComponent("run-outcomes.log")
        let log = RunOutcomeLog(fileURL: url)
        log.append(RunOutcome(
            timestamp: "2026-06-24T09:00:00Z", taskID: "058", mode: "execute",
            projectPath: "/proj", costUsd: 3.1, turns: 22,
            stopReason: TaskRun.strandedStopReason, errorMessage: nil,
            classification: .stranded
        ))

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1)
        let decoded = try JSONDecoder().decode(RunOutcome.self, from: Data(lines[0].utf8))
        XCTAssertEqual(decoded.taskID, "058")
        XCTAssertEqual(decoded.classification, .stranded)
        XCTAssertEqual(decoded.stopReason, "stranded_at_in_progress")
    }

    // MARK: - Denied-tool fields backward compatibility (task #092)

    /// An OLD-format `run-outcomes.log` line — written before #092 and so lacking
    /// the `deniedToolCount` / `deniedTools` keys entirely — must STILL decode,
    /// with the two new fields falling back to their zero/empty defaults. This
    /// guards the backward-compat `decodeIfPresent` so a user's existing log
    /// never becomes unreadable after the upgrade.
    func testOldFormatLineWithoutDeniedFieldsDecodesWithDefaults() throws {
        let url = try writeLog([
            #"{"costUsd":4.6,"stopReason":"end_turn","taskID":"724","turns":17,"projectPath":"/proj","mode":"elaborate","timestamp":"2026-09-02T19:36:28Z","classification":"completed"}"#,
        ])
        let reader = RunOutcomeLogReader(fileURL: url)
        let outcomes = reader.read()
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0].taskID, "724")
        // The #092 fields were absent → defaults, not a decode failure.
        XCTAssertEqual(outcomes[0].deniedToolCount, 0)
        XCTAssertEqual(outcomes[0].deniedTools, [])
    }

    /// A NEW-format outcome carrying a denial tally round-trips through the
    /// writer's encode and the reader's decode unchanged — both the per-call
    /// `deniedToolCount` and the distinct `deniedTools` list survive.
    func testNewFormatOutcomeWithDeniedFieldsRoundTrips() throws {
        let url = tempDir.appendingPathComponent("run-outcomes.log")
        let log = RunOutcomeLog(fileURL: url)
        var outcome = RunOutcome(
            timestamp: "2026-10-25T10:00:00Z", taskID: "092", mode: "elaborate",
            projectPath: "/proj", costUsd: 0.5, turns: 9,
            stopReason: "end_turn", errorMessage: nil, classification: .completed
        )
        outcome.deniedToolCount = 3
        outcome.deniedTools = ["mcp__sentry__search_errors", "mcp__sentry__search_issues"]
        log.append(outcome)

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1)
        let decoded = try JSONDecoder().decode(RunOutcome.self, from: Data(lines[0].utf8))
        XCTAssertEqual(decoded.deniedToolCount, 3)
        XCTAssertEqual(decoded.deniedTools,
                       ["mcp__sentry__search_errors", "mcp__sentry__search_issues"])
        XCTAssertEqual(decoded, outcome)
    }

    // MARK: - Writing (append-only, JSON-per-line)

    func testAppendsOneJSONLinePerOutcome() throws {
        let url = tempDir.appendingPathComponent("run-outcomes.log")
        let log = RunOutcomeLog(fileURL: url)

        let first = RunOutcome(
            timestamp: "2026-06-16T11:06:46Z", taskID: "410", mode: "execute",
            projectPath: "/proj", costUsd: 4.2, turns: 31,
            stopReason: "error_max_budget_usd", errorMessage: nil,
            classification: .truncated
        )
        let second = RunOutcome(
            timestamp: "2026-06-16T12:00:00Z", taskID: "411", mode: "execute",
            projectPath: "/proj", costUsd: 1.0, turns: 7,
            stopReason: "end_turn", errorMessage: nil, classification: .completed
        )
        log.append(first)
        log.append(second)

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        // Each line is a standalone JSON object that round-trips back.
        let decoded0 = try JSONDecoder().decode(RunOutcome.self, from: Data(lines[0].utf8))
        XCTAssertEqual(decoded0.taskID, "410")
        XCTAssertEqual(decoded0.classification, .truncated)
        XCTAssertEqual(decoded0.stopReason, "error_max_budget_usd")
        let decoded1 = try JSONDecoder().decode(RunOutcome.self, from: Data(lines[1].utf8))
        XCTAssertEqual(decoded1.taskID, "411")
        XCTAssertEqual(decoded1.classification, .completed)
    }

    func testAppendCreatesParentDirectoryWhenMissing() throws {
        // The real log lives under ~/.claude/plans-cc which may not exist yet;
        // the writer must create intermediate directories rather than silently
        // dropping the record.
        let url = tempDir
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("deeper", isDirectory: true)
            .appendingPathComponent("run-outcomes.log")
        let log = RunOutcomeLog(fileURL: url)
        log.append(RunOutcome(
            timestamp: "t", taskID: "001", mode: "capture", projectPath: "/p",
            costUsd: 0, turns: 0, stopReason: nil, errorMessage: nil,
            classification: .completed
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("\"taskID\":\"001\"") || contents.contains("\"taskID\" : \"001\""))
    }

    // MARK: - Reading (NDJSON line reader)

    /// Writes NDJSON lines verbatim to a temp `run-outcomes.log` so the reader can
    /// be exercised against realistic bytes (including the malformed/blank lines
    /// it must tolerate) without going through the writer.
    private func writeLog(_ lines: [String]) throws -> URL {
        let url = tempDir.appendingPathComponent("run-outcomes.log")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testReadReturnsAllValidOutcomesInOrder() throws {
        // The real sample line shape (optional stopReason, enum raw classification).
        let url = try writeLog([
            #"{"costUsd":4.6379015,"stopReason":"end_turn","taskID":"724","turns":17,"projectPath":"/Users/matt/Work/Ensemble","mode":"elaborate","timestamp":"2026-09-02T19:36:28Z","classification":"completed"}"#,
            #"{"costUsd":4.2,"stopReason":"error_max_budget_usd","taskID":"410","turns":31,"projectPath":"/proj","mode":"execute","timestamp":"2026-06-16T11:06:46Z","classification":"truncated"}"#,
        ])
        let reader = RunOutcomeLogReader(fileURL: url)
        let outcomes = reader.read()
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(outcomes[0].taskID, "724")
        XCTAssertEqual(outcomes[0].classification, .completed)
        XCTAssertEqual(outcomes[1].taskID, "410")
        XCTAssertEqual(outcomes[1].classification, .truncated)
        XCTAssertEqual(outcomes[1].stopReason, "error_max_budget_usd")
    }

    func testReadSkipsMalformedAndBlankLines() throws {
        // Blank lines and non-JSON garbage are skipped, not fatal — the log is a
        // best-effort append target and a partial write must not blind the reader.
        let url = try writeLog([
            #"{"costUsd":1.0,"taskID":"001","turns":1,"projectPath":"/p","mode":"execute","timestamp":"2026-01-01T00:00:00Z","classification":"completed"}"#,
            "",
            "not json at all",
            #"{"costUsd":2.0"#, // truncated / partial write
            #"{"costUsd":3.0,"taskID":"002","turns":2,"projectPath":"/p","mode":"execute","timestamp":"2026-01-02T00:00:00Z","classification":"crashed"}"#,
        ])
        let reader = RunOutcomeLogReader(fileURL: url)
        let outcomes = reader.read()
        XCTAssertEqual(outcomes.map(\.taskID), ["001", "002"])
    }

    func testReadReturnsEmptyWhenFileMissing() {
        let url = tempDir.appendingPathComponent("does-not-exist.log")
        let reader = RunOutcomeLogReader(fileURL: url)
        XCTAssertEqual(reader.read(), [])
    }

    func testLatestOutcomeByTaskPicksNewestTimestampPerKey() throws {
        // Two outcomes for the same (projectPath, taskID): the latest by timestamp
        // wins, regardless of file order (older line appears AFTER the newer one).
        let url = try writeLog([
            #"{"costUsd":3.0,"taskID":"410","turns":5,"projectPath":"/proj","mode":"execute","timestamp":"2026-06-16T12:00:00Z","classification":"completed"}"#,
            #"{"costUsd":4.2,"stopReason":"error_max_budget_usd","taskID":"410","turns":31,"projectPath":"/proj","mode":"execute","timestamp":"2026-06-16T11:06:46Z","classification":"truncated"}"#,
            // Same taskID "410" but a DIFFERENT project — must be a distinct key.
            #"{"costUsd":1.0,"taskID":"410","turns":2,"projectPath":"/other","mode":"execute","timestamp":"2026-06-16T09:00:00Z","classification":"crashed"}"#,
        ])
        let reader = RunOutcomeLogReader(fileURL: url)
        let latest = reader.latestOutcomeByTask()

        // Newest for (/proj, 410) is the 12:00 completed line, NOT the truncated one.
        let projKey = RunOutcomeKey(projectPath: "/proj", taskID: "410")
        XCTAssertEqual(latest[projKey]?.classification, .completed)
        XCTAssertEqual(latest[projKey]?.timestamp, "2026-06-16T12:00:00Z")

        // The same task id in another project is tracked independently.
        let otherKey = RunOutcomeKey(projectPath: "/other", taskID: "410")
        XCTAssertEqual(latest[otherKey]?.classification, .crashed)
    }
}
