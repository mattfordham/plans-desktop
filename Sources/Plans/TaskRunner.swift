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
/// `plan-elaborate` autonomously to flesh out a pending task.
enum RunMode: String {
    case execute
    case elaborate
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
    /// The task id this run is working — also the run's identity.
    let taskID: String

    /// The mode of this run (`.execute` / `.elaborate`), so the UI can label it
    /// ("Executing #019" vs "Elaborating #019").
    let mode: RunMode

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

    init(taskID: String, mode: RunMode) {
        self.taskID = taskID
        self.mode = mode
    }

    // MARK: - Lifecycle

    /// Launches the bundled Node script for this run's task in `projectPath`.
    /// Resolves the bundled script + `node`, then spawns the process. On a
    /// missing precondition it sets `error` (and leaves `isRunning` false)
    /// instead of spawning. `onFinish` fires exactly once when the run ends.
    func start(projectPath: String, onFinish: @escaping () -> Void) {
        guard !isRunning else { return }
        self.onFinish = onFinish
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
                       projectPath: projectPath, taskID: taskID, mode: mode)
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

    // MARK: - Spawning

    private func spawn(nodePath: String, scriptURL: URL,
                       projectPath: String, taskID: String, mode: RunMode) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [
            scriptURL.path,
            "--project-root", projectPath,
            "--task-id", taskID,
            "--mode", mode.rawValue,
        ]

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

    /// Applies one decoded event to observable state: append to the log, and
    /// fan terminal events out to the dedicated `summary` / `error` fields.
    private func handle(_ event: RunEvent) {
        lines.append(LoggedEvent(event: event))
        switch event {
        case let .done(costUsd, turns, _):
            summary = (costUsd: costUsd, turns: turns)
        case let .error(message):
            error = message
        case .activity, .text:
            break
        }
    }

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
        let cb = onFinish
        onFinish = nil
        cb?()
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

    /// Launches a run for `taskID` in `projectPath` with `mode`. If a run for
    /// this task is already in flight, this is a no-op; otherwise it replaces any
    /// prior finished run for the task and starts a fresh one.
    func run(projectPath: String, taskID: String, mode: RunMode = .execute) {
        if let existing = runs[taskID], existing.isRunning {
            runnerLog.notice("run ignored: task \(taskID, privacy: .public) is already running")
            return
        }
        let taskRun = TaskRun(taskID: taskID, mode: mode)
        runs[taskID] = taskRun
        taskRun.start(projectPath: projectPath) { [weak self] in
            self?.onAnyRunFinished?()
        }
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
}
