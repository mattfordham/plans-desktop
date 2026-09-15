import Foundation
import Observation
import OSLog

/// Subsystem logger for the task runner. View with:
///   log stream --predicate 'subsystem == "com.plans.desktop"' --level debug
/// or in Console.app filtered to subsystem `com.plans.desktop`.
private let runnerLog = Logger(subsystem: "com.plans.desktop", category: "TaskRunner")

/// A single decoded line of the bundled Node script's NDJSON progress stream.
///
/// This is the Swift mirror of the segment-1 Node contract (`run-task.js`,
/// Data Contract / step 2). The script writes exactly one JSON object per line
/// to stdout, discriminated by a `kind` field:
///
/// - `{"kind":"activity","tool":"Edit","detail":"…"}`
/// - `{"kind":"text","chunk":"…"}`
/// - `{"kind":"done","costUsd":<number>,"turns":<number>,"stopReason":"…"}`
/// - `{"kind":"error","message":"…"}`
///
/// As long as this enum decodes those four shapes, the UI never needs to know
/// the SDK changed — the NDJSON contract is the only coupling point.
///
/// This is a pure value enum (no stored identity — Swift enums can't carry
/// stored properties). The log list iterates `LoggedEvent` wrappers instead,
/// which attach a fresh `UUID` per decoded line for stable SwiftUI identity.
enum RunEvent: Codable, Equatable {
    /// A tool invocation surfaced for the live activity log.
    case activity(tool: String, detail: String?)
    /// Streamed assistant text (per-turn, not token-streamed).
    case text(chunk: String)
    /// Terminal success line carrying the run summary.
    case done(costUsd: Double, turns: Int, stopReason: String?)
    /// Terminal error line carrying a human-readable message.
    case error(message: String)

    private enum CodingKeys: String, CodingKey {
        case kind, tool, detail, chunk, costUsd, turns, stopReason, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "activity":
            let tool = try container.decode(String.self, forKey: .tool)
            let detail = try container.decodeIfPresent(String.self, forKey: .detail)
            self = .activity(tool: tool, detail: detail)
        case "text":
            let chunk = try container.decode(String.self, forKey: .chunk)
            self = .text(chunk: chunk)
        case "done":
            let costUsd = try container.decode(Double.self, forKey: .costUsd)
            let turns = try container.decode(Int.self, forKey: .turns)
            let stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
            self = .done(costUsd: costUsd, turns: turns, stopReason: stopReason)
        case "error":
            let message = try container.decode(String.self, forKey: .message)
            self = .error(message: message)
        default:
            // Unknown `kind`: throw a clear DecodingError. The caller
            // (`RunEvent.parseLines`) catches per-line decode failures and skips
            // the line, so a future contract addition degrades gracefully
            // rather than aborting the whole stream.
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown RunEvent kind: \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .activity(tool, detail):
            try container.encode("activity", forKey: .kind)
            try container.encode(tool, forKey: .tool)
            try container.encodeIfPresent(detail, forKey: .detail)
        case let .text(chunk):
            try container.encode("text", forKey: .kind)
            try container.encode(chunk, forKey: .chunk)
        case let .done(costUsd, turns, stopReason):
            try container.encode("done", forKey: .kind)
            try container.encode(costUsd, forKey: .costUsd)
            try container.encode(turns, forKey: .turns)
            try container.encodeIfPresent(stopReason, forKey: .stopReason)
        case let .error(message):
            try container.encode("error", forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }

    // MARK: - Newline splitting

    /// Splits a mutable byte buffer on `\n`, decoding each COMPLETE line into a
    /// `RunEvent` and retaining the trailing partial line in `buffer`. Blank
    /// lines and lines that fail to decode (e.g. an unknown `kind` or malformed
    /// JSON) are skipped. Factored out as a pure function so the newline /
    /// partial-line logic is unit-testable without spawning a `Process`.
    static func parseLines(from buffer: inout Data) -> [RunEvent] {
        let newline = UInt8(ascii: "\n")
        var events: [RunEvent] = []
        while let index = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<index]
            // Drop the consumed line plus its newline.
            buffer.removeSubrange(buffer.startIndex...index)
            guard !lineData.isEmpty else { continue }
            if let event = try? JSONDecoder().decode(RunEvent.self, from: Data(lineData)) {
                events.append(event)
            }
        }
        return events
    }
}

/// Which skill the bundled Node runner should drive for a hand-off.
///
/// Mirrors the Node script's `--mode` flag (`run-task.ts`). `execute` runs
/// `plan-execute` in mandatory worktree isolation; `elaborate` runs
/// `plan-elaborate` autonomously to flesh out a pending task, OPTIONALLY folding
/// in a free-text `--description` as the user's guidance for the pass; `capture` runs
/// `plan-capture` autonomously to record a new task from a free-text
/// description (no existing task id); `captureElaborate` runs `plan-capture`
/// then chains into `plan-elaborate` autonomously to record AND flesh out a new
/// task from a free-text description (no existing task id), leaving it
/// `elaborated` (it does NOT execute); `executeYolo` runs
/// `plan-execute "<description>" yolo` to auto-capture, auto-elaborate, and
/// autonomously execute a new task from a free-text description (no existing
/// task id), leaving it in `review`; `reElaborate` runs `plan-elaborate` in
/// Path-C further-elaboration mode on an EXISTING already-elaborated task,
/// folding a free-text `--description` in as the user's refinement guidance —
/// the mode that REQUIRES both an existing task id and a description;
/// `delete` runs `plan-delete` autonomously to permanently remove an EXISTING
/// task's plan file (the in-app confirm having already stood in for the skill's
/// interactive gate), deliberately KEEPING the task's git branch so a single
/// click can never destroy commits.
enum RunMode: String {
    case execute
    case elaborate
    case capture
    case captureElaborate
    case executeYolo
    case reElaborate
    case delete
    /// Defers a pending/elaborated task by driving `plan-backlog` to move its
    /// file from `.plans/pending/` into `.plans/backlog/` (#077 follow-up).
    case backlog
    /// Brings a deferred task back by driving `plan-restore` to move its file
    /// from `.plans/backlog/` into `.plans/pending/`, PRESERVING its status.
    case restore

    /// Whether this mode operates on an EXISTING task, so `TaskRun.spawn` passes
    /// `--task-id <id>`. True for the existing-task modes `.execute` /
    /// `.elaborate` / `.reElaborate` / `.delete` / `.backlog` / `.restore`;
    /// false for the description-driven modes (`.capture` / `.captureElaborate` /
    /// `.executeYolo`), whose task does not exist yet. Pure flag (no I/O) so the
    /// arg-shape contract is unit-testable without spawning a `node` process.
    ///
    /// This is INDEPENDENT of `usesDescription`: `.reElaborate` and `.elaborate`
    /// are the modes where both are true (they work an existing task and may
    /// carry free-text guidance), so `spawn` can emit `--task-id` AND
    /// `--description` for them.
    var usesTaskID: Bool {
        switch self {
        case .execute, .elaborate, .reElaborate, .delete, .backlog, .restore:
            return true
        case .capture, .captureElaborate, .executeYolo:
            return false
        }
    }

    /// Whether this mode carries a free-text `--description`, so `TaskRun.spawn`
    /// passes `--description <text>`. True for the description-driven modes
    /// (`.capture` / `.captureElaborate` / `.executeYolo`), for `.reElaborate`
    /// (which folds the user's refinement guidance in alongside its `--task-id`),
    /// and for `.elaborate`. False for the plain existing-task modes `.execute` /
    /// `.delete`, which are fully identified by their task id alone. Pure flag
    /// (no I/O) so the arg-shape contract is unit-testable without spawning a
    /// `node` process.
    ///
    /// This flag says the description CHANNEL is open, not that a description is
    /// mandatory: `spawn` emits `--description` only when a non-empty one is
    /// actually present. For the capture modes and `.reElaborate` the caller
    /// always supplies one (they are meaningless without it), but `.elaborate`'s
    /// description is OPTIONAL — a bare `/plan-elaborate <id>` run passes `nil`
    /// and simply omits the flag, exactly as before.
    ///
    /// This is INDEPENDENT of `usesTaskID`: a mode can need both (`.reElaborate`,
    /// `.elaborate`) or just one — they are not an either/or, so `spawn` consults
    /// each flag on its own.
    var usesDescription: Bool {
        switch self {
        case .capture, .captureElaborate, .executeYolo, .reElaborate, .elaborate:
            return true
        case .execute, .delete, .backlog, .restore:
            return false
        }
    }
}

/// A `RunEvent` paired with a fresh `UUID` so the SwiftUI log list can iterate
/// `runner.lines` with stable identity (chosen over view-side `.enumerated()`
/// so appends don't re-key earlier rows). One is created per decoded line.
struct LoggedEvent: Identifiable, Equatable {
    let id = UUID()
    let event: RunEvent
}

/// Spawns and supervises the bundled Node Agent-SDK process (`run-task.js`) for
/// a SINGLE task run, decoding its NDJSON progress stream into observable state
/// the detail-view sheet and card rows render.
///
/// One `TaskRun` exists per active task (created and tracked by `TaskRunner`),
/// so multiple tasks can run concurrently — each owns its own `Process`, its own
/// decoded `lines`, and its own `isRunning`/`phase`. The UI observes the run for
/// a specific task, so launching one task's run never disturbs another row.
///
/// Concurrency: the class is `@MainActor`, so all observable mutation is
/// main-actor isolated. The `Process` stdout `readabilityHandler` runs on a
/// background queue, so each decoded chunk hops back to the main actor before
/// touching state. Node resolution shells out on a detached task to avoid
/// blocking the UI, then hops back to spawn.
@MainActor
@Observable
final class TaskRun {
    /// The task id this run is working — also the run's identity. Mutable ONLY
    /// via `rekey(to:)` for the #053 hand-off (a still-running capture being
    /// re-keyed from its synthetic key to the real task id once plans-cc writes
    /// the plan); everything else treats it as fixed.
    private(set) var taskID: String

    /// The mode of this run (`.execute` / `.elaborate` / `.capture`), so the UI
    /// can label it ("Executing #019" vs "Elaborating #019").
    let mode: RunMode

    /// Free-text description for a `.capture` run, threaded to the Node runner's
    /// `--description` flag. Also carries `.reElaborate`'s required refinement
    /// guidance and `.elaborate`'s OPTIONAL guidance. `nil` for `.execute` runs
    /// and for a bare `.elaborate` (identified by their task id alone).
    let description: String?

    /// The project path this run operates in. Set for description-driven capture
    /// runs so `TaskRunner.reconcileFinishedCaptures(against:)` can locate the
    /// matching `ProjectTasks` and detect whether a brand-new task id appeared in
    /// that project since the run began. `nil` for existing-task runs (which are
    /// keyed by a real task id and need no reconciliation).
    let projectPath: String?

    /// The set of task ids that already existed in `projectPath` at the moment
    /// this capture run began. Reconciliation's matching anchor is "a NEW task id
    /// appeared in this project since the run began" — i.e. a task id present now
    /// but absent from this baseline — which is robust against back-to-back
    /// captures and plans-cc rewriting a title (it does NOT match on
    /// description/title strings). Empty for non-capture runs.
    let baselineTaskIDs: Set<String>

    /// Whether this run's elaborate pass should run in "deep" mode (#065). Maps
    /// directly to the valueless `--deep` process flag: when true, `spawn`
    /// appends `--deep` to the Node arguments and the launcher appends a trailing
    /// ` deep` token to its `/plan-elaborate <id>` line. This composes
    /// ORTHOGONALLY with `mode` — it is not a new `RunMode`; it rides alongside
    /// whichever elaborate-bearing mode is selected (captureElaborate,
    /// reElaborate, elaborate). Defaults false for non-deep runs.
    let deep: Bool

    /// Bounded fallback counter for reconciliation. A finished capture that never
    /// observes a new task id (e.g. the underlying run failed, or plans-cc reused
    /// an id) must not stay pinned forever. Each reconcile pass that fails to find
    /// a match increments this; once it reaches `maxReconcileAttempts` the run is
    /// dismissed anyway so the spinner row can't get stuck. Internal mutable
    /// bookkeeping, not part of the observable UI surface.
    var reconcileAttempts = 0

    /// The bounded-fallback ceiling: after this many fruitless reconcile passes a
    /// finished capture is dismissed even without a confirmed new task id. Small
    /// by design — reconciliation runs once per run-finish (one extra pass per
    /// subsequent finish), so a handful of attempts is enough to cover a slow
    /// filesystem flush while still guaranteeing the row clears.
    static let maxReconcileAttempts = 3

    /// True from the moment the run is accepted until the process terminates (or
    /// `stop()` is called). Drives the progress sheet and per-row inline status.
    private(set) var isRunning = false

    /// Coarse lifecycle phase for immediate feedback. `.launching` the instant
    /// the run is accepted (before `node` resolves / the process spawns), so the
    /// UI shows a "Starting…" state with no dead air, then `.running` once the
    /// child process is live, then `nil` when finished.
    enum Phase { case launching, running }
    private(set) var phase: Phase?

    /// The decoded progress stream, in arrival order, for the scrolling log.
    /// Each entry wraps a `RunEvent` with a stable `UUID` for SwiftUI iteration.
    private(set) var lines: [LoggedEvent] = []

    /// Populated from the terminal `done` event: the run's cost and turn count.
    private(set) var summary: (costUsd: Double, turns: Int)?

    /// The raw `done` stop reason, retained for the durable `RunOutcome` record.
    /// Previously the stop reason was consumed by `handle(_:)` (mapped to a
    /// truncation error) and then dropped; keeping it lets the finish path log
    /// exactly WHY a run ended (e.g. `error_max_budget_usd`) — the field that
    /// answers "why did this task strand at in-progress?" after the sheet closes.
    private(set) var lastStopReason: String?

    /// Set in `handleTermination` when the process exited nonzero without any
    /// terminal `done`/`error` line — the "crashed" signal for the outcome log.
    private var exitedNonzeroWithoutTerminal = false

    /// The project path passed to `start(projectPath:)`, captured for the outcome
    /// record. The stored `projectPath` property is only set for description-
    /// driven capture runs (its reconciliation needs it); execute/elaborate runs
    /// leave it `nil` and carry the path through `start` instead, so we stash it
    /// here so the outcome log records the project for EVERY run kind.
    private var outcomeProjectPath: String?

    /// The durable run-outcome writer, invoked once from `finish(...)`. Injectable
    /// so tests can point it at a temp file (and so a test build with no writable
    /// home still works). Defaults to `~/.claude/plans-cc/run-outcomes.log`.
    private let outcomeLog: RunOutcomeLog

    /// Stamps the `RunOutcome.timestamp`. Injectable so tests get a deterministic
    /// value; defaults to the current time as an ISO-8601 string.
    private let now: () -> String

    /// A human-readable error: a missing-node / missing-script precondition, a
    /// `done`-less nonzero exit, or a streamed `error` event's message.
    private(set) var error: String?

    /// The live child process, retained so `stop()` can terminate it.
    private var process: Process?

    /// Accumulates partial stdout bytes across readability chunks; split on
    /// `\n` so only complete NDJSON lines are decoded.
    private var buffer = Data()

    /// Called once when the run terminates (any path), so the coordinator can
    /// drop it from its active map and trigger a store reload.
    private var onFinish: (() -> Void)?

    init(taskID: String, mode: RunMode, description: String? = nil,
         projectPath: String? = nil, baselineTaskIDs: Set<String> = [],
         deep: Bool = false,
         outcomeLog: RunOutcomeLog = RunOutcomeLog(),
         now: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) }) {
        self.taskID = taskID
        self.mode = mode
        self.description = description
        self.projectPath = projectPath
        self.baselineTaskIDs = baselineTaskIDs
        self.deep = deep
        self.outcomeLog = outcomeLog
        self.now = now
    }

    // MARK: - Lifecycle

    /// Launches the bundled Node script for this run's task in `projectPath`.
    /// Resolves the bundled script + `node`, then spawns the process. On a
    /// missing precondition it sets `error` (and leaves `isRunning` false)
    /// instead of spawning. `onFinish` fires exactly once when the run ends.
    func start(projectPath: String, onFinish: @escaping () -> Void) {
        guard !isRunning else { return }
        self.onFinish = onFinish
        self.outcomeProjectPath = projectPath
        runnerLog.notice("start: task=\(self.taskID, privacy: .public) mode=\(self.mode.rawValue, privacy: .public) project=\(projectPath, privacy: .public)")

        lines = []
        summary = nil
        error = nil
        buffer = Data()
        phase = .launching
        isRunning = true

        // Resolve the bundled script first — a synchronous, non-blocking lookup.
        guard let scriptURL = Self.resolveScriptURL() else {
            runnerLog.error("start aborted: bundled run-task.js not found (bundlePath=\(Bundle.main.bundlePath, privacy: .public))")
            finish(error: "Bundled work-task script (run-task.js) not found.")
            return
        }
        runnerLog.notice("resolved script: \(scriptURL.path, privacy: .public)")

        // Resolve `node` off the main actor (it shells out via a login shell),
        // then continue on the main actor to spawn so observable mutation stays
        // main-actor bound. The detached resolution captures no `self`, so the
        // suspension point can't race against later main-actor state access.
        let taskID = self.taskID
        let mode = self.mode
        let description = self.description
        let deep = self.deep
        _Concurrency.Task { [weak self] in
            let nodePath = await _Concurrency.Task.detached {
                TaskRun.resolveNodePath()
            }.value
            guard let self else { return }
            guard self.isRunning else {
                runnerLog.notice("node resolved but run was already stopped; not spawning")
                return
            }
            guard let nodePath else {
                runnerLog.error("start aborted: could not locate node via login shell")
                self.finish(error: "Could not locate `node`. Install Node.js (e.g. via Homebrew or nvm) and try again.")
                return
            }
            runnerLog.notice("resolved node: \(nodePath, privacy: .public)")
            self.spawn(nodePath: nodePath, scriptURL: scriptURL,
                       projectPath: projectPath, taskID: taskID, mode: mode,
                       description: description, deep: deep)
        }
    }

    /// Terminates the live process (if any) and finalizes the run. No-op when
    /// nothing is running.
    func stop() {
        guard isRunning else { return }
        process?.terminate()
        process = nil
        finish(error: nil)
    }

    /// Re-keys this run's identity in place (the #053 hand-off mutator). When a
    /// still-running capture's project gains the real task id (plans-cc has
    /// written the plan while the long `.captureElaborate`/`.executeYolo` process
    /// keeps running), reconciliation moves the live run from its synthetic
    /// `capture:<path>:<UUID>` key to `newID`. This changes ONLY the identity —
    /// the live `Process`, decoded `lines`, `isRunning`/`phase`, `onFinish`
    /// callback, and reconciliation baseline all ride along unchanged — so the
    /// spinner hands off to the real plan row while the process is still tracked.
    func rekey(to newID: String) {
        taskID = newID
    }

    // MARK: - Spawning

    private func spawn(nodePath: String, scriptURL: URL,
                       projectPath: String, taskID: String, mode: RunMode,
                       description: String?, deep: Bool) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        var arguments = [
            scriptURL.path,
            "--project-root", projectPath,
        ]
        // The two arg flags are INDEPENDENT, not either/or. Existing-task modes
        // (execute / elaborate / reElaborate) pass `--task-id`; description-driven
        // modes (capture / captureElaborate / executeYolo) pass `--description`.
        // reElaborate and elaborate are the hybrids that can pass BOTH (they work
        // an existing task using free-text guidance) — reElaborate always carries
        // one, elaborate's is optional, and the `let description` binding below
        // omits the flag when none was supplied. The two flag sets are centralized
        // in `RunMode.usesTaskID` / `RunMode.usesDescription` so the arg-shape
        // contract is unit-testable without spawning a process.
        if mode.usesTaskID {
            arguments += ["--task-id", taskID]
        }
        if mode.usesDescription, let description, !description.isEmpty {
            arguments += ["--description", description]
        }
        arguments += ["--mode", mode.rawValue]
        // `--deep` (#065) is a valueless flag, ORTHOGONAL to the
        // task-id/description split above: it can accompany ANY mode's elaborate
        // pass (captureElaborate / reElaborate / elaborate). Appended AFTER
        // `--mode` so the argument order stays stable/predictable.
        if deep {
            arguments += ["--deep"]
        }
        proc.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Background-queue handler: append bytes to the buffer and decode any
        // complete lines, hopping each batch to the main actor.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            _Concurrency.Task { @MainActor in
                self?.ingest(data)
            }
        }

        proc.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            _Concurrency.Task { @MainActor in
                self?.handleTermination(status: status)
            }
        }

        runnerLog.notice("spawning: \(nodePath, privacy: .public) \(proc.arguments?.joined(separator: " ") ?? "", privacy: .public)")
        do {
            try proc.run()
            process = proc
            phase = .running
            runnerLog.notice("process launched (pid=\(proc.processIdentifier))")
        } catch {
            runnerLog.error("process launch failed: \(error.localizedDescription, privacy: .public)")
            finish(error: "Failed to launch work-task process: \(error.localizedDescription)")
        }
    }

    // MARK: - Stream handling (main actor)

    /// Appends a stdout chunk and dispatches every complete decoded line.
    private func ingest(_ data: Data) {
        buffer.append(data)
        for event in RunEvent.parseLines(from: &buffer) {
            handle(event)
        }
    }

    /// The set of `done` stop reasons that mean the agent was cut short by a cap
    /// (budget or turn limit) rather than finishing the task. When the run stops
    /// for one of these, the work is incomplete and the task was left at
    /// in-progress (it never reached review), so the UI must surface an error.
    /// Centralized here as the single source of truth so it is unit-testable and
    /// reused by `handle(_:)` (mirrors the `static`-helper pattern used for
    /// `RunMode.usesDescription` / `TaskRunner.captureMode`).
    nonisolated static let truncatingStopReasons: Set<String> = [
        "error_max_budget_usd",
        "error_max_turns",
    ]

    /// The `done` stop reason the launcher emits when an `execute` run finished
    /// cleanly (SDK `result` arrived, no cap) BUT the task never reached a
    /// terminal `review` state — it was left stranded at in-progress because
    /// `plan-execute` stopped one layer too early (task #058). This is distinct
    /// from the budget/turn-cap truncation reasons above: the run was not cut
    /// short, it simply handed off without finishing, so it needs its own
    /// user-facing message. Single source of truth for the string — reused by
    /// `RunOutcome.classify` so the literal lives in exactly one Swift file.
    nonisolated static let strandedStopReason = "stranded_at_in_progress"

    /// Maps a `done` event's `stopReason` to a human-readable error message when
    /// the run did not finish the task — either cut short by a budget/turn cap,
    /// or stranded at in-progress without reaching review — or `nil` for a clean
    /// finish (including a missing/normal reason). Pure so the mapping is
    /// unit-testable without spawning a process.
    nonisolated static func truncationError(for stopReason: String?) -> String? {
        guard let stopReason else { return nil }
        if truncatingStopReasons.contains(stopReason) {
            return "Run cut short — agent budget/turn cap hit before completion. "
                + "The task was left at in-progress (it did not reach review). "
                + "Re-run /plan-execute to resume, or raise the budget."
        }
        if stopReason == strandedStopReason {
            return "Run ended but the task never reached review — it was left "
                + "stranded at in-progress. Re-run /plan-execute to finish it."
        }
        return nil
    }

    /// Applies one decoded event to observable state: append to the log, and
    /// fan terminal events out to the dedicated `summary` / `error` fields.
    private func handle(_ event: RunEvent) {
        lines.append(LoggedEvent(event: event))
        switch event {
        case let .done(costUsd, turns, stopReason):
            // Always record the cost/turns summary. When the run did not finish
            // the task — cut short by a cap (budget/turns) OR stranded at
            // in-progress without reaching review (task #058) — ALSO set `error`
            // so the red banner fires above the summary and the user knows to
            // re-run to finish it.
            summary = (costUsd: costUsd, turns: turns)
            lastStopReason = stopReason
            if let failureMessage = Self.truncationError(for: stopReason), error == nil {
                error = failureMessage
            }
        case let .error(message):
            error = message
        case .activity, .text:
            break
        }
    }

    #if DEBUG
    /// Test seam: feeds raw NDJSON bytes through the exact private ingest path
    /// (`ingest` → `parseLines` → `handle`) so unit tests can exercise terminal
    /// event handling without spawning a `Process`. DEBUG-only; not part of the
    /// shipping API.
    func ingestForTesting(_ ndjson: String) {
        ingest(Data(ndjson.utf8))
    }

    /// Test seam: drives the single termination point (`finish`) directly so the
    /// durable `RunOutcome` write can be verified without spawning a `Process`.
    /// `nonzeroCrash` simulates the `handleTermination` nonzero-exit-without-
    /// terminal path (the "crashed" classification). DEBUG-only.
    func finishForTesting(projectPath: String? = nil, error: String? = nil, nonzeroCrash: Bool = false) {
        if let projectPath { outcomeProjectPath = projectPath }
        if nonzeroCrash { exitedNonzeroWithoutTerminal = true }
        finish(error: error)
    }

    /// Test seam: flips the run into the live `.running` state (`isRunning ==
    /// true`) WITHOUT spawning a `Process`, so the #053 re-key path — which only
    /// fires for a still-running capture — is unit-testable. DEBUG-only.
    func markRunningForTesting() {
        isRunning = true
        phase = .running
    }
    #endif

    /// Finalizes a run when the process exits. Surfaces a generic error only if
    /// the process exited nonzero without any `done`/`error` line being seen
    /// (an unexpected crash); a clean `stop()` or a contract-reported terminal
    /// event is left untouched.
    private func handleTermination(status: Int32) {
        // Drain any trailing buffered line that lacked a final newline.
        buffer.append(UInt8(ascii: "\n"))
        for event in RunEvent.parseLines(from: &buffer) {
            handle(event)
        }

        runnerLog.notice("process terminated: task=\(self.taskID, privacy: .public) status=\(status) lines=\(self.lines.count) hasSummary=\(self.summary != nil) hasError=\(self.error != nil)")
        var generic: String?
        if status != 0 && summary == nil && error == nil {
            generic = "Work-task process exited unexpectedly (code \(status))."
            exitedNonzeroWithoutTerminal = true
        }
        process = nil
        finish(error: generic)
    }

    /// Single termination point: optionally records a final error, clears the
    /// running flags, and notifies the coordinator exactly once.
    private func finish(error: String?) {
        if let error, self.error == nil { self.error = error }
        phase = nil
        isRunning = false
        writeOutcome()
        let cb = onFinish
        onFinish = nil
        cb?()
    }

    /// Writes the durable `RunOutcome` for this run exactly once, from the single
    /// termination point. Captures the cost/turns summary, the raw stop reason,
    /// the final error, and the derived classification so a stranded task can be
    /// diagnosed long after the progress sheet has closed. Best-effort — the
    /// writer swallows IO errors so logging never disturbs the finish path.
    /// `projectPath` is `nil` for existing-task runs that never spawned (a
    /// missing-precondition error before `start`'s project was threaded through);
    /// in that case we record an empty string rather than skip the record.
    private func writeOutcome() {
        let classification = RunOutcome.classify(
            stopReason: lastStopReason,
            errorMessage: error,
            exitedNonzeroWithoutTerminal: exitedNonzeroWithoutTerminal
        )
        let outcome = RunOutcome(
            timestamp: now(),
            taskID: taskID,
            mode: mode.rawValue,
            projectPath: projectPath ?? outcomeProjectPath ?? "",
            costUsd: summary?.costUsd ?? 0,
            turns: summary?.turns ?? 0,
            stopReason: lastStopReason,
            errorMessage: error,
            classification: classification
        )
        outcomeLog.append(outcome)
    }

    // MARK: - Resolution helpers

    /// Resolves the bundled `run-task.js`. Returns `nil` when absent (expected
    /// under `swift test` / dev runs where the bundle lacks the resource).
    private static func resolveScriptURL() -> URL? {
        Bundle.main.url(
            forResource: "run-task",
            withExtension: "js",
            subdirectory: "work-task"
        )
    }

    /// A lock-guarded cache of the resolved `node` path, so we only shell out
    /// once per app run even though `resolveNodePath()` is `nonisolated`.
    private final class NodePathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        func get() -> String? { lock.withLock { value } }
        func set(_ path: String) { lock.withLock { value = path } }
    }

    private nonisolated static let nodePathCache = NodePathCache()

    /// Resolves the `node` binary via a login shell so Homebrew/nvm PATHs are
    /// honored. Caches the result. Returns `nil` when `node` is not found or
    /// the shell call fails. Must be called OFF the main actor (it blocks).
    nonisolated static func resolveNodePath() -> String? {
        if let cached = nodePathCache.get() { return cached }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                runnerLog.error("resolveNodePath: `command -v node` exited \(proc.terminationStatus)")
                return nil
            }
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                runnerLog.error("resolveNodePath: `command -v node` returned empty")
                return nil
            }
            nodePathCache.set(path)
            return path
        } catch {
            runnerLog.error("resolveNodePath: failed to run login shell: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Coordinates concurrent task runs. One shared instance is created in
/// `AppDelegate` and injected via `.environment(...)`, so card rows and detail
/// windows resolve the `TaskRun` for a specific task id. Multiple tasks can run
/// at once — each gets its own `TaskRun`.
@MainActor
@Observable
final class TaskRunner {
    /// Active and recently-finished runs, keyed by task id. A run stays in the
    /// map after finishing so the UI can still show its summary/error until the
    /// user dismisses it; launching the same task again replaces the entry.
    private(set) var runs: [String: TaskRun] = [:]

    /// A callback invoked whenever any run finishes, so the app can reload the
    /// store and surface the task's new status. Set by the app at injection.
    var onAnyRunFinished: (() -> Void)?

    init() {}

    /// The run for `taskID`, if one exists (active or finished-but-not-dismissed).
    func run(for taskID: String) -> TaskRun? { runs[taskID] }

    /// True when a run is currently in flight for `taskID`.
    func isRunning(taskID: String) -> Bool { runs[taskID]?.isRunning ?? false }

    /// How many runs are currently in flight across all tasks. This is the single
    /// source of truth the quit-confirmation hook (`applicationShouldTerminate`)
    /// queries to decide whether to prompt before terminating — so the alert and
    /// the live spinner state never disagree. Finished-but-not-dismissed runs stay
    /// in `runs` but are not counted (their `isRunning` is false).
    var runningRunCount: Int { runs.values.filter { $0.isRunning }.count }

    /// Convenience over `runningRunCount` for the common "is anything running?"
    /// branch in the terminate hook.
    var hasRunningRuns: Bool { runningRunCount > 0 }

    /// Launches a run for `taskID` in `projectPath` with `mode`. If a run for
    /// this task is already in flight, this is a no-op; otherwise it replaces any
    /// prior finished run for the task and starts a fresh one. `description` is
    /// the free-text guidance threaded to the runner's `--description` flag for a
    /// `.reElaborate` refinement of an existing task, or the OPTIONAL guidance an
    /// `.elaborate` run may carry; it defaults to `nil` so the plain
    /// existing-task modes (`.execute` / bare `.elaborate`) and all existing call
    /// sites compile unchanged.
    /// `deep` (#065) is orthogonal to mode selection: when true it rides through
    /// to the `TaskRun`'s `--deep` process flag so the run's elaborate pass goes
    /// deep. It has no effect on modes without an elaborate pass (`.execute` /
    /// `.delete`). Defaulted false to keep existing call sites compiling.
    func run(projectPath: String, taskID: String, mode: RunMode = .execute,
             description: String? = nil, deep: Bool = false) {
        if let existing = runs[taskID], existing.isRunning {
            runnerLog.notice("run ignored: task \(taskID, privacy: .public) is already running")
            return
        }
        let taskRun = TaskRun(taskID: taskID, mode: mode, description: description,
                              deep: deep)
        runs[taskID] = taskRun
        taskRun.start(projectPath: projectPath) { [weak self] in
            self?.onAnyRunFinished?()
        }
    }

    /// The synthetic run-identity PREFIX for description-driven runs (capture or
    /// executeYolo) in `projectPath`. There is no real task id at this point, so
    /// each run is keyed under this prefix plus a unique suffix (see
    /// `capture(...)`). The prefix is independent of mode so a project's progress
    /// rows and popovers track either run kind. `runningCaptures(projectPath:)`
    /// filters on `captureKey(projectPath:) + ":"` to gather a project's runs.
    nonisolated static func captureKey(projectPath: String) -> String { "capture:" + projectPath }

    /// The visible description-driven capture/executeYolo rows for `projectPath`,
    /// in a stable order. Matches the per-run keys built by `capture(...)` by
    /// filtering on the `captureKey(projectPath:) + ":"` prefix — the trailing `:`
    /// separator ensures a different project whose path is a string prefix of this
    /// one (e.g. `/a` vs `/ab`) is NOT matched. Sorted by `taskID` so the render
    /// order is stable across polls.
    ///
    /// Hand-off visibility (task #051): this returns EVERY capture run still
    /// present in `runs` for the project — both in-flight runs AND
    /// finished-but-not-yet-reconciled ones — NOT just `isRunning` runs. The
    /// spinner row must persist from process exit until reconciliation confirms
    /// the new plan row has appeared and removes the run from `runs` via
    /// `dismiss(taskID:)`. Because reconciliation (and the manual popover-dismiss
    /// path) is what removes the run from the map, "row visible" is exactly "run
    /// still in `runs`", so the spinner-out / plan-row-in transition is atomic.
    /// An errored capture stays visible INDEFINITELY: reconcile never
    /// auto-dismisses a run whose `error` is set (that silent clearing is how
    /// failed captures used to vanish unread), so only the manual
    /// popover-dismiss clears it. The `captureRow` UI renders a warning glyph
    /// for that state; the clean-run states keep the `ProgressView`, which
    /// reads as "still creating" for the brief hand-off window.
    func runningCaptures(projectPath: String) -> [TaskRun] {
        let prefix = Self.captureKey(projectPath: projectPath) + ":"
        return runs.values
            .filter { $0.taskID.hasPrefix(prefix) }
            .sorted { $0.taskID < $1.taskID }
    }

    /// Launches a description-driven run for `projectPath` from a brand-new
    /// task's `description`. The mode is selected from the flags: when `execute`
    /// is true it runs `plan-execute "<description>" yolo` (mode `.executeYolo`)
    /// to auto-capture, auto-elaborate, and execute it autonomously in a
    /// worktree, leaving it in `review`; otherwise when `elaborate` is true it
    /// runs `plan-capture` then chains into `plan-elaborate` (mode
    /// `.captureElaborate`) to capture AND flesh out the task, leaving it
    /// `elaborated` (it does NOT execute); otherwise (the default) it `capture`s
    /// the task and leaves it `pending`. `execute` takes precedence over
    /// `elaborate`. Because no task id exists yet, the run is tracked under a
    /// UNIQUE per-run identity key (`captureKey(projectPath:) + ":" + UUID()`),
    /// which also becomes the `TaskRun`'s `taskID`. Every submission therefore
    /// starts a fresh, independently-tracked run — captures are no longer guarded
    /// or serialized, so multiple can run back-to-back/concurrently for one
    /// project. Reuses the same start / finish reload path as `run(...)`, so each
    /// new task surfaces on the next store reload.
    /// `knownTaskIDs` is the set of task ids already present in `projectPath` at
    /// submission time, captured by the caller from the current `store.projects`.
    /// It becomes the run's reconciliation baseline so the hand-off can detect a
    /// genuinely NEW task id once plans-cc writes the captured plan. Defaulted to
    /// empty to keep existing call sites compiling; an empty baseline simply means
    /// "any task id present at reconcile time counts as new".
    /// `deep` (#065) is orthogonal to mode selection: when true it rides through
    /// to the `TaskRun`'s `--deep` process flag so the elaborate pass of a
    /// `.captureElaborate` run goes deep. It has no effect on a plain `.capture`
    /// (no elaborate pass) or an `.executeYolo` run (yolo takes no deep keyword),
    /// and does NOT influence `captureMode(...)`. Defaulted false to keep existing
    /// call sites compiling.
    func capture(projectPath: String, description: String, execute: Bool = false, elaborate: Bool = false, deep: Bool = false, knownTaskIDs: Set<String> = []) {
        let key = Self.captureKey(projectPath: projectPath) + ":" + UUID().uuidString
        let mode = Self.captureMode(execute: execute, elaborate: elaborate)
        let taskRun = TaskRun(taskID: key, mode: mode, description: description,
                              projectPath: projectPath, baselineTaskIDs: knownTaskIDs,
                              deep: deep)
        runs[key] = taskRun
        taskRun.start(projectPath: projectPath) { [weak self] in
            self?.onAnyRunFinished?()
        }
    }

    /// The pure mode-selection behind `capture(...)`: Execute wins
    /// (`.executeYolo`), else Elaborate (`.captureElaborate`), else a plain
    /// `.capture`. Extracted as a `static func` so the precedence is unit-testable
    /// without starting a real run (which would spawn `node`). `capture(...)`
    /// calls this so the live behavior and the test share one source of truth.
    nonisolated static func captureMode(execute: Bool, elaborate: Bool) -> RunMode {
        execute ? .executeYolo : (elaborate ? .captureElaborate : .capture)
    }

    /// Stops the run for `taskID`, if any.
    func stop(taskID: String) {
        runs[taskID]?.stop()
    }

    /// Drops a finished run for `taskID` from the map (e.g. when the user closes
    /// its progress sheet). No-op if the run is still in flight.
    func dismiss(taskID: String) {
        if let run = runs[taskID], !run.isRunning {
            runs[taskID] = nil
        }
    }

    // MARK: - Hand-off reconciliation

    /// The pure matching core behind `reconcileFinishedCaptures(against:)`,
    /// extracted as a `static func` so the anchor + bounded-fallback logic is
    /// unit-testable WITHOUT spawning a `node` process (the live `runs` map can
    /// only be populated by `capture()`/`run()`, which spawn). Given the current
    /// runs and the freshly-reloaded projects, it returns the set of run task ids
    /// that should be dismissed — and mutates each examined finished capture's
    /// `reconcileAttempts` so the caller's bounded fallback advances.
    ///
    /// Matching anchor (per task #051): a finished capture is resolved once its
    /// project contains a task id that was NOT in the run's `baselineTaskIDs` (the
    /// ids known when the run began) — i.e. a genuinely NEW id appeared. This is
    /// deliberately id-based, not description/title-based: title matching is
    /// race-prone for back-to-back captures and breaks when plans-cc rewrites the
    /// captured title. Each capture carries its own per-run baseline, so two
    /// back-to-back captures for one project each resolve against the ids they
    /// individually started with and never cross-dismiss.
    ///
    /// Bounded fallback: a finished capture that finds no new id has its
    /// `reconcileAttempts` incremented; once it reaches `maxReconcileAttempts` it
    /// is dismissed anyway so the spinner row can never stay pinned forever (e.g.
    /// the run failed before writing a plan, or the id set didn't change).
    ///
    /// Still-running runs and non-capture runs (no `projectPath`) are ignored.
    static func taskIDsToDismiss(
        runs: [String: TaskRun],
        projects: [ProjectTasks]
    ) -> Set<String> {
        return reconcile(runs: runs, projects: projects).toDismiss
    }

    /// The outcome of one reconciliation pass: which finished captures to dismiss
    /// (their spinner row hands off by removal) and which still-running captures
    /// to re-key (their live run hands off by moving to the real task id —
    /// `[syntheticKey: realID]`). Both surfaces are derived in one pass so the
    /// finished-path and running-path decisions can't disagree about which ids
    /// are already claimed.
    struct CaptureReconciliation: Equatable {
        var toDismiss: Set<String> = []
        var toRekey: [String: String] = [:]
    }

    /// The pure matching core behind `reconcileFinishedCaptures(against:)`,
    /// extended for the #053 hand-off. Returns BOTH the finished-capture
    /// dismissals (identical to the prior `taskIDsToDismiss` behavior) and the
    /// still-running-capture re-keys.
    ///
    /// A still-running capture re-keys (rather than dismisses) so its long
    /// `.captureElaborate`/`.executeYolo` process — which writes the plan file
    /// early but keeps running for minutes — moves to the real task id the moment
    /// that id appears, eliminating the double row (synthetic spinner beside the
    /// real plan row). A re-key only fires when EXACTLY one running capture exists
    /// for the project AND exactly one new id appeared, so a single new id is
    /// never mis-attributed among concurrent captures. A live run never advances
    /// the bounded-fallback counter and is never force-dismissed.
    static func reconcile(
        runs: [String: TaskRun],
        projects: [ProjectTasks]
    ) -> CaptureReconciliation {
        var result = CaptureReconciliation()
        // Index current task ids by project path for O(1) lookup per run.
        var idsByProject: [String: Set<String>] = [:]
        for project in projects {
            idsByProject[project.projectPath] = Set(project.tasks.map(\.id))
        }

        // Ids already used as run keys aren't claimable as a "new" plan id this
        // pass (e.g. a prior re-key's real id, or an existing-task run's id).
        var claimed = Set(runs.keys)

        // How many RUNNING captures exist per project — a re-key only fires when
        // exactly one running capture is in flight for the project, so a single
        // new id can be attributed to it unambiguously.
        var runningCapturesByProject: [String: Int] = [:]
        for run in runs.values where run.isRunning {
            if let projectPath = run.projectPath {
                runningCapturesByProject[projectPath, default: 0] += 1
            }
        }

        for run in runs.values {
            // Only description-driven capture runs (those carrying a projectPath)
            // participate; existing-task runs are keyed by a real id already.
            guard let projectPath = run.projectPath else { continue }

            let currentIDs = idsByProject[projectPath] ?? []
            let newIDs = currentIDs.subtracting(run.baselineTaskIDs).subtracting(claimed)

            if run.isRunning {
                // Hand off a live capture by re-keying to the real id — but only
                // when it can be attributed unambiguously (one running capture
                // for the project, one new id). Never touch the bounded fallback
                // for a live run.
                if runningCapturesByProject[projectPath] == 1, newIDs.count == 1,
                   let realID = newIDs.first {
                    result.toRekey[run.taskID] = realID
                    claimed.insert(realID)
                }
                continue
            }

            // A capture that finished IN ERROR is never auto-dismissed — not by
            // the new-id hand-off, not by the bounded fallback. Auto-dismissal
            // is exactly what made failed captures disappear before the user
            // could read the error (six Ensemble captures were silently
            // swallowed this way when the launcher's API call 400'd). The row
            // persists, rendering its error state, until the user opens the
            // popover and closes it (the manual `dismiss(taskID:)` path).
            if run.error != nil { continue }

            if !newIDs.isEmpty {
                // A genuinely new task id appeared — the captured plan is present.
                result.toDismiss.insert(run.taskID)
                continue
            }

            // No new id yet: advance the bounded fallback and dismiss once the
            // ceiling is hit so the row can't get stuck.
            run.reconcileAttempts += 1
            if run.reconcileAttempts >= TaskRun.maxReconcileAttempts {
                result.toDismiss.insert(run.taskID)
            }
        }
        return result
    }

    /// Reconciles finished capture spinner rows against the freshly-reloaded
    /// `projects`, dismissing each capture whose new plan has now appeared (or
    /// whose bounded fallback has elapsed). Called from the run-finish hand-off
    /// AFTER `store.reload()`, in the same main-actor turn, so SwiftUI paints one
    /// atomic transition (spinner out, plan row in) instead of two frames.
    /// `dismiss(taskID:)` stays idempotent — it only removes a finished, present
    /// run — so a still-running or already-removed run is a safe no-op.
    ///
    /// This is also the deferred terminal-state path for the NEW-TASK launcher
    /// modes (`captureElaborate` / `executeYolo`): the launcher can't run its
    /// #058 stranded-at-in-progress check for them (the new task's id is unknown
    /// at parse time), so it relies on this reconciliation to detect the
    /// newly-created task id post-reload — the accepted first-cut fallback.
    func reconcileFinishedCaptures(against projects: [ProjectTasks]) {
        let decision = Self.reconcile(runs: runs, projects: projects)

        // Apply re-keys FIRST and atomically: move each still-running capture's
        // live run from its synthetic key to the real task id, so the spinner
        // hands off to the real plan row while the process stays tracked.
        for (syntheticKey, realID) in decision.toRekey {
            guard let run = runs[syntheticKey], runs[realID] == nil else { continue }
            run.rekey(to: realID)
            runs[realID] = run
            runs[syntheticKey] = nil
        }

        for taskID in decision.toDismiss {
            dismiss(taskID: taskID)
        }
    }

    #if DEBUG
    /// Test seam: inserts a pre-built `TaskRun` directly into the otherwise
    /// `private(set)` `runs` map so reconciliation can be unit-tested without
    /// spawning a `node` process. DEBUG-only; not part of the shipping API.
    /// (The pure `taskIDsToDismiss(runs:projects:)` helper is the primary test
    /// surface; this exists for tests that prefer to drive the instance method.)
    func ingestRunForTesting(_ run: TaskRun) {
        runs[run.taskID] = run
    }
    #endif
}
