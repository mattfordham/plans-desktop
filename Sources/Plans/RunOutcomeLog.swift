import Foundation
import OSLog

private let outcomeLog = Logger(subsystem: "com.plans.desktop", category: "RunOutcomeLog")

/// A durable record of how a single task run ended, written once when the run
/// finishes (any path). This exists because the live progress sheet is the ONLY
/// place a run's terminal `stopReason`/error is surfaced today — once that sheet
/// or the app closes, the answer to "why did this task strand at in-progress?"
/// is gone. Persisting one of these per finished run keeps that answer around
/// long after the fact (the canonical case: a heavy execute run hitting the
/// `MAX_BUDGET_USD` cap and being left at in-progress before reaching review).
///
/// `Codable` so it round-trips as a single NDJSON line in `RunOutcomeLog`.
struct RunOutcome: Codable, Equatable {
    /// ISO-8601 timestamp of when the run finished (stamped by the caller so the
    /// value type stays free of clock access — mirrors the workflow/test pattern
    /// of injecting time rather than reading it).
    let timestamp: String

    /// The run's task id. For description-driven capture/yolo runs this is the
    /// synthetic per-run key (`capture:<path>:<uuid>`); for execute/elaborate it
    /// is the real plans-cc task id.
    let taskID: String

    /// The `RunMode` raw value (`execute`, `elaborate`, `capture`, …).
    let mode: String

    /// The project the run operated in.
    let projectPath: String

    /// Cost in USD from the terminal `done` event; 0 when the run produced no
    /// `done` line (e.g. an early crash).
    let costUsd: Double

    /// Turn count from the terminal `done` event; 0 when absent.
    let turns: Int

    /// The raw `done` stop reason (`end_turn`, `error_max_budget_usd`,
    /// `error_max_turns`, …) or `nil` when no `done` line was seen. This is the
    /// single most useful field for diagnosing a strand and was previously
    /// dropped after `TaskRun.handle(_:)` consumed it.
    let stopReason: String?

    /// A human-readable error: a streamed `error` line, a budget/turn-cap
    /// truncation message, or a generic nonzero-exit message. `nil` on a clean
    /// finish.
    let errorMessage: String?

    /// The derived terminal state (see `classify`).
    let classification: Classification

    /// The coarse terminal state of a run, derived from its raw signals. This is
    /// the field a user scans to triage: a `truncated` or `crashed` run is one
    /// that almost certainly stranded its task before reaching review.
    enum Classification: String, Codable {
        /// Finished cleanly (no cap, no error, no crash).
        case completed
        /// Cut short by a budget/turn cap — the task was left mid-flight (the
        /// strand-at-in-progress case the $20 cap was raised to mitigate).
        case truncated
        /// A streamed `error` line ended the run.
        case error
        /// The process exited nonzero without any terminal `done`/`error` line.
        case crashed
    }

    /// Derives the terminal `Classification` from a run's raw signals. Pure so
    /// the precedence is unit-testable without a `Process` (mirrors the
    /// `TaskRun.truncationError` / `TaskRunner.taskIDsToDismiss` static-helper
    /// pattern). Precedence, highest first:
    ///   1. `truncated` — a budget/turn cap is the actionable cause even if the
    ///      process also exited nonzero.
    ///   2. `crashed` — a nonzero exit with no terminal `done`/`error` line. This
    ///      outranks `error` because the crash path always carries a generic
    ///      error message; the distinguishing signal is the abnormal exit.
    ///   3. `error` — a streamed error message (with a clean exit).
    ///   4. `completed` — everything else (incl. a missing stop reason).
    static func classify(
        stopReason: String?,
        errorMessage: String?,
        exitedNonzeroWithoutTerminal: Bool
    ) -> Classification {
        if let stopReason, TaskRun.truncatingStopReasons.contains(stopReason) {
            return .truncated
        }
        if exitedNonzeroWithoutTerminal {
            return .crashed
        }
        if errorMessage != nil {
            return .error
        }
        return .completed
    }
}

/// An append-only writer for `RunOutcome` records: one JSON object per line
/// (NDJSON) at `fileURL`, defaulting to `~/.claude/plans-cc/run-outcomes.log`
/// (alongside the plans-cc registry). The path is injectable so tests write to a
/// temp file rather than the real home directory, mirroring `RegistryReader`.
///
/// Writing is best-effort and never throws: a failed append is logged to the
/// unified log and dropped, because losing a diagnostic record must never take
/// down a run's finish path. The `Logger` is `Sendable`-safe and the type holds
/// only a `URL`, so it is safe to call `append` from the main actor at finish.
struct RunOutcomeLog {
    let fileURL: URL

    /// Defaults to `~/.claude/plans-cc/run-outcomes.log`. Inject a custom
    /// `fileURL` in tests.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("plans-cc")
            .appendingPathComponent("run-outcomes.log")
    }

    /// Appends one `RunOutcome` as a single JSON line. Creates the parent
    /// directory and the file if missing. Best-effort: any encode/IO failure is
    /// logged and swallowed.
    func append(_ outcome: RunOutcome) {
        do {
            let data = try JSONEncoder().encode(outcome)
            var line = data
            line.append(UInt8(ascii: "\n"))

            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
        } catch {
            outcomeLog.error("append failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
