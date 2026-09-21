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
        /// The run finished cleanly (SDK `result`, no cap) but the task never
        /// reached review — it was left stranded at in-progress because
        /// `plan-execute` stopped one layer too early (task #058).
        case stranded
        /// A streamed `error` line ended the run.
        case error
        /// The process exited nonzero without any terminal `done`/`error` line.
        case crashed

        /// A short, human-readable label for a failing classification (#079),
        /// used by the failure UI (detail-view section, card tooltip). Pure so it
        /// is unit-testable without any view. `completed` is not a failure and
        /// falls back to a neutral label the UI never actually shows (the failure
        /// surfaces only render for the four non-completed cases).
        var failureLabel: String {
            switch self {
            case .truncated: return "Run cut short (budget/turn cap)"
            case .stranded: return "Stranded at in-progress"
            case .error: return "Run errored"
            case .crashed: return "Run crashed"
            case .completed: return "Completed"
            }
        }
    }

    /// Derives the terminal `Classification` from a run's raw signals. Pure so
    /// the precedence is unit-testable without a `Process` (mirrors the
    /// `TaskRun.truncationError` / `TaskRunner.taskIDsToDismiss` static-helper
    /// pattern). Precedence, highest first:
    ///   1. `truncated` — a budget/turn cap is the actionable cause even if the
    ///      process also exited nonzero.
    ///   2. `stranded` — the run finished cleanly but the task never reached
    ///      review (the `stranded_at_in_progress` signal, task #058). Ranked
    ///      just below `truncated`; in practice they are mutually exclusive
    ///      (the launcher only emits the stranded reason when NOT a cap reason).
    ///   3. `crashed` — a nonzero exit with no terminal `done`/`error` line. This
    ///      outranks `error` because the crash path always carries a generic
    ///      error message; the distinguishing signal is the abnormal exit.
    ///   4. `error` — a streamed error message (with a clean exit).
    ///   5. `completed` — everything else (incl. a missing stop reason).
    static func classify(
        stopReason: String?,
        errorMessage: String?,
        exitedNonzeroWithoutTerminal: Bool
    ) -> Classification {
        if let stopReason, TaskRun.truncatingStopReasons.contains(stopReason) {
            return .truncated
        }
        if stopReason == TaskRun.strandedStopReason {
            return .stranded
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

/// The correlation key for a run outcome: a `(projectPath, taskID)` pair. The
/// `run-outcomes.log` records outcomes per RUN, and the same task id can recur
/// across projects (a synthetic capture key aside), so a task's failure state is
/// only meaningful when scoped to its owning project. `Hashable` so it keys the
/// `latestOutcomeByTask()` dictionary the store correlates against parsed tasks.
struct RunOutcomeKey: Hashable {
    let projectPath: String
    let taskID: String
}

/// A tolerant NDJSON reader over the `run-outcomes.log` written by `RunOutcomeLog`
/// — one `RunOutcome` JSON object per line. Mirrors `RegistryReader`'s injectable
/// `fileURL`/`FileManager` pattern so tests point it at a temp fixture rather than
/// the real `~/.claude/plans-cc/run-outcomes.log`.
///
/// Reading is best-effort and never throws: a missing/empty file yields an empty
/// list, and any single malformed or blank line is SKIPPED rather than aborting
/// the whole read. This matters because the log is an append target that may be
/// mid-write (a partially flushed final line) or hand-truncated; a diagnostic log
/// must degrade to "fewer records" rather than "no records".
struct RunOutcomeLogReader {
    let fileURL: URL
    let fileManager: FileManager

    /// Defaults to `~/.claude/plans-cc/run-outcomes.log` (the same location
    /// `RunOutcomeLog` writes to). Inject a custom `fileURL`/`fileManager` in
    /// tests.
    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("plans-cc")
            .appendingPathComponent("run-outcomes.log")
    }

    /// Reads every well-formed NDJSON line into a `RunOutcome`, in file order.
    /// Malformed lines (non-JSON, partial writes) and blank lines are skipped.
    /// Returns `[]` when the file is missing or unreadable — never throws.
    func read() -> [RunOutcome] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        return contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> RunOutcome? in
                try? decoder.decode(RunOutcome.self, from: Data(line.utf8))
            }
    }

    /// Selects the LATEST outcome per `(projectPath, taskID)` key. "Latest" is by
    /// the `timestamp` string: the ISO-8601 timestamps the writer stamps are
    /// lexicographically sortable, so a plain string comparison orders them
    /// correctly without a `DateFormatter` round-trip (keeps this type
    /// Foundation-only, no locale/clock access). On a tie the later line in file
    /// order wins. Malformed lines are already dropped by `read()`.
    func latestOutcomeByTask() -> [RunOutcomeKey: RunOutcome] {
        var latest: [RunOutcomeKey: RunOutcome] = [:]
        for outcome in read() {
            let key = RunOutcomeKey(projectPath: outcome.projectPath, taskID: outcome.taskID)
            if let existing = latest[key], existing.timestamp > outcome.timestamp {
                continue
            }
            latest[key] = outcome
        }
        return latest
    }
}
