import Foundation
import Observation

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

/// A `RunEvent` paired with a fresh `UUID` so the SwiftUI log list can iterate
/// `runner.lines` with stable identity (chosen over view-side `.enumerated()`
/// so appends don't re-key earlier rows). One is created per decoded line.
struct LoggedEvent: Identifiable, Equatable {
    let id = UUID()
    let event: RunEvent
}

/// Spawns and supervises the bundled Node Agent-SDK process (`run-task.js`) for
/// a single "Work this task" run, decoding its NDJSON progress stream into
/// observable state the detail-view sheet renders.
///
/// One shared instance is created in `AppDelegate` and injected via
/// `.environment(...)` (segment 3) so it is shared across detail windows — only
/// one run is supported at a time (`isRunning` guards double-launch).
///
/// Concurrency: the class is `@MainActor`, so all observable mutation is
/// main-actor isolated. The `Process` stdout `readabilityHandler` runs on a
/// background queue, so each decoded chunk hops back to the main actor before
/// touching state. Node resolution shells out on a detached task to avoid
/// blocking the UI, then hops back to spawn.
@MainActor
@Observable
final class TaskRunner {
    /// True from the moment `run` accepts a launch until the process terminates
    /// (or `stop()` is called). Drives the progress sheet and button disabling.
    private(set) var isRunning = false

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

    init() {}

    // MARK: - Public API

    /// Launches the bundled Node script for `taskID` in `projectPath`. Guards
    /// against double-launch while a run is in flight, resets prior run state,
    /// then resolves `node` + the bundled script. On a missing precondition it
    /// sets `error` (and leaves `isRunning` false) instead of spawning.
    func run(projectPath: String, taskID: String) {
        guard !isRunning else { return }

        // Reset prior run state.
        lines = []
        summary = nil
        error = nil
        buffer = Data()
        isRunning = true

        // Resolve the bundled script first — a synchronous, non-blocking lookup.
        guard let scriptURL = Self.resolveScriptURL() else {
            error = "Bundled work-task script (run-task.js) not found."
            isRunning = false
            return
        }

        // Resolve `node` off the main actor (it shells out via a login shell),
        // then continue on the main actor to spawn so observable mutation stays
        // main-actor bound. The detached resolution captures no `self`, so the
        // suspension point can't race against later main-actor state access.
        _Concurrency.Task { [weak self] in
            let nodePath = await _Concurrency.Task.detached {
                Self.resolveNodePath()
            }.value
            guard let self else { return }
            // A late `stop()` could have flipped this off; honor it.
            guard self.isRunning else { return }
            guard let nodePath else {
                self.error = "Could not locate `node`. Install Node.js (e.g. via Homebrew or nvm) and try again."
                self.isRunning = false
                return
            }
            self.spawn(nodePath: nodePath, scriptURL: scriptURL,
                       projectPath: projectPath, taskID: taskID)
        }
    }

    /// Terminates the live process (if any) and clears the running flag. No-op
    /// when nothing is running.
    func stop() {
        guard isRunning else { return }
        process?.terminate()
        process = nil
        isRunning = false
    }

    // MARK: - Spawning

    private func spawn(nodePath: String, scriptURL: URL,
                       projectPath: String, taskID: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [
            scriptURL.path,
            "--project-root", projectPath,
            "--task-id", taskID,
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

        do {
            try proc.run()
            process = proc
        } catch {
            self.error = "Failed to launch work-task process: \(error.localizedDescription)"
            isRunning = false
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

        if status != 0 && summary == nil && error == nil {
            error = "Work-task process exited unexpectedly (code \(status))."
        }
        process = nil
        isRunning = false
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
            guard proc.terminationStatus == 0 else { return nil }
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            nodePathCache.set(path)
            return path
        } catch {
            return nil
        }
    }
}
