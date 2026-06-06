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

    /// Runs `git <args...>` inside `dir`, failing the test if git exits non-zero.
    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir.path] + args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        XCTAssertEqual(
            proc.terminationStatus, 0,
            "git \(args.joined(separator: " ")) exited \(proc.terminationStatus)"
        )
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
}
