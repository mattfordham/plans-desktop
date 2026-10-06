import XCTest
@testable import Plans

/// Tests for `GitHelper.currentBranch(at:)` and `GitHelper.isDirty(at:)`.
///
/// Each test stands up a real git repo (or a bare non-git directory) in a
/// unique UUID-named temp dir, following the same fixture idiom as
/// `PlansStoreTests`. Git is driven via `/usr/bin/git` subprocesses so the
/// tests exercise the same binary the helper shells out to.
final class GitHelperTests: XCTestCase {
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

    /// Runs `git <args...>` inside `dir`, failing the test if git exits non-zero
    /// (unless `allowFailure` is set, for commands expected to fail).
    @discardableResult
    private func git(_ args: [String], in dir: URL, allowFailure: Bool = false) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir.path] + args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if !allowFailure {
            XCTAssertEqual(
                proc.terminationStatus, 0,
                "git \(args.joined(separator: " ")) exited \(proc.terminationStatus)"
            )
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Initializes a git repo in `tempDir`, configures an identity, and makes an
    /// initial commit so `HEAD` resolves.
    private func makeRepoWithCommit() throws {
        try git(["init"], in: tempDir)
        try git(["config", "user.email", "test@example.com"], in: tempDir)
        try git(["config", "user.name", "Test User"], in: tempDir)
        let file = tempDir.appendingPathComponent("README.md")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "README.md"], in: tempDir)
        try git(["commit", "-m", "initial"], in: tempDir)
    }

    // MARK: - currentBranch

    func testCurrentBranchReturnsCheckedOutBranch() throws {
        try makeRepoWithCommit()
        // Force a known branch name so the assertion is precise regardless of
        // the runner's default-branch config (main vs master).
        try git(["checkout", "-b", "testbranch"], in: tempDir)

        XCTAssertEqual(GitHelper.currentBranch(at: tempDir.path), "testbranch")
    }

    func testCurrentBranchOnNonGitDirReturnsNil() throws {
        XCTAssertNil(GitHelper.currentBranch(at: tempDir.path))
    }

    func testCurrentBranchOnEmptyPathReturnsNil() {
        XCTAssertNil(GitHelper.currentBranch(at: ""))
    }

    // MARK: - isDirty

    func testIsDirtyFalseOnCleanRepo() throws {
        try makeRepoWithCommit()
        XCTAssertEqual(GitHelper.isDirty(at: tempDir.path), false)
    }

    func testIsDirtyTrueWithUntrackedFile() throws {
        try makeRepoWithCommit()
        let file = tempDir.appendingPathComponent("untracked.txt")
        try "new\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitHelper.isDirty(at: tempDir.path), true)
    }

    func testIsDirtyTrueWithModifiedTrackedFile() throws {
        try makeRepoWithCommit()
        let file = tempDir.appendingPathComponent("README.md")
        try "hello changed\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitHelper.isDirty(at: tempDir.path), true)
    }

    func testIsDirtyOnNonGitDirReturnsNil() throws {
        XCTAssertNil(GitHelper.isDirty(at: tempDir.path))
    }

    // MARK: - Shared runner

    func testRunReturnsStdoutAndStatus() {
        let result = GitHelper.run(executable: "/bin/echo", arguments: ["hello"], timeout: 5)
        XCTAssertEqual(result?.status, 0)
        XCTAssertEqual(result?.stdout, "hello")
        XCTAssertEqual(result?.ok, true)
    }

    func testRunReturnsNilWhenTimeoutElapses() {
        let start = Date()
        let result = GitHelper.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.3)
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testRunDisablesGitTerminalPrompt() {
        let result = GitHelper.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf %s \"$GIT_TERMINAL_PROMPT\""],
            timeout: 5
        )
        XCTAssertEqual(result?.stdout, "0")
    }

    func testRunReturnsNilWhenExecutableMissing() {
        XCTAssertNil(GitHelper.run(executable: "/nonexistent/bin", arguments: [], timeout: 5))
    }

    // MARK: - Branch-mode fixture helpers

    /// Configures identity and disables signing so fixture commits never depend
    /// on the runner's global git config.
    private func configureIdentity(_ dir: URL) throws {
        try git(["config", "user.email", "test@example.com"], in: dir)
        try git(["config", "user.name", "Test User"], in: dir)
        try git(["config", "commit.gpgsign", "false"], in: dir)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Builds the plans-cc branch-mode layout: a bare `remote.git`, a `project`
    /// clone on `main`, and an orphan `plans` branch (pushed with upstream)
    /// checked out as a worktree at `project/.plans`, excluded from the code
    /// branch via `.git/info/exclude`. Returns the project root.
    private func makeBranchModeProject(setUpstream: Bool = true) throws -> URL {
        let remote = tempDir.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try git(["init", "--bare", "-b", "main"], in: remote)

        let project = tempDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], in: project)
        try configureIdentity(project)
        try git(["remote", "add", "origin", remote.path], in: project)
        try write("code\n", to: project.appendingPathComponent("README.md"))
        try git(["add", "README.md"], in: project)
        try git(["commit", "-m", "initial"], in: project)
        try git(["push", "-u", "origin", "main"], in: project)

        try git(["checkout", "--orphan", "plans"], in: project)
        try git(["rm", "-rf", "--cached", "."], in: project)
        try FileManager.default.removeItem(at: project.appendingPathComponent("README.md"))
        try write("{\"next_id\": 1}\n", to: project.appendingPathComponent("config.json"))
        try git(["add", "config.json"], in: project)
        try git(["commit", "-m", "plans: init"], in: project)
        if setUpstream {
            try git(["push", "-u", "origin", "plans"], in: project)
        }
        try FileManager.default.removeItem(at: project.appendingPathComponent("config.json"))
        try git(["checkout", "-f", "main"], in: project)

        try write(".plans\n", to: project.appendingPathComponent(".git/info/exclude"))
        try git(["worktree", "add", ".plans", "plans"], in: project)
        return project
    }

    /// Clones `remote.git` into `name`, checks out `plans`, and pushes a commit
    /// that writes `contents` to `file`, simulating a plan written elsewhere.
    private func pushFromSecondClone(file: String, contents: String, name: String = "other") throws {
        let other = tempDir.appendingPathComponent(name)
        try git(["clone", "-b", "plans", tempDir.appendingPathComponent("remote.git").path, other.path], in: tempDir)
        try configureIdentity(other)
        try write(contents, to: other.appendingPathComponent(file))
        try git(["add", file], in: other)
        try git(["commit", "-m", "remote change"], in: other)
        try git(["push", "origin", "plans"], in: other)
    }

    private func commitInPlans(_ project: URL, file: String, contents: String) throws {
        let plans = project.appendingPathComponent(".plans")
        try configureIdentity(plans)
        try write(contents, to: plans.appendingPathComponent(file))
        try git(["add", file], in: plans)
        try git(["commit", "-m", "local change"], in: plans)
    }

    // MARK: - hasRemote

    func testHasRemoteFalseForRepoWithoutRemotes() throws {
        try makeRepoWithCommit()
        XCTAssertEqual(GitHelper.hasRemote(at: tempDir.path), false)
    }

    func testHasRemoteTrueWhenAnyRemoteIsConfigured() throws {
        try makeRepoWithCommit()
        try git(["remote", "add", "upstream", "https://example.invalid/repo.git"], in: tempDir)
        XCTAssertEqual(GitHelper.hasRemote(at: tempDir.path), true)
    }

    func testHasRemoteNilOutsideARepo() {
        XCTAssertNil(GitHelper.hasRemote(at: tempDir.path))
        XCTAssertNil(GitHelper.hasRemote(at: ""))
    }

    // MARK: - plansStorageMode

    func testStorageModeNoneWhenRootIsNotARepo() throws {
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent(".plans"),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(GitHelper.plansStorageMode(at: tempDir.path), PlansStorageMode.none)
    }

    func testStorageModeNoneForEmptyPath() {
        XCTAssertEqual(GitHelper.plansStorageMode(at: ""), PlansStorageMode.none)
    }

    func testStorageModeLocalWhenPlansIsIgnored() throws {
        try makeRepoWithCommit()
        try write(".plans/\n", to: tempDir.appendingPathComponent(".gitignore"))
        try write("{}\n", to: tempDir.appendingPathComponent(".plans/config.json"))
        XCTAssertEqual(GitHelper.plansStorageMode(at: tempDir.path), .local)
    }

    func testStorageModeInlineWhenPlansIsNotIgnored() throws {
        try makeRepoWithCommit()
        try write("{}\n", to: tempDir.appendingPathComponent(".plans/config.json"))
        XCTAssertEqual(GitHelper.plansStorageMode(at: tempDir.path), .inline)
    }

    func testStorageModeBranchForPlansWorktree() throws {
        let project = try makeBranchModeProject()
        XCTAssertEqual(GitHelper.plansStorageMode(at: project.path), .branch)
    }

    func testStorageModeBranchThroughSymlinkedPlansInCodeWorktree() throws {
        let project = try makeBranchModeProject()
        let codeWorktree = tempDir.appendingPathComponent("code-wt")
        try git(["worktree", "add", "-b", "feature", codeWorktree.path], in: project)
        try FileManager.default.createSymbolicLink(
            at: codeWorktree.appendingPathComponent(".plans"),
            withDestinationURL: project.appendingPathComponent(".plans")
        )
        XCTAssertEqual(GitHelper.plansStorageMode(at: codeWorktree.path), .branch)
    }

    func testStorageModeNotBranchWhenPlansToplevelEqualsRootToplevel() throws {
        try makeRepoWithCommit()
        // `.plans` resolving to the root itself shares the root's toplevel, so
        // it is not a dedicated worktree.
        try FileManager.default.createSymbolicLink(
            at: tempDir.appendingPathComponent(".plans"),
            withDestinationURL: tempDir
        )
        XCTAssertEqual(GitHelper.plansStorageMode(at: tempDir.path), .inline)
    }

    // MARK: - plansSyncStatus

    func testSyncStatusNilOutsideBranchMode() throws {
        try makeRepoWithCommit()
        try write("{}\n", to: tempDir.appendingPathComponent(".plans/config.json"))
        XCTAssertNil(GitHelper.plansSyncStatus(at: tempDir.path))
    }

    func testSyncStatusInSyncWithUpstream() throws {
        let project = try makeBranchModeProject()
        XCTAssertEqual(
            GitHelper.plansSyncStatus(at: project.path),
            PlansSyncStatus(branch: "plans", remote: "origin", upstream: true,
                            ahead: 0, behind: 0, rebaseStuck: false)
        )
    }

    func testSyncStatusCountsLocalCommitsAsAhead() throws {
        let project = try makeBranchModeProject()
        try commitInPlans(project, file: "a.md", contents: "a\n")
        try commitInPlans(project, file: "b.md", contents: "b\n")
        let status = GitHelper.plansSyncStatus(at: project.path)
        XCTAssertEqual(status?.ahead, 2)
        XCTAssertEqual(status?.behind, 0)
    }

    func testSyncStatusCountsFetchedRemoteCommitsAsBehind() throws {
        let project = try makeBranchModeProject()
        try pushFromSecondClone(file: "remote.md", contents: "r\n")
        try git(["fetch", "origin"], in: project.appendingPathComponent(".plans"))
        let status = GitHelper.plansSyncStatus(at: project.path)
        XCTAssertEqual(status?.ahead, 0)
        XCTAssertEqual(status?.behind, 1)
    }

    func testSyncStatusNoUpstream() throws {
        let project = try makeBranchModeProject(setUpstream: false)
        let status = GitHelper.plansSyncStatus(at: project.path)
        XCTAssertEqual(status?.upstream, false)
        XCTAssertEqual(status?.ahead, 0)
        XCTAssertEqual(status?.behind, 0)
        XCTAssertEqual(status?.branch, "plans")
    }

    func testSyncStatusReadsRemoteAndFallbackBranchFromConfig() throws {
        let project = try makeBranchModeProject()
        let plans = project.appendingPathComponent(".plans")
        try write(
            "{\"sync\": {\"remote\": \"upstream\", \"branch\": \"tracked-plans\"}}\n",
            to: plans.appendingPathComponent("config.json")
        )
        // A detached HEAD reports "HEAD", which falls back to `sync.branch`.
        try git(["checkout", "--detach"], in: plans)
        let status = GitHelper.plansSyncStatus(at: project.path)
        XCTAssertEqual(status?.remote, "upstream")
        XCTAssertEqual(status?.branch, "tracked-plans")
    }

    func testSyncStatusDetectsStuckRebase() throws {
        let project = try makeBranchModeProject()
        let plans = project.appendingPathComponent(".plans")
        try commitInPlans(project, file: "config.json", contents: "{\"next_id\": 2}\n")
        try pushFromSecondClone(file: "config.json", contents: "{\"next_id\": 3}\n")
        try git(["fetch", "origin"], in: plans)
        try git(["rebase", "@{u}"], in: plans, allowFailure: true)

        let status = GitHelper.plansSyncStatus(at: project.path)
        XCTAssertEqual(status?.rebaseStuck, true)
    }
}
