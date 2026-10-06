import Foundation
import OSLog

/// Subsystem logger for git queries. View with:
///   log stream --predicate 'subsystem == "com.plans.desktop"' --level debug
private let gitLog = Logger(subsystem: "com.plans.desktop", category: "GitHelper")

/// Reads live git state for a project directory by shelling out to
/// `/usr/bin/git`, mirroring the subprocess pattern in
/// `TaskRunner.resolveNodePath()`.
///
/// State is queried fresh on every call — there is intentionally **no
/// caching** — because a project's branch and working-tree status change
/// constantly and must stay live. Every method blocks and is `nonisolated
/// static`, so callers must invoke them off the main actor.
///
/// Failures are silent toward the UI: a missing repo, an unavailable git, a
/// launch failure, or a timeout surfaces as `nil` rather than an error. `nil`
/// means "unknown", which the UI should treat differently from a known value.
enum GitHelper {
    /// The outcome of one finished subprocess: its exit status plus trimmed
    /// stdout / stderr.
    struct ProcessResult: Sendable, Equatable {
        let status: Int32
        let stdout: String
        let stderr: String

        var ok: Bool { status == 0 }
    }

    /// How long a single git query may run before it is killed. These are all
    /// local, read-only commands, so anything this slow is wedged (a hung
    /// filesystem, a stuck credential helper) rather than busy.
    static let defaultTimeout: TimeInterval = 10

    private static let gitPath = "/usr/bin/git"

    /// Runs `executable` with `arguments`, returning its exit status and
    /// trimmed output, or `nil` when it fails to launch or does not exit within
    /// `timeout` seconds (in which case it is terminated).
    ///
    /// The child gets `environment` (the app's own environment when `nil`) plus
    /// `GIT_TERMINAL_PROMPT=0`, so git can never block on an interactive
    /// credential prompt, and `/dev/null` as stdin. It runs in
    /// `currentDirectory` when one is given. Both pipes are drained concurrently
    /// so a chatty child cannot deadlock on a full pipe buffer while we wait for
    /// it.
    nonisolated static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        timeout: TimeInterval = defaultTimeout
    ) -> ProcessResult? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        var childEnvironment = environment ?? ProcessInfo.processInfo.environment
        childEnvironment["GIT_TERMINAL_PROMPT"] = "0"
        proc.environment = childEnvironment
        if let currentDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        proc.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }

        do {
            try proc.run()
        } catch {
            gitLog.error("run: failed to launch \(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let output = OutputBox()
        let reads = DispatchGroup()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        reads.enter()
        DispatchQueue.global(qos: .utility).async {
            output.setStdout(outHandle.readDataToEndOfFile())
            reads.leave()
        }
        reads.enter()
        DispatchQueue.global(qos: .utility).async {
            output.setStderr(errHandle.readDataToEndOfFile())
            reads.leave()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            gitLog.error("run: \(executable, privacy: .public) \(arguments.joined(separator: " "), privacy: .public) timed out after \(timeout)s")
            return nil
        }
        // A grandchild that inherited the pipes can hold them open past the
        // child's exit; don't let it stall us — take whatever was read.
        _ = reads.wait(timeout: .now() + 1)

        let (stdout, stderr) = output.snapshot()
        return ProcessResult(
            status: proc.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Runs `git -C <directory> <args...>` through `run(executable:arguments:timeout:)`.
    nonisolated static func git(
        _ args: [String],
        in directory: String,
        timeout: TimeInterval = defaultTimeout
    ) -> ProcessResult? {
        run(executable: gitPath, arguments: ["-C", directory] + args, timeout: timeout)
    }

    /// Lock-guarded accumulator for the two pipe reads, which complete on
    /// background queues.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()

        func setStdout(_ data: Data) { lock.withLock { stdout = data } }
        func setStderr(_ data: Data) { lock.withLock { stderr = data } }
        func snapshot() -> (Data, Data) { lock.withLock { (stdout, stderr) } }
    }

    // MARK: - Branch / dirty

    /// Returns the name of the currently checked-out branch for the repo at
    /// `projectPath`, via `git -C <path> rev-parse --abbrev-ref HEAD`.
    ///
    /// Returns `nil` when: `projectPath` is empty, the process fails to launch
    /// or times out, git exits non-zero (e.g. the path is not a git repo or git
    /// is unavailable), or the trimmed output is empty. Must be called off the
    /// main actor (it blocks).
    nonisolated static func currentBranch(at projectPath: String) -> String? {
        guard !projectPath.isEmpty,
              let result = git(["rev-parse", "--abbrev-ref", "HEAD"], in: projectPath) else {
            return nil
        }
        guard result.ok else {
            gitLog.debug("currentBranch: rev-parse exited \(result.status) for \(projectPath, privacy: .public)")
            return nil
        }
        return result.stdout.isEmpty ? nil : result.stdout
    }

    /// Returns whether the working tree at `projectPath` has uncommitted
    /// changes, via `git -C <path> status --porcelain`.
    ///
    /// Returns `true` when the trimmed output is non-empty (dirty), `false`
    /// when empty (clean), and `nil` when the process fails to launch, times
    /// out, or git exits non-zero (e.g. the path is not a git repo or git is
    /// unavailable). A `nil` result means "unknown" — it is **not** the same as
    /// "clean". Must be called off the main actor (it blocks).
    nonisolated static func isDirty(at projectPath: String) -> Bool? {
        guard !projectPath.isEmpty,
              let result = git(["status", "--porcelain"], in: projectPath) else {
            return nil
        }
        guard result.ok else {
            gitLog.debug("isDirty: status exited \(result.status) for \(projectPath, privacy: .public)")
            return nil
        }
        return !result.stdout.isEmpty
    }

    /// Returns whether the repo at `projectPath` has any remote configured, via
    /// `git -C <path> remote`. `nil` when it is not a repo or git fails, which
    /// the UI treats as "unknown", not "no remote". Must be called off the main
    /// actor (it blocks).
    nonisolated static func hasRemote(at projectPath: String) -> Bool? {
        guard !projectPath.isEmpty,
              let result = git(["remote"], in: projectPath),
              result.ok else {
            return nil
        }
        return !result.stdout.isEmpty
    }

    // MARK: - plans-cc storage mode

    /// Resolves where the project's `.plans/` lives. A port of `detectMode` in
    /// plans-cc `lib/plans-git.js` — keep the two in step.
    ///
    /// - `.none` when the root is not a git repo (even if `.plans` is one).
    /// - `.branch` when `.plans` is the toplevel of its OWN worktree: its
    ///   toplevel realpath equals realpath(`.plans`) and differs from the
    ///   root's toplevel.
    /// - `.local` when the root repo ignores `.plans` (`check-ignore -q`).
    /// - `.inline` otherwise.
    ///
    /// Must be called off the main actor (it blocks).
    nonisolated static func plansStorageMode(at root: String) -> PlansStorageMode {
        guard !root.isEmpty,
              let rootTop = git(["rev-parse", "--show-toplevel"], in: root),
              rootTop.ok else {
            return .none
        }

        let plansDir = (root as NSString).appendingPathComponent(".plans")
        if FileManager.default.fileExists(atPath: plansDir),
           let plansTop = git(["rev-parse", "--show-toplevel"], in: plansDir),
           plansTop.ok {
            let plansTopReal = realpath(plansTop.stdout)
            if plansTopReal == realpath(plansDir),
               plansTopReal != realpath(rootTop.stdout) {
                return .branch
            }
        }

        if git(["check-ignore", "-q", ".plans"], in: root)?.ok == true {
            return .local
        }
        return .inline
    }

    /// Read-only sync state of a branch-mode `.plans` worktree, or `nil` when
    /// the project is not in branch mode. A port of `syncStatus` in plans-cc
    /// `lib/plans-git.js` — keep the two in step. It never fetches, never takes
    /// the `.plans/.git-lock`, and never writes, so `behind` is as of the last
    /// fetch.
    ///
    /// Pass a `mode` already resolved by `plansStorageMode(at:)` to skip
    /// re-detecting it. Must be called off the main actor (it blocks).
    nonisolated static func plansSyncStatus(
        at root: String,
        mode knownMode: PlansStorageMode? = nil
    ) -> PlansSyncStatus? {
        guard !root.isEmpty else { return nil }
        let mode = knownMode ?? plansStorageMode(at: root)
        guard mode == .branch else { return nil }

        let plansDir = (root as NSString).appendingPathComponent(".plans")
        let config = readSyncConfig(root: root)
        let head = git(["rev-parse", "--abbrev-ref", "HEAD"], in: plansDir)
        let branch: String
        if let head, head.ok, !head.stdout.isEmpty, head.stdout != "HEAD" {
            branch = head.stdout
        } else {
            branch = config.branch
        }

        var upstream = false
        var ahead = 0
        var behind = 0
        let upstreamRef = git(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            in: plansDir
        )
        if upstreamRef?.ok == true {
            upstream = true
            if let counts = git(["rev-list", "--left-right", "--count", "HEAD...@{u}"], in: plansDir),
               counts.ok {
                let parts = counts.stdout.split(whereSeparator: \.isWhitespace)
                if parts.count == 2, let left = Int(parts[0]), let right = Int(parts[1]) {
                    ahead = left
                    behind = right
                }
            }
        }

        return PlansSyncStatus(
            branch: branch,
            remote: config.remote,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            rebaseStuck: rebaseInProgress(in: plansDir)
        )
    }

    /// Whether a rebase is in progress in `dir`: git keeps a `rebase-merge` or
    /// `rebase-apply` directory under the (per-worktree) git dir until the
    /// rebase is continued or aborted.
    private nonisolated static func rebaseInProgress(in dir: String) -> Bool {
        ["rebase-merge", "rebase-apply"].contains { name in
            guard let result = git(["rev-parse", "--git-path", name], in: dir), result.ok else {
                return false
            }
            let path = result.stdout.hasPrefix("/")
                ? result.stdout
                : (dir as NSString).appendingPathComponent(result.stdout)
            return FileManager.default.fileExists(atPath: path)
        }
    }

    /// The `sync` key of `.plans/config.json`, defaulting per key to
    /// `remote: "origin"` / `branch: "plans"` when absent or malformed.
    private nonisolated static func readSyncConfig(root: String) -> (remote: String, branch: String) {
        var remote = "origin"
        var branch = "plans"
        let url = URL(fileURLWithPath: root)
            .appendingPathComponent(".plans")
            .appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sync = object["sync"] as? [String: Any] {
            if let value = sync["remote"] as? String, !value.isEmpty { remote = value }
            if let value = sync["branch"] as? String, !value.isEmpty { branch = value }
        }
        return (remote, branch)
    }

    /// `realpath(3)`, degrading to a standardized absolute path when the path
    /// cannot be resolved, so comparisons still work for missing paths.
    private nonisolated static func realpath(_ path: String) -> String {
        if let resolved = Darwin.realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
