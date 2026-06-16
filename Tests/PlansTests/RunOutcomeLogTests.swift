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
}
