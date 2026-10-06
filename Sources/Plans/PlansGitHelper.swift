import Foundation
import OSLog

/// Subsystem logger for plans-git helper invocations. View with:
///   log stream --predicate 'subsystem == "com.plans.desktop"' --level debug
private let helperLog = Logger(subsystem: "com.plans.desktop", category: "PlansGitHelper")

/// Invokes plans-cc's `plans-git.js` helper (`sync` / `migrate`) as a
/// subprocess and parses its stdout.
///
/// The helper owns every write it makes to a project's `.plans/` worktree
/// (locking, rebase, renumbering, counters, push); the app only launches it and
/// reads the lines it prints. Its stdout contract:
/// - `Renumbered #A → #B` — one line per task moved off a colliding id.
/// - `Warning: …` — any problem; the exit code is always 0.
/// - setup commands (`migrate`) end with exactly one `OK: …` or `Error: …` line.
///
/// Every invocation blocks and is `nonisolated static`, so callers must run it
/// off the main actor.
enum PlansGitHelper {
    /// One task moved to a new id because its id collided with a remote one.
    struct Renumber: Equatable, Sendable {
        let from: String
        let to: String
    }

    /// How a `sync` ended, from the most significant `Warning:` line.
    enum SyncOutcome: Equatable, Sendable {
        /// No classified warning. Also what a project with no upstream reports,
        /// since the helper prints nothing in that case.
        case synced
        /// Another plans-cc commit held `.plans/.git-lock`; nothing was pulled.
        case locked
        /// The pull hit a conflict; the helper aborted the rebase and kept the
        /// local commits.
        case conflict
        /// The pull (or the helper itself) failed, including being offline.
        case failed(String)
        /// No helper script exists at the expected path.
        case helperMissing
    }

    struct SyncResult: Equatable, Sendable {
        let outcome: SyncOutcome
        let renumbered: [Renumber]
        /// Every `Warning:` line's text, in order, without the prefix.
        let warnings: [String]

        init(outcome: SyncOutcome, renumbered: [Renumber] = [], warnings: [String] = []) {
            self.outcome = outcome
            self.renumbered = renumbered
            self.warnings = warnings
        }
    }

    /// How a `migrate` ended, from its final `OK:` / `Error:` line.
    enum MigrateOutcome: Equatable, Sendable {
        case ok(String)
        /// The error text, plus the `backup kept at <path>` location when the
        /// helper left the original `.plans/` in a backup directory.
        case error(String, backupPath: String?)
        case helperMissing
    }

    struct MigrateResult: Equatable, Sendable {
        let outcome: MigrateOutcome
        /// Informational lines that are neither warnings nor the result line.
        let messages: [String]
        let warnings: [String]

        init(outcome: MigrateOutcome, messages: [String] = [], warnings: [String] = []) {
            self.outcome = outcome
            self.messages = messages
            self.warnings = warnings
        }
    }

    typealias NodeResolver = @Sendable () -> TaskRun.LoginShellEnvironment?

    /// The installed helper, `~/.claude/plans-cc/plans-git.js`.
    nonisolated static var defaultHelperPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/plans-cc/plans-git.js")
            .path
    }

    /// `sync` pulls over the network; with batch-mode ssh and no terminal
    /// prompts an unreachable remote fails fast, so this only bounds a
    /// genuinely wedged transfer.
    static let syncTimeout: TimeInterval = 60

    /// `migrate` copies and verifies every file and may push, so it gets longer.
    static let migrateTimeout: TimeInterval = 180

    private static let warningPrefix = "Warning: "
    private static let okPrefix = "OK: "
    private static let errorPrefix = "Error: "
    private static let backupMarker = "backup kept at "

    // MARK: - Invocation

    /// Runs `plans-git.js sync` in `projectPath` and parses its output.
    nonisolated static func sync(
        projectPath: String,
        helperPath: String = defaultHelperPath,
        nodeResolver: NodeResolver = { TaskRun.resolveLoginEnvironment() },
        timeout: TimeInterval = syncTimeout
    ) -> SyncResult {
        switch invoke(
            subcommand: "sync",
            projectPath: projectPath,
            helperPath: helperPath,
            nodeResolver: nodeResolver,
            timeout: timeout
        ) {
        case .helperMissing:
            return SyncResult(outcome: .helperMissing)
        case .failed(let message):
            return SyncResult(outcome: .failed(message))
        case .finished(let stdout):
            return parseSyncOutput(stdout)
        }
    }

    /// Runs `plans-git.js migrate` in `projectPath` and parses its output.
    nonisolated static func migrate(
        projectPath: String,
        helperPath: String = defaultHelperPath,
        nodeResolver: NodeResolver = { TaskRun.resolveLoginEnvironment() },
        timeout: TimeInterval = migrateTimeout
    ) -> MigrateResult {
        switch invoke(
            subcommand: "migrate",
            projectPath: projectPath,
            helperPath: helperPath,
            nodeResolver: nodeResolver,
            timeout: timeout
        ) {
        case .helperMissing:
            return MigrateResult(outcome: .helperMissing)
        case .failed(let message):
            return MigrateResult(outcome: .error(message, backupPath: nil))
        case .finished(let stdout):
            return parseMigrateOutput(stdout)
        }
    }

    private enum Invocation {
        case helperMissing
        case failed(String)
        case finished(String)
    }

    /// Runs `node <helper> <subcommand>` with the project root as cwd. The
    /// child gets the login-shell PATH (so a Dock-launched app still finds the
    /// node the user's shell would) and batch-mode ssh, so git can never stall
    /// on a passphrase or host-key prompt.
    private nonisolated static func invoke(
        subcommand: String,
        projectPath: String,
        helperPath: String,
        nodeResolver: NodeResolver,
        timeout: TimeInterval
    ) -> Invocation {
        guard FileManager.default.fileExists(atPath: helperPath) else {
            helperLog.error("\(subcommand, privacy: .public): helper not found at \(helperPath, privacy: .public)")
            return .helperMissing
        }
        guard let login = nodeResolver(), let nodePath = login.nodePath else {
            helperLog.error("\(subcommand, privacy: .public): could not locate node")
            return .failed("Could not locate `node`; plans-git \(subcommand) did not run.")
        }

        var environment = TaskRun.buildChildEnvironment(
            base: ProcessInfo.processInfo.environment,
            loginPath: login.path,
            nodePath: nodePath
        )
        environment["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes"

        guard let result = GitHelper.run(
            executable: nodePath,
            arguments: [helperPath, subcommand],
            environment: environment,
            currentDirectory: projectPath,
            timeout: timeout
        ) else {
            return .failed("plans-git \(subcommand) did not finish within \(Int(timeout))s or could not be launched")
        }
        if !result.stderr.isEmpty {
            helperLog.debug("\(subcommand, privacy: .public) stderr: \(result.stderr, privacy: .public)")
        }
        return .finished(result.stdout)
    }

    // MARK: - Parsing

    /// Parses `sync` stdout. The outcome is the most significant classified
    /// warning: conflict, then locked, then failed. Unclassified warnings (a
    /// failed push, a renumber left for hand resolution) leave the outcome
    /// `.synced` but are kept in `warnings`.
    nonisolated static func parseSyncOutput(_ stdout: String) -> SyncResult {
        var renumbered: [Renumber] = []
        var warnings: [String] = []
        var conflict = false
        var locked = false
        var failure: String?

        for line in lines(of: stdout) {
            if let renumber = parseRenumber(line) {
                renumbered.append(renumber)
            } else if line.hasPrefix(warningPrefix) {
                let warning = String(line.dropFirst(warningPrefix.count))
                warnings.append(warning)
                if warning.contains("conflict it cannot resolve automatically") {
                    conflict = true
                } else if warning.contains("locked by another commit") {
                    locked = true
                } else if failure == nil,
                          warning.hasPrefix("plans sync failed") || warning.hasPrefix("plans-git failed") {
                    failure = warning
                }
            }
        }

        let outcome: SyncOutcome
        if conflict {
            outcome = .conflict
        } else if locked {
            outcome = .locked
        } else if let failure {
            outcome = .failed(failure)
        } else {
            outcome = .synced
        }
        return SyncResult(outcome: outcome, renumbered: renumbered, warnings: warnings)
    }

    /// Parses `migrate` stdout. The last `OK:` / `Error:` line is the result;
    /// output with neither (the helper crashed) is an error carrying the last
    /// warning.
    nonisolated static func parseMigrateOutput(_ stdout: String) -> MigrateResult {
        var messages: [String] = []
        var warnings: [String] = []
        var outcome: MigrateOutcome?

        for line in lines(of: stdout) {
            if line.hasPrefix(okPrefix) {
                outcome = .ok(String(line.dropFirst(okPrefix.count)))
            } else if line.hasPrefix(errorPrefix) {
                let message = String(line.dropFirst(errorPrefix.count))
                outcome = .error(message, backupPath: backupPath(in: message))
            } else if line.hasPrefix(warningPrefix) {
                warnings.append(String(line.dropFirst(warningPrefix.count)))
            } else {
                messages.append(line)
            }
        }

        let resolved = outcome ?? .error(
            warnings.last ?? "plans-git migrate printed no result",
            backupPath: nil
        )
        return MigrateResult(outcome: resolved, messages: messages, warnings: warnings)
    }

    /// The path following `backup kept at `, up to the next `; ` or the end of
    /// the message. Paths may contain spaces.
    nonisolated static func backupPath(in message: String) -> String? {
        guard let marker = message.range(of: backupMarker) else { return nil }
        let rest = message[marker.upperBound...]
        let path = rest.range(of: "; ").map { rest[..<$0.lowerBound] } ?? rest
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func lines(of stdout: String) -> [String] {
        stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Parses `Renumbered #A → #B`.
    private nonisolated static func parseRenumber(_ line: String) -> Renumber? {
        guard line.hasPrefix("Renumbered #") else { return nil }
        let body = line.dropFirst("Renumbered #".count)
        guard let arrow = body.range(of: " → #") else { return nil }
        let from = String(body[..<arrow.lowerBound])
        let to = String(body[arrow.upperBound...])
        guard !from.isEmpty, !to.isEmpty,
              from.allSatisfy(\.isNumber), to.allSatisfy(\.isNumber) else { return nil }
        return Renumber(from: from, to: to)
    }
}
