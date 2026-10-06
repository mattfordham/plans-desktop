import XCTest
@testable import Plans

/// Tests for `PlansGitHelper`: the stdout parsers for plans-cc's
/// `plans-git.js sync` / `migrate`, and the invocation path (helper missing,
/// cwd, environment) driven through a stand-in "node" (`/bin/sh`) and a shell
/// script posing as the helper, so no real node or network is needed.
final class PlansGitHelperTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if tempDir != nil,
           FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Writes a shell script standing in for `plans-git.js` and returns its path.
    private func writeFakeHelper(_ body: String) throws -> String {
        let url = tempDir.appendingPathComponent("plans-git.sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// A node resolver that hands back `/bin/sh` as "node", so the fake helper
    /// script runs as `sh <helper> <subcommand>`.
    private let shellAsNode: @Sendable () -> TaskRun.LoginShellEnvironment? = {
        TaskRun.LoginShellEnvironment(nodePath: "/bin/sh", path: "/usr/bin:/bin")
    }

    // MARK: - Sync output parsing

    func testEmptySyncOutputIsSynced() {
        let result = PlansGitHelper.parseSyncOutput("")
        XCTAssertEqual(result.outcome, .synced)
        XCTAssertEqual(result.renumbered, [])
        XCTAssertEqual(result.warnings, [])
    }

    func testRenumberedLinesBecomeRenumberRecords() {
        let output = """
        Renumbered #041 → #043
        Renumbered #042 → #044
        """
        let result = PlansGitHelper.parseSyncOutput(output)
        XCTAssertEqual(result.outcome, .synced)
        XCTAssertEqual(result.renumbered, [
            PlansGitHelper.Renumber(from: "041", to: "043"),
            PlansGitHelper.Renumber(from: "042", to: "044"),
        ])
    }

    func testLockedWarningMapsToLocked() {
        let result = PlansGitHelper.parseSyncOutput(
            "Warning: .plans is locked by another commit (.git-lock); skipped sync"
        )
        XCTAssertEqual(result.outcome, .locked)
        XCTAssertEqual(result.warnings, [".plans is locked by another commit (.git-lock); skipped sync"])
    }

    func testConflictWarningMapsToConflict() {
        let result = PlansGitHelper.parseSyncOutput(
            "Warning: plans sync hit a conflict it cannot resolve automatically — rebase aborted, local plan commits kept; resolve by hand with `git -C .plans pull --rebase`: CONFLICT (content)"
        )
        XCTAssertEqual(result.outcome, .conflict)
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testSyncFailedWarningMapsToFailedWithMessage() {
        let message = "plans sync failed: fatal: unable to access 'https://example.com/': Could not resolve host"
        let result = PlansGitHelper.parseSyncOutput("Warning: \(message)")
        XCTAssertEqual(result.outcome, .failed(message))
    }

    func testUnexpectedHelperFailureMapsToFailed() {
        let message = "plans-git failed unexpectedly: boom"
        let result = PlansGitHelper.parseSyncOutput("Warning: \(message)")
        XCTAssertEqual(result.outcome, .failed(message))
    }

    func testConflictOutranksOtherWarnings() {
        let output = """
        Warning: plans push to origin/plans failed (committed locally; will retry on next push)
        Warning: plans sync hit a conflict it cannot resolve automatically — rebase aborted
        """
        XCTAssertEqual(PlansGitHelper.parseSyncOutput(output).outcome, .conflict)
    }

    func testUnclassifiedWarningsKeepSyncedButAreRetained() {
        let output = """
        Renumbered #010 → #012
        Warning: plans push to origin/plans failed (committed locally; will retry on next push)
        """
        let result = PlansGitHelper.parseSyncOutput(output)
        XCTAssertEqual(result.outcome, .synced)
        XCTAssertEqual(result.renumbered, [PlansGitHelper.Renumber(from: "010", to: "012")])
        XCTAssertEqual(result.warnings, ["plans push to origin/plans failed (committed locally; will retry on next push)"])
    }

    // MARK: - Migrate output parsing

    func testMigrateOKLine() {
        let output = """
        Moved .plans aside to .plans.backup-123
        OK: .plans is on branch plans (pushed to origin/plans)
        """
        let result = PlansGitHelper.parseMigrateOutput(output)
        XCTAssertEqual(result.outcome, .ok(".plans is on branch plans (pushed to origin/plans)"))
        XCTAssertEqual(result.messages, ["Moved .plans aside to .plans.backup-123"])
    }

    func testMigrateErrorWithoutBackup() {
        let result = PlansGitHelper.parseMigrateOutput("Error: .plans is not in local mode")
        XCTAssertEqual(result.outcome, .error(".plans is not in local mode", backupPath: nil))
    }

    func testMigrateErrorExtractsBackupPathBeforeSemicolon() {
        let message = "migration verification failed: 3 files differ — backup kept at /Users/me/My Project/.plans.backup-1; nothing was committed"
        let result = PlansGitHelper.parseMigrateOutput("Warning: something\nError: \(message)")
        XCTAssertEqual(
            result.outcome,
            .error(message, backupPath: "/Users/me/My Project/.plans.backup-1")
        )
        XCTAssertEqual(result.warnings, ["something"])
    }

    func testMigrateErrorExtractsBackupPathAtEndOfLine() {
        let message = "migrate failed unexpectedly: EPERM — backup kept at /tmp/p/.plans.backup-2"
        let result = PlansGitHelper.parseMigrateOutput("Error: \(message)")
        XCTAssertEqual(result.outcome, .error(message, backupPath: "/tmp/p/.plans.backup-2"))
    }

    func testMigrateWithNoResultLineIsAnError() {
        let result = PlansGitHelper.parseMigrateOutput("Warning: plans-git failed unexpectedly: boom")
        XCTAssertEqual(result.outcome, .error("plans-git failed unexpectedly: boom", backupPath: nil))
    }

    // MARK: - Invocation

    func testSyncWithMissingHelperIsHelperMissing() {
        let missing = tempDir.appendingPathComponent("nope.js").path
        let result = PlansGitHelper.sync(
            projectPath: tempDir.path,
            helperPath: missing,
            nodeResolver: shellAsNode
        )
        XCTAssertEqual(result.outcome, .helperMissing)
    }

    func testMigrateWithMissingHelperIsHelperMissing() {
        let missing = tempDir.appendingPathComponent("nope.js").path
        let result = PlansGitHelper.migrate(
            projectPath: tempDir.path,
            helperPath: missing,
            nodeResolver: shellAsNode
        )
        XCTAssertEqual(result.outcome, .helperMissing)
    }

    func testSyncWithoutNodeFails() throws {
        let helper = try writeFakeHelper("echo hi\n")
        let result = PlansGitHelper.sync(
            projectPath: tempDir.path,
            helperPath: helper,
            nodeResolver: { nil }
        )
        guard case .failed = result.outcome else {
            return XCTFail("expected .failed, got \(result.outcome)")
        }
    }

    func testSyncRunsHelperInProjectRootWithBatchModeSSH() throws {
        let helper = try writeFakeHelper("""
        if [ "$1" != "sync" ]; then echo "Warning: plans sync failed: wrong subcommand $1"; exit 0; fi
        if [ "$(pwd -P)" != "$(cd "$EXPECTED_DIR" && pwd -P)" ]; then echo "Warning: plans sync failed: wrong cwd $(pwd)"; exit 0; fi
        if [ "$GIT_SSH_COMMAND" != "ssh -oBatchMode=yes" ]; then echo "Warning: plans sync failed: ssh $GIT_SSH_COMMAND"; exit 0; fi
        if [ "$GIT_TERMINAL_PROMPT" != "0" ]; then echo "Warning: plans sync failed: prompt"; exit 0; fi
        echo "Renumbered #005 → #007"
        """)
        setenv("EXPECTED_DIR", tempDir.path, 1)
        defer { unsetenv("EXPECTED_DIR") }

        let result = PlansGitHelper.sync(
            projectPath: tempDir.path,
            helperPath: helper,
            nodeResolver: shellAsNode
        )
        XCTAssertEqual(result.outcome, .synced, "warnings: \(result.warnings)")
        XCTAssertEqual(result.renumbered, [PlansGitHelper.Renumber(from: "005", to: "007")])
    }

    func testMigrateRunsHelperAndParsesResult() throws {
        let helper = try writeFakeHelper("""
        if [ "$1" != "migrate" ]; then echo "Error: wrong subcommand $1"; exit 0; fi
        echo "OK: .plans is on branch plans (not pushed)"
        """)
        let result = PlansGitHelper.migrate(
            projectPath: tempDir.path,
            helperPath: helper,
            nodeResolver: shellAsNode
        )
        XCTAssertEqual(result.outcome, .ok(".plans is on branch plans (not pushed)"))
    }

    func testSyncTimeoutFails() throws {
        let helper = try writeFakeHelper("sleep 5\n")
        let result = PlansGitHelper.sync(
            projectPath: tempDir.path,
            helperPath: helper,
            nodeResolver: shellAsNode,
            timeout: 0.5
        )
        guard case .failed = result.outcome else {
            return XCTFail("expected .failed, got \(result.outcome)")
        }
    }
}
