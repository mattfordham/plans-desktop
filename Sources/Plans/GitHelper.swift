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
/// constantly and must stay live. Both methods block and are `nonisolated
/// static`, so callers must invoke them off the main actor.
///
/// Failures are silent toward the UI: a missing repo, an unavailable git, or a
/// launch failure surfaces as `nil` rather than an error. `nil` means
/// "unknown", which the UI should treat differently from a known value.
enum GitHelper {
    /// Returns the name of the currently checked-out branch for the repo at
    /// `projectPath`, via `git -C <path> rev-parse --abbrev-ref HEAD`.
    ///
    /// Returns `nil` when: `projectPath` is empty, the process fails to launch,
    /// git exits non-zero (e.g. the path is not a git repo or git is
    /// unavailable), or the trimmed output is empty. Must be called off the
    /// main actor (it blocks).
    nonisolated static func currentBranch(at projectPath: String) -> String? {
        guard !projectPath.isEmpty else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", projectPath, "rev-parse", "--abbrev-ref", "HEAD"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                gitLog.debug("currentBranch: rev-parse exited \(proc.terminationStatus) for \(projectPath, privacy: .public)")
                return nil
            }
            let branch = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return branch.isEmpty ? nil : branch
        } catch {
            gitLog.error("currentBranch: failed to launch git: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Returns whether the working tree at `projectPath` has uncommitted
    /// changes, via `git -C <path> status --porcelain`.
    ///
    /// Returns `true` when the trimmed output is non-empty (dirty), `false`
    /// when empty (clean), and `nil` when the process fails to launch or git
    /// exits non-zero (e.g. the path is not a git repo or git is unavailable).
    /// A `nil` result means "unknown" — it is **not** the same as "clean". Must
    /// be called off the main actor (it blocks).
    nonisolated static func isDirty(at projectPath: String) -> Bool? {
        guard !projectPath.isEmpty else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", projectPath, "status", "--porcelain"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                gitLog.debug("isDirty: status exited \(proc.terminationStatus) for \(projectPath, privacy: .public)")
                return nil
            }
            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !output.isEmpty
        } catch {
            gitLog.error("isDirty: failed to launch git: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
