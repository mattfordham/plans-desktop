import XCTest
@testable import Plans

/// Tests for `PlansStore.reload()`, exercising the wiring of the (verbatim,
/// already-tested) `RegistryReader` → `TaskParser` read path via dependency
/// injection. Fixtures use the same UUID temp-dir pattern as
/// `RegistryReaderTests`/`TaskParserTests`.
final class PlansStoreTests: XCTestCase {
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
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Writes a task file `filename` containing `text` into
    /// `<projectDir>/.plans/<subdir>/`, creating intermediate dirs as needed.
    private func writeTaskFile(
        projectDir: URL,
        filename: String,
        text: String,
        in subdir: String
    ) throws {
        let dir = projectDir
            .appendingPathComponent(".plans")
            .appendingPathComponent(subdir)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        try text.write(
            to: dir.appendingPathComponent(filename),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Creates a project dir under the temp dir with a `.plans/` directory and
    /// returns its URL.
    private func makeProjectDir(name: String) throws -> URL {
        let projectDir = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: projectDir.appendingPathComponent(".plans"),
            withIntermediateDirectories: true
        )
        return projectDir
    }

    /// Writes a `projects.json` registry in the temp dir listing the given
    /// project paths and returns a `RegistryReader` pointed at it.
    private func makeReader(projectPaths: [String]) throws -> RegistryReader {
        let entries = projectPaths
            .map { #"{ "path": "\#($0)", "lastSeen": "2026-06-04T14:41:00Z" }"# }
            .joined(separator: ",\n")
        let json = """
        {
          "version": 1,
          "projects": [
        \(entries)
          ]
        }
        """
        let registryURL = tempDir.appendingPathComponent("projects.json")
        try json.write(to: registryURL, atomically: true, encoding: .utf8)
        return RegistryReader(registryURL: registryURL)
    }

    // MARK: - reload()

    func testReloadPopulatesProjectsWithCounts() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )
        try writeTaskFile(
            projectDir: projectDir,
            filename: "002-second.md",
            text: "# Second\n\n**Status:** in-progress",
            in: "pending"
        )
        try writeTaskFile(
            projectDir: projectDir,
            filename: "003-done.md",
            text: "# Done\n\n**Status:** completed",
            in: "completed"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)
        store.reload()

        XCTAssertEqual(store.projects.count, 1)
        let project = try XCTUnwrap(store.projects.first)
        XCTAssertEqual(project.projectName, "alpha")
        XCTAssertEqual(project.counts[.pending], 1)
        XCTAssertEqual(project.counts[.inProgress], 1)
        XCTAssertEqual(project.counts[.completed], 1)
    }

    func testReloadHandlesMultipleProjectsInRegistryOrder() throws {
        let alpha = try makeProjectDir(name: "alpha")
        let beta = try makeProjectDir(name: "beta")
        try writeTaskFile(
            projectDir: alpha,
            filename: "001-a.md",
            text: "# A\n\n**Status:** pending",
            in: "pending"
        )
        try writeTaskFile(
            projectDir: beta,
            filename: "001-b.md",
            text: "# B\n\n**Status:** review",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [alpha.path, beta.path])
        let store = PlansStore(registryReader: reader)
        store.reload()

        XCTAssertEqual(store.projects.map(\.projectName), ["alpha", "beta"])
    }

    func testReloadOnEmptyRegistryYieldsNoProjects() throws {
        let reader = try makeReader(projectPaths: [])
        let store = PlansStore(registryReader: reader)
        store.reload()

        XCTAssertEqual(store.projects.count, 0)
    }

    func testReloadOnMissingRegistryDoesNotCrash() {
        let missingURL = tempDir.appendingPathComponent("does-not-exist.json")
        let reader = RegistryReader(registryURL: missingURL)
        let store = PlansStore(registryReader: reader)
        store.reload()

        XCTAssertEqual(store.projects.count, 0)
    }

    // MARK: - startPolling() / stopPolling()

    func testStartPollingPerformsInitialLoadSynchronously() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)
        // No timer firing involved: the load must happen synchronously.
        store.startPolling()
        defer { store.stopPolling() }

        XCTAssertEqual(store.projects.count, 1)
        let project = try XCTUnwrap(store.projects.first)
        XCTAssertEqual(project.projectName, "alpha")
        XCTAssertEqual(project.counts[.pending], 1)
    }

    func testReloadReflectsFilesystemChangeAfterInitialLoad() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)
        store.startPolling()
        defer { store.stopPolling() }

        let initial = try XCTUnwrap(store.projects.first)
        XCTAssertEqual(initial.counts[.pending], 1)

        // Simulate a live `.plans/` change, then re-read directly (rather than
        // waiting on the wall-clock timer fire).
        try writeTaskFile(
            projectDir: projectDir,
            filename: "002-second.md",
            text: "# Second\n\n**Status:** completed",
            in: "completed"
        )
        store.reload()

        let updated = try XCTUnwrap(store.projects.first)
        XCTAssertEqual(updated.counts[.pending], 1)
        XCTAssertEqual(updated.counts[.completed], 1)
    }

    func testStartPollingInstallsTimerAndStopPollingInvalidatesIt() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)

        XCTAssertFalse(store.isPolling)

        store.startPolling()
        XCTAssertTrue(store.isPolling)

        store.stopPolling()
        XCTAssertFalse(store.isPolling)
    }

    func testStopPollingIsSafeWhenNotPolling() throws {
        let reader = try makeReader(projectPaths: [])
        let store = PlansStore(registryReader: reader)

        // Should be a no-op rather than crashing.
        store.stopPolling()
        XCTAssertFalse(store.isPolling)
    }

    // MARK: - iconSpaceCounts

    func testIconSpaceCountsSumsAcrossMultipleProjects() throws {
        let alpha = try makeProjectDir(name: "alpha")
        let beta = try makeProjectDir(name: "beta")
        // alpha: 1 in-progress, 1 review
        try writeTaskFile(
            projectDir: alpha,
            filename: "001-a.md",
            text: "# A\n\n**Status:** in-progress",
            in: "pending"
        )
        try writeTaskFile(
            projectDir: alpha,
            filename: "002-a.md",
            text: "# A2\n\n**Status:** review",
            in: "pending"
        )
        // beta: 2 in-progress, 1 in-review
        try writeTaskFile(
            projectDir: beta,
            filename: "001-b.md",
            text: "# B\n\n**Status:** in-progress",
            in: "pending"
        )
        try writeTaskFile(
            projectDir: beta,
            filename: "002-b.md",
            text: "# B2\n\n**Status:** in-progress",
            in: "pending"
        )
        try writeTaskFile(
            projectDir: beta,
            filename: "003-b.md",
            text: "# B3\n\n**Status:** in-review",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [alpha.path, beta.path])
        let store = PlansStore(registryReader: reader)
        store.reload()

        let entries = store.iconSpaceCounts
        XCTAssertEqual(entries.map(\.status), [.inProgress, .review, .inReview])
        XCTAssertEqual(entries.map(\.count), [3, 1, 1])
    }

    func testIconSpaceCountsOmitsZeroCountStatuses() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        // Only review tasks; in-progress and in-review absent.
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-a.md",
            text: "# A\n\n**Status:** review",
            in: "pending"
        )
        // Plus statuses outside the icon-space set, which must not appear.
        try writeTaskFile(
            projectDir: projectDir,
            filename: "002-a.md",
            text: "# A2\n\n**Status:** pending",
            in: "pending"
        )
        try writeTaskFile(
            projectDir: projectDir,
            filename: "003-a.md",
            text: "# A3\n\n**Status:** completed",
            in: "completed"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)
        store.reload()

        let entries = store.iconSpaceCounts
        XCTAssertEqual(entries.map(\.status), [.review])
        XCTAssertEqual(entries.map(\.count), [1])
    }

    func testIconSpaceCountsOrdersInProgressReviewInReview() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-a.md",
            text: "# A\n\n**Status:** in-review",
            in: "pending"
        )
        try writeTaskFile(
            projectDir: projectDir,
            filename: "002-a.md",
            text: "# A2\n\n**Status:** review",
            in: "pending"
        )
        try writeTaskFile(
            projectDir: projectDir,
            filename: "003-a.md",
            text: "# A3\n\n**Status:** in-progress",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)
        store.reload()

        XCTAssertEqual(
            store.iconSpaceCounts.map(\.status),
            [.inProgress, .review, .inReview]
        )
    }

    func testIconSpaceCountsIsEmptyForEmptyStore() throws {
        let reader = try makeReader(projectPaths: [])
        let store = PlansStore(registryReader: reader)
        store.reload()

        XCTAssertTrue(store.iconSpaceCounts.isEmpty)
    }
}
