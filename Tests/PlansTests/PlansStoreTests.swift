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
        // TaskParser titleizes the directory's last path component (see
        // String+Titleize), so dir "alpha" surfaces as project name "Alpha".
        XCTAssertEqual(project.projectName, "Alpha")
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

        XCTAssertEqual(store.projects.map(\.projectName), ["Alpha", "Beta"])
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

    // MARK: - Run-outcome failure correlation (#079)

    /// Writes an NDJSON `run-outcomes.log` under the temp dir listing the given
    /// outcomes and returns a `RunOutcomeLogReader` pointed at it.
    private func makeOutcomeReader(_ outcomes: [RunOutcome]) throws -> RunOutcomeLogReader {
        let url = tempDir.appendingPathComponent("run-outcomes-\(UUID().uuidString).log")
        let encoder = JSONEncoder()
        let lines = try outcomes.map { String(data: try encoder.encode($0), encoding: .utf8)! }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return RunOutcomeLogReader(fileURL: url)
    }

    /// Forces the content-modification date of a task file to `date` so a test
    /// can control the recency relationship between a plan file's mtime and a
    /// run-outcome timestamp (the #080 liveness guard). Files written by
    /// `writeTaskFile` otherwise get an mtime of "now", which is always newer
    /// than the fixed past outcome timestamps used in these fixtures.
    private func setTaskFileMtime(
        projectDir: URL,
        filename: String,
        in subdir: String,
        to date: Date
    ) throws {
        let url = projectDir
            .appendingPathComponent(".plans")
            .appendingPathComponent(subdir)
            .appendingPathComponent(filename)
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    /// Parses an ISO-8601 outcome timestamp (as used in these fixtures) into a
    /// `Date` so tests can derive mtimes relative to an outcome's own timestamp.
    private func date(fromISO iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func makeOutcome(
        projectPath: String,
        taskID: String,
        classification: RunOutcome.Classification,
        timestamp: String,
        stopReason: String? = nil,
        errorMessage: String? = nil
    ) -> RunOutcome {
        RunOutcome(
            timestamp: timestamp,
            taskID: taskID,
            mode: "execute",
            projectPath: projectPath,
            costUsd: 0,
            turns: 0,
            stopReason: stopReason,
            errorMessage: errorMessage,
            classification: classification
        )
    }

    /// An in-progress task with a matching latest FAILED outcome on disk surfaces
    /// a `failure` overlay carrying the outcome's classification/message.
    func testReloadCorrelatesFailureForInProgressTask() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "007-run.md",
            text: "# Run\n\n**Status:** in-progress",
            in: "pending"
        )
        // The outcome is NEWER than the plan file's mtime — a genuine, just-
        // recorded failure that the #080 liveness guard must NOT suppress.
        try setTaskFileMtime(
            projectDir: projectDir,
            filename: "007-run.md",
            in: "pending",
            to: date(fromISO: "2026-06-04T09:00:00Z")
        )
        let reader = try makeReader(projectPaths: [projectDir.path])
        let outcomeReader = try makeOutcomeReader([
            makeOutcome(
                projectPath: projectDir.path,
                taskID: "007",
                classification: .truncated,
                timestamp: "2026-06-04T10:00:00Z",
                stopReason: "error_max_budget_usd",
                errorMessage: "Budget cap reached"
            )
        ])
        let store = PlansStore(registryReader: reader, outcomeLogReader: outcomeReader)
        store.reload()

        let task = try XCTUnwrap(store.projects.first?.tasks.first { $0.id == "007" })
        let failure = try XCTUnwrap(task.failure, "in-progress + failed outcome should overlay a failure")
        XCTAssertEqual(failure.classification, .truncated)
        XCTAssertEqual(failure.stopReason, "error_max_budget_usd")
        XCTAssertEqual(failure.errorMessage, "Budget cap reached")
        XCTAssertEqual(failure.timestamp, "2026-06-04T10:00:00Z")
    }

    /// No stale badge: a task that has ADVANCED past in-progress (now review)
    /// carries no failure overlay even though a failed outcome exists on disk.
    func testReloadDoesNotBadgeTaskThatAdvancedPastInProgress() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "007-run.md",
            text: "# Run\n\n**Status:** review",
            in: "pending"
        )
        let reader = try makeReader(projectPaths: [projectDir.path])
        let outcomeReader = try makeOutcomeReader([
            makeOutcome(
                projectPath: projectDir.path,
                taskID: "007",
                classification: .truncated,
                timestamp: "2026-06-04T10:00:00Z"
            )
        ])
        let store = PlansStore(registryReader: reader, outcomeLogReader: outcomeReader)
        store.reload()

        let task = try XCTUnwrap(store.projects.first?.tasks.first { $0.id == "007" })
        XCTAssertNil(task.failure, "a task past in-progress must not show a stale failure badge")
    }

    /// No stale badge: an in-progress task whose LATEST outcome is `completed`
    /// carries no failure overlay (only failing classifications overlay).
    func testReloadDoesNotBadgeInProgressTaskWithCompletedLatestOutcome() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "007-run.md",
            text: "# Run\n\n**Status:** in-progress",
            in: "pending"
        )
        let reader = try makeReader(projectPaths: [projectDir.path])
        let outcomeReader = try makeOutcomeReader([
            makeOutcome(
                projectPath: projectDir.path,
                taskID: "007",
                classification: .truncated,
                timestamp: "2026-06-04T10:00:00Z"
            ),
            // A later, cleanly-completed run supersedes the earlier failure.
            makeOutcome(
                projectPath: projectDir.path,
                taskID: "007",
                classification: .completed,
                timestamp: "2026-06-04T11:00:00Z"
            )
        ])
        let store = PlansStore(registryReader: reader, outcomeLogReader: outcomeReader)
        store.reload()

        let task = try XCTUnwrap(store.projects.first?.tasks.first { $0.id == "007" })
        XCTAssertNil(task.failure, "a superseding completed outcome must clear the failure")
    }

    // MARK: - Stale-outcome liveness guard (#080)

    /// The false-positive reproduction: an in-progress task whose latest outcome
    /// is a failing classification but whose plan-file mtime is NEWER than the
    /// outcome timestamp (a terminal run rewrote the file after the stale app
    /// run failed) must NOT show a failure overlay. This is the #080 bug: a stale
    /// failing outcome kept lighting the alarm on a task being healthily re-run.
    func testReloadSuppressesStaleFailureWhenFileNewerThanOutcome() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "007-run.md",
            text: "# Run\n\n**Status:** in-progress",
            in: "pending"
        )
        // The plan file was edited AFTER the failing outcome was recorded — the
        // signature of an active terminal run advancing past the stale failure.
        try setTaskFileMtime(
            projectDir: projectDir,
            filename: "007-run.md",
            in: "pending",
            to: date(fromISO: "2026-06-04T11:00:00Z")
        )
        let reader = try makeReader(projectPaths: [projectDir.path])
        let outcomeReader = try makeOutcomeReader([
            makeOutcome(
                projectPath: projectDir.path,
                taskID: "007",
                classification: .stranded,
                timestamp: "2026-06-04T10:00:00Z",
                stopReason: "stranded_at_in_progress",
                errorMessage: "Reached maximum budget ($20)"
            )
        ])
        let store = PlansStore(registryReader: reader, outcomeLogReader: outcomeReader)
        store.reload()

        let task = try XCTUnwrap(store.projects.first?.tasks.first { $0.id == "007" })
        XCTAssertNil(
            task.failure,
            "a failing outcome OLDER than the plan file's mtime is stale and must not overlay"
        )
    }

    /// Guard against over-suppression: a failing outcome NEWER than the plan
    /// file's mtime is a genuine, current failure and MUST still overlay.
    func testReloadShowsFailureWhenOutcomeNewerThanFile() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "007-run.md",
            text: "# Run\n\n**Status:** in-progress",
            in: "pending"
        )
        // The plan file predates the failing outcome — the run failed after the
        // last file edit, so the failure is current and should show.
        try setTaskFileMtime(
            projectDir: projectDir,
            filename: "007-run.md",
            in: "pending",
            to: date(fromISO: "2026-06-04T09:00:00Z")
        )
        let reader = try makeReader(projectPaths: [projectDir.path])
        let outcomeReader = try makeOutcomeReader([
            makeOutcome(
                projectPath: projectDir.path,
                taskID: "007",
                classification: .error,
                timestamp: "2026-06-04T10:00:00Z",
                errorMessage: "boom"
            )
        ])
        let store = PlansStore(registryReader: reader, outcomeLogReader: outcomeReader)
        store.reload()

        let task = try XCTUnwrap(store.projects.first?.tasks.first { $0.id == "007" })
        let failure = try XCTUnwrap(
            task.failure,
            "a failing outcome NEWER than the plan file's mtime is current and must overlay"
        )
        XCTAssertEqual(failure.classification, .error)
    }

    /// Edge case: an outcome timestamp EXACTLY EQUAL to the plan file's mtime is
    /// treated as FRESH (`<` comparison, not `<=`) — the overlay is shown. This
    /// biases toward surfacing a failure on a tie rather than hiding it.
    func testReloadShowsFailureWhenOutcomeEqualsFileMtime() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "007-run.md",
            text: "# Run\n\n**Status:** in-progress",
            in: "pending"
        )
        // Mtime exactly equals the outcome timestamp.
        try setTaskFileMtime(
            projectDir: projectDir,
            filename: "007-run.md",
            in: "pending",
            to: date(fromISO: "2026-06-04T10:00:00Z")
        )
        let reader = try makeReader(projectPaths: [projectDir.path])
        let outcomeReader = try makeOutcomeReader([
            makeOutcome(
                projectPath: projectDir.path,
                taskID: "007",
                classification: .crashed,
                timestamp: "2026-06-04T10:00:00Z"
            )
        ])
        let store = PlansStore(registryReader: reader, outcomeLogReader: outcomeReader)
        store.reload()

        let task = try XCTUnwrap(store.projects.first?.tasks.first { $0.id == "007" })
        XCTAssertNotNil(
            task.failure,
            "an outcome timestamp equal to the file mtime is fresh and must overlay"
        )
    }

    /// Edge case: an UNPARSEABLE outcome timestamp means the guard cannot judge
    /// recency, so it fails SAFE and shows the overlay rather than hiding a
    /// possible genuine failure.
    func testReloadShowsFailureWhenOutcomeTimestampUnparseable() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "007-run.md",
            text: "# Run\n\n**Status:** in-progress",
            in: "pending"
        )
        // File mtime is "now" (newer than any plausible outcome), which WOULD
        // suppress a parseable stale outcome — but the timestamp cannot be parsed.
        let reader = try makeReader(projectPaths: [projectDir.path])
        let outcomeReader = try makeOutcomeReader([
            makeOutcome(
                projectPath: projectDir.path,
                taskID: "007",
                classification: .stranded,
                timestamp: "not-a-timestamp"
            )
        ])
        let store = PlansStore(registryReader: reader, outcomeLogReader: outcomeReader)
        store.reload()

        let task = try XCTUnwrap(store.projects.first?.tasks.first { $0.id == "007" })
        XCTAssertNotNil(
            task.failure,
            "an unparseable outcome timestamp must fall back to showing the overlay"
        )
    }

    /// Edge case: when the plan file's mtime is UNAVAILABLE (`nil`), the guard
    /// cannot compare recency and falls back to the pre-#080 behavior — the
    /// overlay is shown. Constructed directly (rather than via a filesystem
    /// fixture) because a real file always has an mtime; this exercises the
    /// `task.modified == nil` fallback branch of the overlay in isolation.
    func testFailureOverlayShownWhenFileMtimeIsNil() throws {
        let task = Task(
            id: "007",
            title: "Run",
            type: nil,
            status: .inProgress,
            created: nil,
            branch: nil,
            isKeptWorktree: false,
            blockedBy: [],
            sections: [],
            howProgress: (done: 0, total: 0),
            isBlocked: false,
            isCompletedDir: false,
            isBacklogged: false,
            failure: nil,
            modified: nil
        )
        let project = ProjectTasks(
            projectPath: "/p",
            projectName: "P",
            lastSeen: "",
            tasks: [task],
            counts: [.inProgress: 1],
            activeTasks: [task],
            backloggedTasks: []
        )
        let outcomes: [RunOutcomeKey: RunOutcome] = [
            RunOutcomeKey(projectPath: "/p", taskID: "007"): makeOutcome(
                projectPath: "/p",
                taskID: "007",
                classification: .truncated,
                timestamp: "2026-06-04T10:00:00Z"
            )
        ]

        let overlaid = PlansStore.applyFailureOverlayForTesting(
            to: project,
            latestOutcomes: outcomes
        )

        let result = try XCTUnwrap(overlaid.tasks.first)
        XCTAssertNotNil(
            result.failure,
            "a nil file mtime must fall back to showing the overlay (pre-#080 behavior)"
        )
    }

    /// `failedCount` (#079) totals the tasks carrying a failure overlay across
    /// every project. Two in-progress tasks with failing latest outcomes (one per
    /// project) sum to 2; a healthy in-progress task adds nothing.
    func testFailedCountTotalsFailureOverlaysAcrossProjects() throws {
        let alpha = try makeProjectDir(name: "alpha")
        let beta = try makeProjectDir(name: "beta")
        try writeTaskFile(projectDir: alpha, filename: "001-a.md",
                          text: "# A\n\n**Status:** in-progress", in: "pending")
        try writeTaskFile(projectDir: beta, filename: "002-b.md",
                          text: "# B\n\n**Status:** in-progress", in: "pending")
        // A healthy in-progress task (no failing outcome) must not be counted.
        try writeTaskFile(projectDir: alpha, filename: "003-c.md",
                          text: "# C\n\n**Status:** in-progress", in: "pending")
        // Both failing files predate their outcomes — genuine failures the #080
        // liveness guard must count, not suppress.
        try setTaskFileMtime(projectDir: alpha, filename: "001-a.md", in: "pending",
                             to: date(fromISO: "2026-06-04T09:00:00Z"))
        try setTaskFileMtime(projectDir: beta, filename: "002-b.md", in: "pending",
                             to: date(fromISO: "2026-06-04T09:00:00Z"))

        let reader = try makeReader(projectPaths: [alpha.path, beta.path])
        let outcomeReader = try makeOutcomeReader([
            makeOutcome(projectPath: alpha.path, taskID: "001",
                        classification: .error, timestamp: "2026-06-04T10:00:00Z",
                        errorMessage: "boom"),
            makeOutcome(projectPath: beta.path, taskID: "002",
                        classification: .crashed, timestamp: "2026-06-04T10:00:00Z")
        ])
        let store = PlansStore(registryReader: reader, outcomeLogReader: outcomeReader)
        store.reload()

        XCTAssertEqual(store.failedCount, 2)
    }

    /// With no failing outcomes on disk, `failedCount` is 0 so the menu-bar
    /// surfaces suppress the failed badge entirely.
    func testFailedCountZeroWhenNoFailures() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(projectDir: projectDir, filename: "001-a.md",
                          text: "# A\n\n**Status:** in-progress", in: "pending")
        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader,
                               outcomeLogReader: try makeOutcomeReader([]))
        store.reload()

        XCTAssertEqual(store.failedCount, 0)
    }

    // MARK: - onDidReload hand-off hook (#051)

    /// `reload()` must invoke `onDidReload` AFTER `projects` is repopulated, so
    /// the app can reconcile finished capture spinners against the fresh parse.
    /// Asserting `projects` is already populated inside the callback locks in the
    /// ordering the hand-off depends on.
    func testReloadInvokesOnDidReloadAfterProjectsPopulated() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)
        var observedCount: Int?
        store.onDidReload = { observedCount = store.projects.count }
        store.reload()

        XCTAssertEqual(observedCount, 1,
                       "onDidReload should fire after projects is populated")
    }

    /// The regression guard for the orphaned-spinner bug: reconciliation must run
    /// on EVERY reload — including a plain poll-tick `reload()` — not only the
    /// run-finish path. A capture plan that lands after the run-finish reconcile
    /// pass is otherwise parsed-but-never-reconciled, pinning the spinner row.
    func testEveryReloadFiresOnDidReloadForPollDrivenReconcile() throws {
        let reader = try makeReader(projectPaths: [])
        let store = PlansStore(registryReader: reader)
        var fireCount = 0
        store.onDidReload = { fireCount += 1 }

        store.reload()
        store.reload()
        store.reload()

        XCTAssertEqual(fireCount, 3,
                       "each reload (poll tick included) must reconcile")
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
        XCTAssertEqual(project.projectName, "Alpha")
        XCTAssertEqual(project.counts[.pending], 1)
    }

    // MARK: - Off-main poll offload (#059)

    /// The launch contract: a direct `reload()` populates `projects`
    /// synchronously (before returning), NOT via a deferred background hop. The
    /// #059 change only moves the timer-driven poll off-main; `reload()` itself
    /// stays synchronous so `startPolling()` and `linkProject` see populated
    /// projects immediately. (`testStartPollingPerformsInitialLoadSynchronously`
    /// covers the `startPolling()` entry; this guards the bare `reload()` path.)
    func testReloadPopulatesProjectsSynchronouslyBeforeReturning() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)

        // Empty before, populated the instant `reload()` returns — no run-loop
        // spin, no expectation await needed.
        XCTAssertTrue(store.projects.isEmpty)
        store.reload()
        XCTAssertEqual(store.projects.map(\.projectName), ["Alpha"])
    }

    /// `performReload(priorGitInfo:)` is thread-agnostic and behavior-preserving:
    /// invoking it directly on the calling thread and dispatched off a background
    /// queue yields the same `[ProjectTasks]` (paths, counts, ordering) and
    /// carries over non-`nil` prior git branch/dirty. Proves the offload the poll
    /// relies on does not alter results.
    func testPerformReloadIsThreadAgnosticAndCarriesGitInfo() throws {
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
            text: "# B\n\n**Status:** completed",
            in: "completed"
        )

        let reader = try makeReader(projectPaths: [alpha.path, beta.path])
        let store = PlansStore(registryReader: reader)

        // Non-nil prior git info for one project to prove the carry-over survives
        // through the background offload.
        let priorGitInfo: [String: (String?, Bool?)] = [
            alpha.path: ("feature/x", true)
        ]

        // Main-thread reference result.
        let mainResult = store.performReloadForTesting(priorGitInfo: priorGitInfo)

        // Same call dispatched onto a background queue; await via expectation.
        let expectation = expectation(description: "background performReload")
        var backgroundResult: [ProjectTasks] = []
        DispatchQueue.global(qos: .userInitiated).async {
            backgroundResult = store.performReloadForTesting(priorGitInfo: priorGitInfo)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        // Same paths, in the same (registry) order.
        XCTAssertEqual(
            mainResult.map(\.projectPath),
            backgroundResult.map(\.projectPath)
        )
        XCTAssertEqual(mainResult.map(\.projectPath), [alpha.path, beta.path])

        // Same counts per project.
        XCTAssertEqual(
            mainResult.map { $0.counts },
            backgroundResult.map { $0.counts }
        )

        // Git carry-over survives on the background path exactly as on main.
        let bgAlpha = try XCTUnwrap(
            backgroundResult.first { $0.projectPath == alpha.path }
        )
        XCTAssertEqual(bgAlpha.gitBranch, "feature/x")
        XCTAssertEqual(bgAlpha.gitIsDirty, true)

        // A project with no prior git info stays nil on both paths.
        let bgBeta = try XCTUnwrap(
            backgroundResult.first { $0.projectPath == beta.path }
        )
        XCTAssertNil(bgBeta.gitBranch)
        XCTAssertNil(bgBeta.gitIsDirty)
    }

    /// The out-of-order guard (#059): once a newer reload has bumped the
    /// generation, applying an OLDER-generation async result is dropped — it does
    /// not overwrite `projects`. Drives the real guarded tail
    /// (`applyReloadResult`) deterministically via the test-only applier so no
    /// real background race is needed.
    func testStaleAsyncReloadResultIsDroppedByGenerationGuard() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)

        // Establish a baseline "newer" state and capture the generation an
        // in-flight poll would have snapshotted BEFORE it.
        store.reload()
        let staleGeneration = store.reloadGenerationForTesting

        // A newer reload starts, bumping the generation past the captured value.
        store.reload()
        XCTAssertGreaterThan(store.reloadGenerationForTesting, staleGeneration)
        let freshProjects = store.projects

        // The stale poll finally hops back to main with an unrelated result
        // tagged with its now-superseded generation — it must be dropped.
        let staleProjects = [
            ProjectTasks(
                projectPath: "/stale/ghost",
                projectName: "Ghost",
                lastSeen: "",
                tasks: [],
                counts: [:],
                activeTasks: []
            )
        ]
        store.applyReloadResultForTesting(staleProjects, generation: staleGeneration)

        // `projects` still reflects the newer reload, not the stale array.
        XCTAssertEqual(
            store.projects.map(\.projectPath),
            freshProjects.map(\.projectPath)
        )
        XCTAssertFalse(store.projects.contains { $0.projectPath == "/stale/ghost" })
    }

    /// Complement to the drop case: a result whose captured generation still
    /// matches the current generation IS applied by the guarded tail.
    func testCurrentGenerationReloadResultIsApplied() throws {
        let reader = try makeReader(projectPaths: [])
        let store = PlansStore(registryReader: reader)

        let currentGeneration = store.reloadGenerationForTesting
        let projects = [
            ProjectTasks(
                projectPath: "/applied/one",
                projectName: "One",
                lastSeen: "",
                tasks: [],
                counts: [:],
                activeTasks: []
            )
        ]
        store.applyReloadResultForTesting(projects, generation: currentGeneration)

        XCTAssertEqual(store.projects.map(\.projectPath), ["/applied/one"])
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

    // MARK: - linkProject(at:)

    func testLinkProjectWritesRegistryAndReloadsSoProjectAppears() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )

        // Start with an empty registry; the writer and reader share its URL.
        let registryURL = tempDir.appendingPathComponent("projects.json")
        let reader = RegistryReader(registryURL: registryURL)
        let writer = RegistryWriter(registryURL: registryURL)
        let store = PlansStore(registryReader: reader, registryWriter: writer)
        store.reload()
        XCTAssertEqual(store.projects.count, 0)

        try store.linkProject(at: projectDir.path)

        // The new project appears in the store immediately (reload happened).
        XCTAssertEqual(store.projects.map(\.projectName), ["Alpha"])

        // And it was persisted to the registry on disk.
        let persisted = reader.loadRegistry()
        XCTAssertEqual(persisted.map(\.path), [projectDir.path])
    }

    func testLinkProjectRejectsPathWithoutPlansDirAndWritesNothing() throws {
        // A directory that exists but has no `.plans/` subdirectory.
        let projectDir = tempDir.appendingPathComponent("noplans")
        try FileManager.default.createDirectory(
            at: projectDir,
            withIntermediateDirectories: true
        )

        let registryURL = tempDir.appendingPathComponent("projects.json")
        let reader = RegistryReader(registryURL: registryURL)
        let writer = RegistryWriter(registryURL: registryURL)
        let store = PlansStore(registryReader: reader, registryWriter: writer)

        XCTAssertThrowsError(try store.linkProject(at: projectDir.path)) { error in
            XCTAssertEqual(error as? PlansStore.LinkError, .missingPlansDirectory)
        }

        // Nothing was written: no registry file exists.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: registryURL.path)
        )
        XCTAssertTrue(store.projects.isEmpty)
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

    // MARK: - Manual order override (persisted to injected UserDefaults)

    /// Builds an isolated, empty `UserDefaults` suite so persistence assertions
    /// never touch the real `.standard` defaults.
    private func makeDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testManualOrderDefaultsToInactiveAndEmpty() throws {
        let reader = try makeReader(projectPaths: [])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())

        XCTAssertFalse(store.manualOrderActive)
        XCTAssertTrue(store.projectOrderOverride.isEmpty)
    }

    func testSettingManualOrderPersistsAcrossStoreInstances() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        let store = PlansStore(registryReader: reader, defaults: defaults)
        store.setManualOrder(["/c", "/a", "/b"])

        XCTAssertTrue(store.manualOrderActive)
        XCTAssertEqual(store.projectOrderOverride, ["/c", "/a", "/b"])

        // A fresh store over the SAME defaults reads the saved order back.
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertTrue(reloaded.manualOrderActive)
        XCTAssertEqual(reloaded.projectOrderOverride, ["/c", "/a", "/b"])
    }

    func testAssigningProjectOrderOverrideDirectlyPersists() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        let store = PlansStore(registryReader: reader, defaults: defaults)
        store.projectOrderOverride = ["/x", "/y"]

        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertEqual(reloaded.projectOrderOverride, ["/x", "/y"])
    }

    func testAssigningManualOrderActiveDirectlyPersists() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        let store = PlansStore(registryReader: reader, defaults: defaults)
        store.manualOrderActive = true

        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertTrue(reloaded.manualOrderActive)
    }

    // MARK: - Capture drafts (persisted to injected UserDefaults, #031)

    func testCaptureDraftRoundTripsAcrossStoreInstances() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        let store = PlansStore(registryReader: reader, defaults: defaults)
        let draft = PlansStore.CaptureDraft(text: "hi", execute: true, elaborate: false)
        store.setDraft(draft, for: "/proj")

        // Visible immediately on the same store.
        XCTAssertEqual(store.draft(for: "/proj"), draft)

        // A fresh store over the SAME defaults restores the draft.
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        let restored = try XCTUnwrap(reloaded.draft(for: "/proj"))
        XCTAssertEqual(restored.text, "hi")
        XCTAssertTrue(restored.execute)
        XCTAssertFalse(restored.elaborate)

        // Clearing drops it on this store AND on a fresh store over the same defaults.
        store.clearDraft(for: "/proj")
        XCTAssertNil(store.draft(for: "/proj"))

        let afterClear = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertNil(afterClear.draft(for: "/proj"))
    }

    // MARK: - Capture draft image data (#048 / #069 multi-image)

    func testCaptureDraftImageDatasRoundTripAcrossStoreInstances() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        // Two small byte sequences stand in for two staged images.
        let first = Data([0x89, 0x50, 0x4E, 0x47])
        let second = Data([0x01, 0x02, 0x03])

        let store = PlansStore(registryReader: reader, defaults: defaults)
        let draft = PlansStore.CaptureDraft(
            text: "hi",
            execute: false,
            elaborate: false,
            imageDatas: [first, second]
        )
        store.setDraft(draft, for: "/proj")

        // Visible immediately on the same store, order preserved.
        XCTAssertEqual(store.draft(for: "/proj")?.imageDatas, [first, second])

        // A fresh store over the SAME defaults restores the image bytes.
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        let restored = try XCTUnwrap(reloaded.draft(for: "/proj"))
        XCTAssertEqual(restored.imageDatas, [first, second])
    }

    func testCaptureDraftEmptyImageDatasRoundTripsAsEmpty() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        let store = PlansStore(registryReader: reader, defaults: defaults)
        let draft = PlansStore.CaptureDraft(
            text: "hi",
            execute: false,
            elaborate: false,
            imageDatas: []
        )
        store.setDraft(draft, for: "/proj")

        XCTAssertEqual(store.draft(for: "/proj")?.imageDatas, [])

        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        let restored = try XCTUnwrap(reloaded.draft(for: "/proj"))
        XCTAssertEqual(restored.imageDatas, [])
    }

    // MARK: - CaptureImageStore (image staging under Application Support, #048)

    func testCaptureImageStoreSavesImageUnderInjectedAppSupportNeverPlans() throws {
        // Inject a base directory under the per-test temp dir so the store writes
        // there instead of the real Application Support container.
        let appSupport = tempDir.appendingPathComponent("AppSupport")
        let imageStore = CaptureImageStore(applicationSupportDirectory: appSupport)

        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let url = try imageStore.saveImage(pngBytes)

        // The returned URL exists on disk and its contents match the bytes written.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), pngBytes)

        // The path lives under the injected Application Support temp dir, and
        // never inside any `.plans/` directory (§2 hard constraint).
        XCTAssertTrue(url.path.hasPrefix(appSupport.path))
        XCTAssertFalse(url.path.contains("/.plans/"))
        XCTAssertFalse(url.pathComponents.contains(".plans"))
    }

    func testFlattenDescriptionAppendsMarkdownReferenceForImageURL() {
        let imageURL = URL(fileURLWithPath: "/tmp/Plans/attachments/abc.png")
        let result = CaptureImageStore.flattenDescription(
            "Fix the login bug",
            imageURL: imageURL
        )

        XCTAssertTrue(result.contains("Fix the login bug"))
        XCTAssertTrue(result.contains("!["))
        XCTAssertTrue(result.contains("file://\(imageURL.path)"))
    }

    func testFlattenDescriptionReturnsInputUnchangedForNilURL() {
        let input = "Fix the login bug"
        let result = CaptureImageStore.flattenDescription(input, imageURL: nil)

        XCTAssertEqual(result, input)
    }

    func testFlattenDescriptionAppendsOneReferencePerURLInOrder() {
        let first = URL(fileURLWithPath: "/tmp/Plans/attachments/one.png")
        let second = URL(fileURLWithPath: "/tmp/Plans/attachments/two.png")

        let result = CaptureImageStore.flattenDescription(
            "Fix the login bug",
            imageURLs: [first, second]
        )

        XCTAssertEqual(
            result,
            "Fix the login bug"
                + "\n\n![pasted image](file://\(first.path))"
                + "\n\n![pasted image](file://\(second.path))"
        )
    }

    func testFlattenDescriptionReturnsInputUnchangedForEmptyURLList() {
        let input = "Fix the login bug"
        let result = CaptureImageStore.flattenDescription(input, imageURLs: [])

        XCTAssertEqual(result, input)
    }

    func testSaveAndFlattenReturnsDescriptionUnchangedForEmptyImageDatas() {
        let appSupport = tempDir.appendingPathComponent("AppSupport")
        let imageStore = CaptureImageStore(applicationSupportDirectory: appSupport)

        let input = "Fix the login bug"
        let result = imageStore.saveAndFlatten(description: input, imageDatas: [])

        XCTAssertEqual(result, input)
    }

    func testSaveAndFlattenSavesEachImageAndAppendsReferencesInOrder() throws {
        let appSupport = tempDir.appendingPathComponent("AppSupport")
        let imageStore = CaptureImageStore(applicationSupportDirectory: appSupport)

        let first = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let second = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0B])

        let result = imageStore.saveAndFlatten(
            description: "Fix the login bug",
            imageDatas: [first, second]
        )

        // One markdown image reference appended per saved image.
        XCTAssertTrue(result.hasPrefix("Fix the login bug"))
        let refCount = result.components(separatedBy: "![pasted image](file://").count - 1
        XCTAssertEqual(refCount, 2)

        // Extract the saved file paths from the flattened references, in order.
        let refs = result
            .components(separatedBy: "![pasted image](file://")
            .dropFirst()
            .map { $0.components(separatedBy: ")")[0] }
        XCTAssertEqual(refs.count, 2)

        // Each saved file exists under the injected AppSupport temp dir and is
        // NOT inside any `.plans/` directory (§2 hard constraint). The bytes
        // round-trip in staging order.
        let expectedBytes = [first, second]
        for (index, path) in refs.enumerated() {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertTrue(path.hasPrefix(appSupport.path))
            XCTAssertFalse(path.contains("/.plans/"))
            XCTAssertFalse(URL(fileURLWithPath: path).pathComponents.contains(".plans"))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), expectedBytes[index])
        }
    }

    func testClearManualOrderRevertsFlagButKeepsOverride() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        let store = PlansStore(registryReader: reader, defaults: defaults)
        store.setManualOrder(["/a", "/b"])
        store.clearManualOrder()

        XCTAssertFalse(store.manualOrderActive)

        // The flag-off state persists too.
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertFalse(reloaded.manualOrderActive)
    }

    // MARK: - Card layout mode (#033, persisted to injected UserDefaults)

    func testCardLayoutModeDefaultsToScroll() throws {
        let reader = try makeReader(projectPaths: [])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())

        XCTAssertEqual(store.cardLayoutMode, .scroll)
    }

    func testSettingCardLayoutModePersistsAcrossStoreInstances() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        let store = PlansStore(registryReader: reader, defaults: defaults)
        store.cardLayoutMode = .fit

        // A fresh store over the SAME defaults reads the saved mode back.
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertEqual(reloaded.cardLayoutMode, .fit)
    }

    // MARK: - Project view mode (#072, persisted to injected UserDefaults)

    func testProjectViewModeDefaultsToAll() throws {
        let reader = try makeReader(projectPaths: [])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())

        XCTAssertEqual(store.projectViewMode, .all)
    }

    func testSettingProjectViewModePersistsAcrossStoreInstances() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        let store = PlansStore(registryReader: reader, defaults: defaults)
        store.projectViewMode = .starred

        // A fresh store over the SAME defaults reads the saved mode back.
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertEqual(reloaded.projectViewMode, .starred)
    }

    // MARK: - Show backlog (#077, persisted to injected UserDefaults)

    func testShowBacklogDefaultsToFalse() throws {
        let reader = try makeReader(projectPaths: [])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())

        XCTAssertFalse(store.showBacklog)
    }

    func testSettingShowBacklogPersistsAcrossStoreInstances() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        let store = PlansStore(registryReader: reader, defaults: defaults)
        store.showBacklog = true

        // A fresh store over the SAME defaults reads the saved flag back.
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertTrue(reloaded.showBacklog)
    }

    // MARK: - Starred project paths (#035, persisted to injected UserDefaults)

    func testStarredProjectPathsDefaultToEmpty() throws {
        let reader = try makeReader(projectPaths: [])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())

        XCTAssertTrue(store.starredProjectPaths.isEmpty)
    }

    func testStarredProjectPathsPersistAcrossStoreInstances() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        let store = PlansStore(registryReader: reader, defaults: defaults)
        store.starredProjectPaths.insert("/proj1")
        store.starredProjectPaths.insert("/proj2")

        XCTAssertEqual(store.starredProjectPaths, ["/proj1", "/proj2"])

        // A fresh store over the SAME defaults restores the starred set.
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertEqual(reloaded.starredProjectPaths, ["/proj1", "/proj2"])
    }

    func testRemovingStarredProjectPathPersistsAcrossStoreInstances() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        let store = PlansStore(registryReader: reader, defaults: defaults)
        store.starredProjectPaths = ["/proj1", "/proj2"]
        store.starredProjectPaths.remove("/proj1")

        XCTAssertEqual(store.starredProjectPaths, ["/proj2"])

        // A fresh store over the SAME defaults reflects the removal.
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertEqual(reloaded.starredProjectPaths, ["/proj2"])
    }

    // MARK: - Focused project (#067, persisted to injected UserDefaults)

    func testFocusedProjectPathDefaultsToNil() throws {
        let reader = try makeReader(projectPaths: [])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())

        XCTAssertNil(store.focusedProjectPath)
    }

    func testFocusedProjectPathPersistsAcrossStoreInstances() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        let store = PlansStore(registryReader: reader, defaults: defaults)
        store.focusedProjectPath = "/proj1"

        XCTAssertEqual(store.focusedProjectPath, "/proj1")

        // A fresh store over the SAME defaults restores the focused path.
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertEqual(reloaded.focusedProjectPath, "/proj1")
    }

    func testClearFocusSetsPathToNilAndPersists() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        let store = PlansStore(registryReader: reader, defaults: defaults)
        store.focusedProjectPath = "/proj1"
        store.clearFocus()

        XCTAssertNil(store.focusedProjectPath)

        // The cleared (nil) state persists across a fresh store.
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertNil(reloaded.focusedProjectPath)
    }

    func testToggleFocusSetsWhenUnfocusedAndClearsWhenAlreadyFocused() throws {
        let reader = try makeReader(projectPaths: [])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())

        // Toggling an unfocused path focuses it.
        store.toggleFocus("/proj1")
        XCTAssertEqual(store.focusedProjectPath, "/proj1")

        // Toggling the SAME (already-focused) path clears the focus.
        store.toggleFocus("/proj1")
        XCTAssertNil(store.focusedProjectPath)

        // Toggling a DIFFERENT path while one is focused switches focus.
        store.toggleFocus("/proj1")
        store.toggleFocus("/proj2")
        XCTAssertEqual(store.focusedProjectPath, "/proj2")
    }

    // MARK: - New Plan trigger (non-persisted ⌘N → sheet bridge, #034)

    func testRequestNewPlanIncrementsTrigger() throws {
        let reader = try makeReader(projectPaths: [])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())

        XCTAssertEqual(store.newPlanTrigger, 0)
        store.requestNewPlan()
        XCTAssertEqual(store.newPlanTrigger, 1)
        store.requestNewPlan()
        XCTAssertEqual(store.newPlanTrigger, 2)
    }

    func testNewPlanTriggerIsNotPersisted() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        let store = PlansStore(registryReader: reader, defaults: defaults)
        store.requestNewPlan()
        XCTAssertEqual(store.newPlanTrigger, 1)

        // A fresh store over the SAME defaults starts back at 0 — the trigger is
        // transient UI state, deliberately never written to UserDefaults.
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertEqual(reloaded.newPlanTrigger, 0)
    }

    // MARK: - Change-gated parsing (#066 Step 3)

    /// A project whose `.plans/` is unchanged between two consecutive reloads
    /// must NOT be re-read/re-parsed on the second reload: the prior parse result
    /// is reused verbatim. This is the whole point of the change gate — on an
    /// idle tick with N unchanged projects, zero task files are read or parsed.
    func testUnchangedProjectIsNotReparsedOnSubsequentReload() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)

        store.reload()
        XCTAssertEqual(
            store.lastReloadParsedPathsForTesting, [projectDir.path],
            "the first reload has no cache, so the project must be parsed"
        )

        store.reload()
        XCTAssertEqual(
            store.lastReloadParsedPathsForTesting, [],
            "an unchanged project must be skipped on the second reload"
        )

        // The reused result must still be correct and present.
        let project = try XCTUnwrap(store.projects.first)
        XCTAssertEqual(project.projectPath, projectDir.path)
        XCTAssertEqual(project.counts[.pending], 1)
        XCTAssertEqual(project.activeTasks.first?.title, "First")
    }

    /// Adding a task file must re-parse that project and surface the new data.
    func testAddedTaskFileCausesReparseAndSurfaces() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)
        store.reload()
        store.reload()
        XCTAssertEqual(store.lastReloadParsedPathsForTesting, [])

        try writeTaskFile(
            projectDir: projectDir,
            filename: "002-second.md",
            text: "# Second\n\n**Status:** in-progress",
            in: "pending"
        )
        store.reload()

        XCTAssertEqual(store.lastReloadParsedPathsForTesting, [projectDir.path])
        let project = try XCTUnwrap(store.projects.first)
        XCTAssertEqual(project.counts[.pending], 1)
        XCTAssertEqual(project.counts[.inProgress], 1)
    }

    /// THE correctness case for #066 Step 3: an IN-PLACE edit to an existing task
    /// file's contents — same filename, so the containing directory's own mtime
    /// is not a dependable signal. The change gate must still re-parse and the
    /// edited status must surface. If this regressed, task edits would silently
    /// stop appearing in both surfaces.
    func testInPlaceEditOfExistingTaskFileCausesReparseAndSurfaces() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)
        store.reload()
        store.reload()
        XCTAssertEqual(store.lastReloadParsedPathsForTesting, [])
        XCTAssertEqual(store.projects.first?.counts[.pending], 1)

        // Rewrite the SAME file with different contents (no new/removed entry).
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** in-progress",
            in: "pending"
        )
        store.reload()

        XCTAssertEqual(
            store.lastReloadParsedPathsForTesting, [projectDir.path],
            "an in-place content edit must invalidate the change gate"
        )
        let project = try XCTUnwrap(store.projects.first)
        XCTAssertNil(project.counts[.pending])
        XCTAssertEqual(project.counts[.inProgress], 1)
        XCTAssertEqual(project.activeTasks.first?.status, .inProgress)
    }

    /// An in-place edit that keeps the file's byte count IDENTICAL must also be
    /// caught, so the signature cannot rely on size alone. The mtime is advanced
    /// explicitly (as a real editor write does) to defeat sub-second filesystem
    /// timestamp granularity.
    func testSameLengthInPlaceEditCausesReparse() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** review",
            in: "pending"
        )
        let fileURL = projectDir
            .appendingPathComponent(".plans")
            .appendingPathComponent("pending")
            .appendingPathComponent("001-first.md")

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)
        store.reload()
        store.reload()
        XCTAssertEqual(store.lastReloadParsedPathsForTesting, [])

        // "review" -> "elabor" would change length; use the same-length
        // "**Status:** review" -> "**Status:** pendin" trick? Instead keep the
        // total byte count equal by swapping to an equally-long valid status.
        try "# First\n\n**Status:** in-rev".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: fileURL.path
        )
        store.reload()

        XCTAssertEqual(
            store.lastReloadParsedPathsForTesting, [projectDir.path],
            "a same-length in-place edit must still invalidate the change gate"
        )
    }

    /// Deleting a task file must re-parse and the removal must surface.
    func testDeletedTaskFileCausesReparseAndSurfaces() throws {
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
            text: "# Second\n\n**Status:** pending",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)
        store.reload()
        store.reload()
        XCTAssertEqual(store.lastReloadParsedPathsForTesting, [])
        XCTAssertEqual(store.projects.first?.counts[.pending], 2)

        try FileManager.default.removeItem(
            at: projectDir.appendingPathComponent(".plans/pending/002-second.md")
        )
        store.reload()

        XCTAssertEqual(store.lastReloadParsedPathsForTesting, [projectDir.path])
        XCTAssertEqual(store.projects.first?.counts[.pending], 1)
    }

    /// The gate is PER PROJECT: when one of two projects changes, only that one
    /// is re-parsed; the untouched project keeps its cached result.
    func testOnlyTheChangedProjectIsReparsed() throws {
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
            text: "# B\n\n**Status:** pending",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [alpha.path, beta.path])
        let store = PlansStore(registryReader: reader)
        store.reload()
        store.reload()
        XCTAssertEqual(store.lastReloadParsedPathsForTesting, [])

        try writeTaskFile(
            projectDir: beta,
            filename: "002-b2.md",
            text: "# B2\n\n**Status:** review",
            in: "pending"
        )
        store.reload()

        XCTAssertEqual(store.lastReloadParsedPathsForTesting, [beta.path])
        XCTAssertEqual(store.projects.map(\.projectPath), [alpha.path, beta.path])
        XCTAssertEqual(store.projects.first?.counts[.pending], 1)
        XCTAssertEqual(store.projects.last?.counts[.review], 1)
    }

    /// #051 must survive the change gate: `onDidReload` fires on EVERY reload
    /// even when all parsing is skipped, so a capture spinner can never orphan.
    func testOnDidReloadFiresEvenWhenAllParsingIsSkipped() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)
        store.reload()

        var fireCount = 0
        store.onDidReload = { fireCount += 1 }
        store.reload()
        store.reload()
        store.reload()

        XCTAssertEqual(store.lastReloadParsedPathsForTesting, [])
        XCTAssertEqual(fireCount, 3, "onDidReload must fire on every tick, skipped or not")
    }

    /// A project removed from the registry must have its cache entry dropped, and
    /// a project re-added later must be parsed fresh rather than resurrected from
    /// a stale cached result.
    func testProjectRemovedFromRegistryDoesNotLeakCachedResult() throws {
        let alpha = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: alpha,
            filename: "001-a.md",
            text: "# A\n\n**Status:** pending",
            in: "pending"
        )

        let registryURL = tempDir.appendingPathComponent("projects.json")
        let reader = try makeReader(projectPaths: [alpha.path])
        let store = PlansStore(registryReader: reader)
        store.reload()
        XCTAssertEqual(store.projects.count, 1)

        // Empty the registry.
        try #"{ "version": 1, "projects": [] }"#
            .write(to: registryURL, atomically: true, encoding: .utf8)
        store.reload()
        XCTAssertEqual(store.projects.count, 0)

        // Re-add it; the project must reappear with correct data.
        _ = try makeReader(projectPaths: [alpha.path])
        store.reload()
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(store.projects.first?.counts[.pending], 1)
    }

    // MARK: - Equality-gated publishes (#066 Step 4)

    /// An idle tick where every project came from the change-gate cache must not
    /// PUBLISH at all: `projects` is left untouched, so `@Observable` records no
    /// mutation and SwiftUI observers (project cards, `MenuBarView`, and
    /// `MenuBarLabel`'s `ImageRenderer` bitmap re-bake) never invalidate.
    ///
    /// Note that a bare `projects = newValue` IS observable even when the value
    /// compares equal, so this can only pass with a genuine `if new != projects`
    /// guard around the assignment.
    func testUnchangedReloadDoesNotPublishProjects() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)

        store.reload()
        XCTAssertTrue(
            store.lastReloadDidPublishProjectsForTesting,
            "the first reload goes from [] to one project, so it must publish"
        )
        let publishesAfterFirst = store.projectsPublishCountForTesting

        store.reload()
        store.reload()
        store.reload()

        XCTAssertEqual(store.lastReloadParsedPathsForTesting, [])
        XCTAssertFalse(
            store.lastReloadDidPublishProjectsForTesting,
            "an idle tick producing identical projects must not publish"
        )
        XCTAssertEqual(
            store.projectsPublishCountForTesting, publishesAfterFirst,
            "three idle ticks must not have bumped the publish counter at all"
        )

        // The suppressed publish must NOT mean stale/missing data.
        let project = try XCTUnwrap(store.projects.first)
        XCTAssertEqual(project.projectPath, projectDir.path)
        XCTAssertEqual(project.counts[.pending], 1)
    }

    /// The mirror of the above: a REAL change must still publish and surface.
    /// A gate that dropped genuine changes would be far worse than the energy
    /// cost this exists to fix, so this is the load-bearing safety test.
    func testChangedReloadDoesPublishProjects() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)
        store.reload()
        store.reload()
        XCTAssertFalse(store.lastReloadDidPublishProjectsForTesting)
        let publishesBefore = store.projectsPublishCountForTesting

        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** in-progress",
            in: "pending"
        )
        store.reload()

        XCTAssertTrue(
            store.lastReloadDidPublishProjectsForTesting,
            "a real content change must publish"
        )
        XCTAssertEqual(store.projectsPublishCountForTesting, publishesBefore + 1)
        XCTAssertEqual(store.projects.first?.counts[.inProgress], 1)
        XCTAssertNil(store.projects.first?.counts[.pending])
    }

    /// The equality gate must compare EVERY field of the value graph. A change
    /// that alters only a deeply-nested field (a `## How` checkbox tick inside a
    /// task's section body, which moves `howProgress` and the section text but
    /// leaves the status counts and task ids identical) must still publish. This
    /// is the test that would fail if `==` were hand-written sloppily and skipped
    /// a field.
    func testNestedOnlyChangePublishesAndSurfaces() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending\n\n## How\n\n- [ ] one\n- [ ] two",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)
        store.reload()
        store.reload()
        XCTAssertFalse(store.lastReloadDidPublishProjectsForTesting)
        XCTAssertEqual(store.projects.first?.activeTasks.first?.howProgress.done, 0)

        // Tick one checkbox. Same status, same id, same counts, same task count —
        // ONLY the section body and `howProgress` move.
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending\n\n## How\n\n- [x] one\n- [ ] two",
            in: "pending"
        )
        store.reload()

        XCTAssertTrue(
            store.lastReloadDidPublishProjectsForTesting,
            "a change confined to a nested section body must still publish"
        )
        XCTAssertEqual(store.projects.first?.activeTasks.first?.howProgress.done, 1)
        XCTAssertEqual(store.projects.first?.counts[.pending], 1)
    }

    /// The git second pass merges into `projects` on EVERY tick. When the live
    /// git values equal what is already published, `applyGitInfo` must not
    /// republish either — otherwise the equality gate on the parse path would be
    /// defeated 5 seconds later by the git merge.
    func testApplyGitInfoDoesNotPublishWhenGitValuesAreUnchanged() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)
        store.reload()

        // First merge: nil -> ("main", false) is a real change and must publish.
        store.applyGitInfoForTesting([(path: projectDir.path, branch: "main", dirty: false)])
        XCTAssertEqual(store.projects.first?.gitBranch, "main")
        let publishesAfterFirstGit = store.projectsPublishCountForTesting

        // Second merge with identical values must be a no-op publish-wise.
        store.applyGitInfoForTesting([(path: projectDir.path, branch: "main", dirty: false)])
        store.applyGitInfoForTesting([(path: projectDir.path, branch: "main", dirty: false)])
        XCTAssertEqual(
            store.projectsPublishCountForTesting, publishesAfterFirstGit,
            "identical git results must not republish `projects`"
        )
        XCTAssertEqual(store.projects.first?.gitBranch, "main")
        XCTAssertEqual(store.projects.first?.gitIsDirty, false)

        // A changed git value must publish and surface.
        store.applyGitInfoForTesting([(path: projectDir.path, branch: "feature/x", dirty: true)])
        XCTAssertEqual(store.projectsPublishCountForTesting, publishesAfterFirstGit + 1)
        XCTAssertEqual(store.projects.first?.gitBranch, "feature/x")
        XCTAssertEqual(store.projects.first?.gitIsDirty, true)
    }

    /// The suppressed publish must not clobber the drill-down selection, nor be
    /// disturbed by it: selection is independent observable state and an idle
    /// tick must leave it exactly as the user set it.
    func testSuppressedPublishPreservesSelectionState() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )

        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader)
        store.reload()
        store.selectedProjectPath = projectDir.path

        store.reload()
        store.reload()

        XCTAssertFalse(store.lastReloadDidPublishProjectsForTesting)
        XCTAssertEqual(store.selectedProjectPath, projectDir.path)
    }

    /// A registry-level change (a project dropping out) must publish even though
    /// no individual surviving project changed.
    func testProjectRemovalPublishesEvenThoughSurvivorsAreUnchanged() throws {
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
            text: "# B\n\n**Status:** pending",
            in: "pending"
        )

        let registryURL = tempDir.appendingPathComponent("projects.json")
        let reader = try makeReader(projectPaths: [alpha.path, beta.path])
        let store = PlansStore(registryReader: reader)
        store.reload()
        store.reload()
        XCTAssertFalse(store.lastReloadDidPublishProjectsForTesting)

        try #"{ "version": 1, "projects": [{ "path": "\#(alpha.path)", "lastSeen": "2026-06-04T14:41:00Z" }] }"#
            .write(to: registryURL, atomically: true, encoding: .utf8)
        store.reload()

        XCTAssertTrue(
            store.lastReloadDidPublishProjectsForTesting,
            "a project dropping out of the registry must publish"
        )
        XCTAssertEqual(store.projects.map(\.projectPath), [alpha.path])
    }

    // MARK: - Throttled git second pass (#066 Step 2)

    /// A mutable, test-controlled clock. Advancing it is how a test crosses the
    /// git throttle boundary without any real `sleep`.
    private final class TestClock {
        var now: Date
        init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { self.now = start }
        func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
        /// The time source closure handed to `PlansStore(now:)`.
        var source: () -> Date { { [self] in now } }
    }

    /// Consecutive idle ticks inside the throttle window must NOT re-query git
    /// for a project already queried. The first reload queries it (no prior
    /// timestamp); subsequent reloads a few seconds later must schedule ZERO
    /// git work — that is the ~415k-subprocesses/day saving.
    func testGitPassSkipsProjectsQueriedWithinThrottleWindow() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )
        let reader = try makeReader(projectPaths: [projectDir.path])
        let clock = TestClock()
        let store = PlansStore(registryReader: reader, defaults: makeDefaults(), now: clock.source)

        store.reload()
        XCTAssertEqual(
            store.lastGitPassQueriedPathsForTesting, [projectDir.path],
            "the first pass has no prior timestamp, so git must be queried"
        )

        // Three more poll ticks, 5s apart — all well inside the 30s window and
        // all with an unchanged `.plans/`.
        for _ in 0..<3 {
            clock.advance(5)
            store.reload()
            XCTAssertEqual(
                store.lastGitPassQueriedPathsForTesting, [],
                "an unchanged project inside the throttle window must not re-query git"
            )
        }
    }

    /// Once the throttle interval has elapsed, git MUST be re-queried even
    /// though nothing in `.plans/` changed — otherwise a branch switch made
    /// outside the app would never surface.
    func testGitPassRequeriesAfterThrottleIntervalElapses() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        let reader = try makeReader(projectPaths: [projectDir.path])
        let clock = TestClock()
        let store = PlansStore(registryReader: reader, defaults: makeDefaults(), now: clock.source)

        store.reload()
        XCTAssertEqual(store.lastGitPassQueriedPathsForTesting, [projectDir.path])

        clock.advance(29)
        store.reload()
        XCTAssertEqual(
            store.lastGitPassQueriedPathsForTesting, [],
            "still inside the window at 29s"
        )

        clock.advance(2) // 31s since the last query
        store.reload()
        XCTAssertEqual(
            store.lastGitPassQueriedPathsForTesting, [projectDir.path],
            "the throttle interval elapsed, so git must be re-queried"
        )

        // And the timestamp resets: the very next tick is throttled again.
        clock.advance(5)
        store.reload()
        XCTAssertEqual(store.lastGitPassQueriedPathsForTesting, [])
    }

    /// A `.plans/` edit very often accompanies a branch/dirty change (a plan is
    /// moved to in-progress as a worktree is created). A project whose parse
    /// result changed must therefore refresh git PROMPTLY, without waiting out
    /// the throttle — and only that project, not its unchanged neighbours.
    func testChangedProjectRequeriesGitImmediatelyWithinThrottleWindow() throws {
        let alpha = try makeProjectDir(name: "alpha")
        let beta = try makeProjectDir(name: "beta")
        try writeTaskFile(
            projectDir: alpha,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )
        let reader = try makeReader(projectPaths: [alpha.path, beta.path])
        let clock = TestClock()
        let store = PlansStore(registryReader: reader, defaults: makeDefaults(), now: clock.source)

        store.reload()
        XCTAssertEqual(
            Set(store.lastGitPassQueriedPathsForTesting), Set([alpha.path, beta.path])
        )

        clock.advance(5)
        store.reload()
        XCTAssertEqual(store.lastGitPassQueriedPathsForTesting, [])

        // Change ONLY alpha's `.plans/` contents.
        clock.advance(5)
        try writeTaskFile(
            projectDir: alpha,
            filename: "002-second.md",
            text: "# Second\n\n**Status:** in-progress",
            in: "pending"
        )
        store.reload()

        XCTAssertEqual(
            store.lastReloadParsedPathsForTesting, [alpha.path],
            "only alpha's parse result changed"
        )
        XCTAssertEqual(
            store.lastGitPassQueriedPathsForTesting, [alpha.path],
            "a changed project must refresh git immediately; beta stays throttled"
        )
    }

    /// A project that drops out of the registry must not leave a timestamp
    /// behind that would throttle it on re-registration — a re-added project is
    /// queried immediately so its branch is never unknown/stale on screen.
    func testDeregisteredProjectDoesNotResurrectStaleThrottleEntry() throws {
        let alpha = try makeProjectDir(name: "alpha")
        let beta = try makeProjectDir(name: "beta")
        let registryURL = tempDir.appendingPathComponent("projects.json")

        _ = try makeReader(projectPaths: [alpha.path, beta.path])
        let reader = RegistryReader(registryURL: registryURL)
        let clock = TestClock()
        let store = PlansStore(registryReader: reader, defaults: makeDefaults(), now: clock.source)

        store.reload()
        XCTAssertEqual(Set(store.lastGitPassQueriedPathsForTesting), Set([alpha.path, beta.path]))

        // beta de-registers.
        _ = try makeReader(projectPaths: [alpha.path])
        clock.advance(5)
        store.reload()
        XCTAssertEqual(store.lastGitPassQueriedPathsForTesting, [])

        // beta comes back, still inside the 30s window. It must be queried
        // immediately rather than reusing the dropped timestamp.
        _ = try makeReader(projectPaths: [alpha.path, beta.path])
        clock.advance(5)
        store.reload()
        XCTAssertEqual(
            store.lastGitPassQueriedPathsForTesting, [beta.path],
            "a re-registered project must be re-queried, not throttled by a stale entry"
        )
    }

    /// The throttle must not disturb #051: `onDidReload` still fires on EVERY
    /// tick, including ticks where the git pass scheduled no work at all.
    func testOnDidReloadStillFiresOnGitThrottledTicks() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        let reader = try makeReader(projectPaths: [projectDir.path])
        let clock = TestClock()
        let store = PlansStore(registryReader: reader, defaults: makeDefaults(), now: clock.source)

        var reloadCount = 0
        store.onDidReload = { reloadCount += 1 }

        store.reload()
        clock.advance(5)
        store.reload()
        clock.advance(5)
        store.reload()

        XCTAssertEqual(store.lastGitPassQueriedPathsForTesting, [])
        XCTAssertEqual(reloadCount, 3, "onDidReload must fire on every tick, throttled or not")
    }

    /// Throttling must never cause the git merge to publish stale values: a
    /// project skipped by the throttle keeps its last-known branch/dirty on
    /// screen (carried over by `performReload`) and publishes nothing.
    func testThrottledTicksPreserveLastKnownGitValuesWithoutRepublishing() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        let reader = try makeReader(projectPaths: [projectDir.path])
        let clock = TestClock()
        let store = PlansStore(registryReader: reader, defaults: makeDefaults(), now: clock.source)

        store.reload()
        store.applyGitInfoForTesting([(path: projectDir.path, branch: "feature/x", dirty: true)])
        XCTAssertEqual(store.projects.first?.gitBranch, "feature/x")
        let publishesBefore = store.projectsPublishCountForTesting

        clock.advance(5)
        store.reload()
        clock.advance(5)
        store.reload()

        XCTAssertEqual(store.lastGitPassQueriedPathsForTesting, [])
        XCTAssertEqual(
            store.projects.first?.gitBranch, "feature/x",
            "the last-known branch must survive throttled ticks"
        )
        XCTAssertEqual(store.projects.first?.gitIsDirty, true)
        XCTAssertEqual(
            store.projectsPublishCountForTesting, publishesBefore,
            "throttled idle ticks must not republish `projects`"
        )
    }

    // MARK: - plans-cc storage mode and sync status

    private static let branchSync = PlansSyncStatus(
        branch: "plans", remote: "origin", upstream: true,
        ahead: 1, behind: 2, rebaseStuck: false
    )

    func testProjectTasksPlansFieldsDefaultToNil() {
        let project = ProjectTasks(
            projectPath: "/p", projectName: "P", lastSeen: "",
            tasks: [], counts: [:], activeTasks: []
        )
        XCTAssertNil(project.plansMode)
        XCTAssertNil(project.plansSync)
    }

    func testApplyGitInfoMergesPlansModeAndSyncStatus() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())
        store.reload()

        store.applyGitInfoForTesting([
            PlansStore.GitResult(path: projectDir.path, branch: "main", dirty: false,
                                 mode: .branch, sync: Self.branchSync)
        ])

        XCTAssertEqual(store.projects.first?.gitBranch, "main")
        XCTAssertEqual(store.projects.first?.plansMode, .branch)
        XCTAssertEqual(store.projects.first?.plansSync, Self.branchSync)
    }

    func testApplyGitInfoPublishesWhenOnlySyncStatusChanges() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())
        store.reload()
        store.applyGitInfoForTesting([
            PlansStore.GitResult(path: projectDir.path, branch: "main", dirty: false,
                                 mode: .branch, sync: Self.branchSync)
        ])
        let publishesBefore = store.projectsPublishCountForTesting

        let behindMore = PlansSyncStatus(
            branch: "plans", remote: "origin", upstream: true,
            ahead: 1, behind: 5, rebaseStuck: false
        )
        store.applyGitInfoForTesting([
            PlansStore.GitResult(path: projectDir.path, branch: "main", dirty: false,
                                 mode: .branch, sync: behindMore)
        ])

        XCTAssertEqual(store.projectsPublishCountForTesting, publishesBefore + 1)
        XCTAssertEqual(store.projects.first?.plansSync?.behind, 5)
    }

    func testLegacyApplyGitInfoHookLeavesPlansFieldsNil() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())
        store.reload()
        store.applyGitInfoForTesting([(path: projectDir.path, branch: "main", dirty: false)])
        XCTAssertNil(store.projects.first?.plansMode)
        XCTAssertNil(store.projects.first?.plansSync)
    }

    func testReloadCarriesOverPlansModeAndSyncStatus() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )
        let reader = try makeReader(projectPaths: [projectDir.path])
        let clock = TestClock()
        let store = PlansStore(registryReader: reader, defaults: makeDefaults(), now: clock.source)
        store.reload()
        store.applyGitInfoForTesting([
            PlansStore.GitResult(path: projectDir.path, branch: "main", dirty: false,
                                 mode: .branch, sync: Self.branchSync)
        ])

        // A re-parse (changed `.plans/`) rebuilds the project from the parser,
        // which must not drop the last-known mode/status.
        clock.advance(5)
        try writeTaskFile(
            projectDir: projectDir,
            filename: "002-second.md",
            text: "# Second\n\n**Status:** pending",
            in: "pending"
        )
        store.reload()
        XCTAssertEqual(store.lastReloadParsedPathsForTesting, [projectDir.path])
        XCTAssertEqual(store.projects.first?.plansMode, .branch)
        XCTAssertEqual(store.projects.first?.plansSync, Self.branchSync)

        // Throttled idle ticks keep them too, without republishing.
        let publishesBefore = store.projectsPublishCountForTesting
        clock.advance(5)
        store.reload()
        XCTAssertEqual(store.lastGitPassQueriedPathsForTesting, [])
        XCTAssertEqual(store.projects.first?.plansMode, .branch)
        XCTAssertEqual(store.projects.first?.plansSync, Self.branchSync)
        XCTAssertEqual(store.projectsPublishCountForTesting, publishesBefore)
    }

    func testPerformReloadCarriesPriorPlansFields() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())

        let result = store.performReloadForTesting(priorGitResults: [
            projectDir.path: PlansStore.GitResult(
                path: projectDir.path, branch: "main", dirty: true,
                mode: .local, sync: nil
            )
        ])

        XCTAssertEqual(result.first?.gitBranch, "main")
        XCTAssertEqual(result.first?.gitIsDirty, true)
        XCTAssertEqual(result.first?.plansMode, .local)
        XCTAssertNil(result.first?.plansSync)
    }

    func testFailureOverlayPreservesPlansFields() throws {
        let task = Task(
            id: "007", title: "Run", type: nil, status: .inProgress, created: nil,
            branch: nil, isKeptWorktree: false, blockedBy: [], sections: [],
            howProgress: (done: 0, total: 0), isBlocked: false, isCompletedDir: false,
            isBacklogged: false, failure: nil, modified: nil
        )
        let project = ProjectTasks(
            projectPath: "/p", projectName: "P", lastSeen: "",
            tasks: [task], counts: [.inProgress: 1], activeTasks: [task],
            gitBranch: "main", gitIsDirty: false,
            plansMode: .branch, plansSync: Self.branchSync
        )
        let outcomes: [RunOutcomeKey: RunOutcome] = [
            RunOutcomeKey(projectPath: "/p", taskID: "007"): makeOutcome(
                projectPath: "/p", taskID: "007",
                classification: .truncated, timestamp: "2026-06-04T10:00:00Z"
            )
        ]

        let overlaid = PlansStore.applyFailureOverlayForTesting(to: project, latestOutcomes: outcomes)

        XCTAssertNotNil(overlaid.tasks.first?.failure)
        XCTAssertEqual(overlaid.plansMode, .branch)
        XCTAssertEqual(overlaid.plansSync, Self.branchSync)
    }

    /// The real git second pass resolves the storage mode for every queried
    /// project and only asks for sync status in branch mode.
    func testGitSecondPassResolvesPlansModeForLocalProject() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        func git(_ args: [String]) throws {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.arguments = ["-C", projectDir.path] + args
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try proc.run()
            proc.waitUntilExit()
        }
        try git(["init", "-b", "main"])
        try ".plans/\n".write(
            to: projectDir.appendingPathComponent(".gitignore"),
            atomically: true, encoding: .utf8
        )
        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())
        store.reload()

        let deadline = Date().addingTimeInterval(10)
        while store.projects.first?.plansMode == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(store.projects.first?.plansMode, .local)
        XCTAssertNil(store.projects.first?.plansSync)
    }

    // MARK: - Plans sync scheduler

    /// Records every injected sync call and returns a scripted result. An
    /// optional gate holds the sync open so a test can observe it in flight.
    private final class SyncRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private var _result = PlansGitHelper.SyncResult(outcome: .synced)
        var gate: DispatchSemaphore?

        var calls: [String] { lock.withLock { _calls } }
        var result: PlansGitHelper.SyncResult {
            get { lock.withLock { _result } }
            set { lock.withLock { _result = newValue } }
        }

        var closure: @Sendable (String) -> PlansGitHelper.SyncResult {
            { [self] path in
                lock.withLock { _calls.append(path) }
                gate?.wait()
                return result
            }
        }
    }

    private struct SyncFixture {
        let store: PlansStore
        let clock: TestClock
        let recorder: SyncRecorder
        let path: String
        let projectDir: URL
    }

    /// One registered project, loaded, with the injected sync closure and a
    /// test clock. The project is NOT yet marked branch mode; call
    /// `markBranch` right before each scheduling call, because the real git
    /// pass (which finds no repo in the temp dir) lands whenever the run loop
    /// spins and resets the mode.
    private func makeSyncFixture(defaults: UserDefaults? = nil) throws -> SyncFixture {
        let projectDir = try makeProjectDir(name: "alpha")
        let reader = try makeReader(projectPaths: [projectDir.path])
        let clock = TestClock()
        let recorder = SyncRecorder()
        let store = PlansStore(
            registryReader: reader,
            defaults: defaults ?? makeDefaults(),
            now: clock.source,
            plansSync: recorder.closure
        )
        store.reload()
        return SyncFixture(store: store, clock: clock, recorder: recorder,
                           path: projectDir.path, projectDir: projectDir)
    }

    private func markBranch(
        _ fixture: SyncFixture,
        mode: PlansStorageMode = .branch,
        upstream: Bool = true,
        rebaseStuck: Bool = false
    ) {
        let sync = PlansSyncStatus(
            branch: "plans", remote: "origin", upstream: upstream,
            ahead: 0, behind: 0, rebaseStuck: rebaseStuck
        )
        fixture.store.applyGitInfoForTesting([
            PlansStore.GitResult(path: fixture.path, branch: "main", dirty: false,
                                 mode: mode, sync: mode == .branch ? sync : nil)
        ])
    }

    /// Waits until the store reports a finished sync for the fixture's path.
    private func waitForSyncFinish(_ fixture: SyncFixture) {
        let finished = expectation(description: "sync finished")
        fixture.store.onDidFinishSync = { path in
            if path == fixture.path { finished.fulfill() }
        }
        wait(for: [finished], timeout: 5)
        fixture.store.onDidFinishSync = nil
    }

    func testAutoSyncDefaultsOnAndPersists() throws {
        let defaults = makeDefaults()
        let reader = try makeReader(projectPaths: [])
        let store = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertTrue(store.autoSyncEnabled)

        store.autoSyncEnabled = false
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertFalse(reloaded.autoSyncEnabled)
    }

    func testScheduleSyncsEligibleBranchProjectAndKeepsResult() throws {
        let fixture = try makeSyncFixture()
        fixture.recorder.result = PlansGitHelper.SyncResult(
            outcome: .synced,
            renumbered: [PlansGitHelper.Renumber(from: "041", to: "043")]
        )
        markBranch(fixture)

        XCTAssertEqual(fixture.store.scheduleDueSyncs(), [fixture.path])
        XCTAssertTrue(fixture.store.syncingPaths.contains(fixture.path))
        waitForSyncFinish(fixture)

        XCTAssertEqual(fixture.recorder.calls, [fixture.path])
        XCTAssertFalse(fixture.store.syncingPaths.contains(fixture.path))
        XCTAssertEqual(fixture.store.lastSyncResult(for: fixture.path)?.outcome, .synced)
        XCTAssertEqual(
            fixture.store.lastSyncResult(for: fixture.path)?.renumbered,
            [PlansGitHelper.Renumber(from: "041", to: "043")]
        )
    }

    func testReloadSchedulesDueSyncs() throws {
        let fixture = try makeSyncFixture()
        markBranch(fixture)
        fixture.store.reload()
        waitForSyncFinish(fixture)
        XCTAssertEqual(fixture.recorder.calls, [fixture.path])
    }

    func testScheduledSyncIsDebouncedForNinetySeconds() throws {
        let fixture = try makeSyncFixture()
        markBranch(fixture)
        fixture.store.scheduleDueSyncs()
        waitForSyncFinish(fixture)

        fixture.clock.advance(60)
        markBranch(fixture)
        XCTAssertEqual(fixture.store.syncSkipReason(for: fixture.path, trigger: .scheduled), .debounced)
        XCTAssertEqual(fixture.store.scheduleDueSyncs(), [])

        fixture.clock.advance(31)
        markBranch(fixture)
        XCTAssertEqual(fixture.store.scheduleDueSyncs(), [fixture.path])
        waitForSyncFinish(fixture)
        XCTAssertEqual(fixture.recorder.calls.count, 2)
    }

    func testInFlightSyncIsNotStartedTwice() throws {
        let fixture = try makeSyncFixture()
        let gate = DispatchSemaphore(value: 0)
        fixture.recorder.gate = gate
        markBranch(fixture)
        XCTAssertEqual(fixture.store.scheduleDueSyncs(), [fixture.path])

        fixture.clock.advance(120)
        XCTAssertEqual(fixture.store.syncSkipReason(for: fixture.path, trigger: .manual), .inFlight)
        XCTAssertEqual(fixture.store.scheduleDueSyncs(), [])
        XCTAssertFalse(fixture.store.syncNow(projectPath: fixture.path))

        gate.signal()
        waitForSyncFinish(fixture)
        XCTAssertEqual(fixture.recorder.calls.count, 1)
    }

    func testSchedulerSkipsNonBranchProjects() throws {
        let fixture = try makeSyncFixture()
        for mode in [PlansStorageMode.none, .local, .inline] {
            markBranch(fixture, mode: mode)
            XCTAssertEqual(fixture.store.syncSkipReason(for: fixture.path, trigger: .scheduled), .notBranchMode)
            XCTAssertEqual(fixture.store.scheduleDueSyncs(), [])
        }
        XCTAssertEqual(fixture.recorder.calls, [])
    }

    func testSchedulerSkipsProjectWithoutUpstream() throws {
        let fixture = try makeSyncFixture()
        markBranch(fixture, upstream: false)
        XCTAssertEqual(fixture.store.syncSkipReason(for: fixture.path, trigger: .scheduled), .noUpstream)
        XCTAssertEqual(fixture.store.scheduleDueSyncs(), [])
    }

    func testSchedulerSkipsStuckRebase() throws {
        let fixture = try makeSyncFixture()
        markBranch(fixture, rebaseStuck: true)
        XCTAssertEqual(fixture.store.syncSkipReason(for: fixture.path, trigger: .scheduled), .rebaseStuck)
        XCTAssertEqual(fixture.store.syncSkipReason(for: fixture.path, trigger: .manual), .rebaseStuck)
        XCTAssertEqual(fixture.store.scheduleDueSyncs(), [])
    }

    func testSchedulerSkipsBusyProject() throws {
        let fixture = try makeSyncFixture()
        fixture.store.isProjectBusy = { $0 == fixture.path }
        markBranch(fixture)
        XCTAssertEqual(fixture.store.syncSkipReason(for: fixture.path, trigger: .scheduled), .busy)
        XCTAssertEqual(fixture.store.syncSkipReason(for: fixture.path, trigger: .runFinished), .busy)
        XCTAssertEqual(fixture.store.scheduleDueSyncs(), [])
        XCTAssertEqual(fixture.recorder.calls, [])
    }

    func testSchedulerSkipsWhenAutoSyncIsOff() throws {
        let fixture = try makeSyncFixture()
        fixture.store.autoSyncEnabled = false
        markBranch(fixture)
        XCTAssertEqual(fixture.store.syncSkipReason(for: fixture.path, trigger: .scheduled), .autoSyncOff)
        XCTAssertEqual(fixture.store.syncSkipReason(for: fixture.path, trigger: .runFinished), .autoSyncOff)
        XCTAssertNil(fixture.store.syncSkipReason(for: fixture.path, trigger: .manual))
        XCTAssertEqual(fixture.store.scheduleDueSyncs(), [])
    }

    func testSchedulerSkipsFreshGitLockButNotStaleOne() throws {
        let fixture = try makeSyncFixture()
        let lockDir = fixture.projectDir.appendingPathComponent(".plans/.git-lock")
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)

        try FileManager.default.setAttributes(
            [.modificationDate: fixture.clock.now.addingTimeInterval(-5)],
            ofItemAtPath: lockDir.path
        )
        markBranch(fixture)
        XCTAssertEqual(fixture.store.syncSkipReason(for: fixture.path, trigger: .scheduled), .locked)
        XCTAssertEqual(fixture.store.scheduleDueSyncs(), [])

        try FileManager.default.setAttributes(
            [.modificationDate: fixture.clock.now.addingTimeInterval(-120)],
            ofItemAtPath: lockDir.path
        )
        XCTAssertNil(fixture.store.syncSkipReason(for: fixture.path, trigger: .scheduled),
                     "a lock older than plans-cc's stale window is broken by the helper itself")
    }

    func testConflictBacksOffUntilSyncNow() throws {
        let fixture = try makeSyncFixture()
        fixture.recorder.result = PlansGitHelper.SyncResult(outcome: .conflict, warnings: ["conflict"])
        markBranch(fixture)
        fixture.store.scheduleDueSyncs()
        waitForSyncFinish(fixture)
        XCTAssertTrue(fixture.store.isSyncBackedOff(projectPath: fixture.path))

        fixture.clock.advance(600)
        markBranch(fixture)
        XCTAssertEqual(fixture.store.syncSkipReason(for: fixture.path, trigger: .scheduled), .conflictBackoff)
        XCTAssertEqual(fixture.store.syncSkipReason(for: fixture.path, trigger: .runFinished), .conflictBackoff)
        XCTAssertEqual(fixture.store.scheduleDueSyncs(), [])
        XCTAssertEqual(fixture.recorder.calls.count, 1)

        fixture.recorder.result = PlansGitHelper.SyncResult(outcome: .synced)
        XCTAssertTrue(fixture.store.syncNow(projectPath: fixture.path))
        XCTAssertFalse(fixture.store.isSyncBackedOff(projectPath: fixture.path))
        waitForSyncFinish(fixture)
        XCTAssertEqual(fixture.recorder.calls.count, 2)
        XCTAssertEqual(fixture.store.lastSyncResult(for: fixture.path)?.outcome, .synced)

        fixture.clock.advance(100)
        markBranch(fixture)
        XCTAssertEqual(fixture.store.scheduleDueSyncs(), [fixture.path])
        waitForSyncFinish(fixture)
    }

    func testSyncNowBypassesDebounceAndAutoSyncFlag() throws {
        let fixture = try makeSyncFixture()
        markBranch(fixture)
        fixture.store.scheduleDueSyncs()
        waitForSyncFinish(fixture)

        fixture.store.autoSyncEnabled = false
        fixture.clock.advance(5)
        markBranch(fixture)
        XCTAssertTrue(fixture.store.syncNow(projectPath: fixture.path))
        waitForSyncFinish(fixture)
        XCTAssertEqual(fixture.recorder.calls.count, 2)
    }

    func testSyncAfterRunBypassesDebounce() throws {
        let fixture = try makeSyncFixture()
        markBranch(fixture)
        fixture.store.scheduleDueSyncs()
        waitForSyncFinish(fixture)

        fixture.clock.advance(5)
        markBranch(fixture)
        XCTAssertTrue(fixture.store.syncAfterRun(inProject: fixture.path))
        waitForSyncFinish(fixture)
        XCTAssertEqual(fixture.recorder.calls.count, 2)
    }

    func testSyncAfterRunMatchesStandardizedPath() throws {
        let fixture = try makeSyncFixture()
        markBranch(fixture)
        XCTAssertTrue(fixture.store.syncAfterRun(inProject: fixture.path + "/"))
        waitForSyncFinish(fixture)
        XCTAssertEqual(fixture.recorder.calls, [fixture.path])
    }

    func testFinishedSyncForcesGitRequeryForThatPath() throws {
        let fixture = try makeSyncFixture()
        fixture.clock.advance(5)
        fixture.store.reload()
        XCTAssertEqual(fixture.store.lastGitPassQueriedPathsForTesting, [],
                       "inside the throttle window the poll must not re-query git")

        markBranch(fixture)
        XCTAssertTrue(fixture.store.syncNow(projectPath: fixture.path))
        waitForSyncFinish(fixture)
        XCTAssertEqual(fixture.store.lastGitPassQueriedPathsForTesting, [fixture.path])
    }

    // MARK: - Remote presence (gates the Convert action)

    func testApplyGitInfoMergesHasRemote() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())
        store.reload()
        XCTAssertNil(store.projects.first?.gitHasRemote)

        store.applyGitInfoForTesting([
            PlansStore.GitResult(path: projectDir.path, branch: "main", dirty: false,
                                 mode: .local, hasRemote: true)
        ])
        XCTAssertEqual(store.projects.first?.gitHasRemote, true)
    }

    func testPerformReloadAndFailureOverlayCarryHasRemote() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())
        let result = store.performReloadForTesting(priorGitResults: [
            projectDir.path: PlansStore.GitResult(
                path: projectDir.path, branch: "main", dirty: false,
                mode: .local, hasRemote: true
            )
        ])
        XCTAssertEqual(result.first?.gitHasRemote, true)

        let task = Task(
            id: "007", title: "Run", type: nil, status: .inProgress, created: nil,
            branch: nil, isKeptWorktree: false, blockedBy: [], sections: [],
            howProgress: (done: 0, total: 0), isBlocked: false, isCompletedDir: false,
            isBacklogged: false, failure: nil, modified: nil
        )
        let project = ProjectTasks(
            projectPath: "/p", projectName: "P", lastSeen: "",
            tasks: [task], counts: [.inProgress: 1], activeTasks: [task],
            plansMode: .local, gitHasRemote: true
        )
        let outcomes: [RunOutcomeKey: RunOutcome] = [
            RunOutcomeKey(projectPath: "/p", taskID: "007"): makeOutcome(
                projectPath: "/p", taskID: "007",
                classification: .truncated, timestamp: "2026-06-04T10:00:00Z"
            )
        ]
        let overlaid = PlansStore.applyFailureOverlayForTesting(to: project, latestOutcomes: outcomes)
        XCTAssertNotNil(overlaid.tasks.first?.failure)
        XCTAssertEqual(overlaid.gitHasRemote, true)
    }

    func testGitSecondPassResolvesHasRemoteForLocalProject() throws {
        let projectDir = try makeProjectDir(name: "alpha")
        func git(_ args: [String]) throws {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.arguments = ["-C", projectDir.path] + args
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try proc.run()
            proc.waitUntilExit()
        }
        try git(["init", "-b", "main"])
        try git(["remote", "add", "origin", "https://example.invalid/repo.git"])
        try ".plans/\n".write(
            to: projectDir.appendingPathComponent(".gitignore"),
            atomically: true, encoding: .utf8
        )
        let reader = try makeReader(projectPaths: [projectDir.path])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())
        store.reload()

        let deadline = Date().addingTimeInterval(10)
        while store.projects.first?.plansMode == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(store.projects.first?.plansMode, .local)
        XCTAssertEqual(store.projects.first?.gitHasRemote, true)
    }

    // MARK: - Convert to tracked plans (migrate)

    func testConvertSkipReasonRule() {
        XCTAssertNil(PlansStore.convertSkipReason(mode: .local, hasRemote: true, isBusy: false, isPaused: false))
        XCTAssertEqual(PlansStore.convertSkipReason(mode: nil, hasRemote: true, isBusy: false, isPaused: false), .notLocalMode)
        for mode in [PlansStorageMode.none, .inline, .branch] {
            XCTAssertEqual(PlansStore.convertSkipReason(mode: mode, hasRemote: true, isBusy: false, isPaused: false), .notLocalMode)
        }
        XCTAssertEqual(PlansStore.convertSkipReason(mode: .local, hasRemote: false, isBusy: false, isPaused: false), .noRemote)
        XCTAssertEqual(PlansStore.convertSkipReason(mode: .local, hasRemote: nil, isBusy: false, isPaused: false), .noRemote)
        XCTAssertEqual(PlansStore.convertSkipReason(mode: .local, hasRemote: true, isBusy: true, isPaused: false), .busy)
        XCTAssertEqual(PlansStore.convertSkipReason(mode: .local, hasRemote: true, isBusy: false, isPaused: true), .inProgress)
    }

    /// Records every injected migrate call and returns a scripted result,
    /// optionally held open by a gate.
    private final class MigrateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var result = PlansGitHelper.MigrateResult(outcome: .ok("plans moved to branch plans"))
        var gate: DispatchSemaphore?

        var calls: [String] { lock.withLock { _calls } }

        var closure: @Sendable (String) -> PlansGitHelper.MigrateResult {
            { [self] path in
                lock.withLock { _calls.append(path) }
                gate?.wait()
                return lock.withLock { result }
            }
        }
    }

    private struct MigrateFixture {
        let store: PlansStore
        let clock: TestClock
        let recorder: MigrateRecorder
        let path: String
        let projectDir: URL
    }

    private func makeMigrateFixture() throws -> MigrateFixture {
        let projectDir = try makeProjectDir(name: "alpha")
        try writeTaskFile(
            projectDir: projectDir,
            filename: "001-first.md",
            text: "# First\n\n**Status:** pending",
            in: "pending"
        )
        let reader = try makeReader(projectPaths: [projectDir.path])
        let clock = TestClock()
        let recorder = MigrateRecorder()
        let store = PlansStore(
            registryReader: reader,
            defaults: makeDefaults(),
            now: clock.source,
            plansMigrate: recorder.closure
        )
        store.reload()
        return MigrateFixture(store: store, clock: clock, recorder: recorder,
                              path: projectDir.path, projectDir: projectDir)
    }

    /// Marks the fixture project local mode with a remote. Call right before
    /// acting: the real git pass (no repo in the temp dir) resets it whenever
    /// the run loop spins.
    private func markLocal(_ fixture: MigrateFixture, hasRemote: Bool = true) {
        fixture.store.applyGitInfoForTesting([
            PlansStore.GitResult(path: fixture.path, branch: "main", dirty: false,
                                 mode: .local, hasRemote: hasRemote)
        ])
    }

    func testConvertRefusedUnlessEligible() throws {
        let fixture = try makeMigrateFixture()
        markLocal(fixture, hasRemote: false)
        XCTAssertEqual(fixture.store.convertSkipReason(for: fixture.path), .noRemote)
        XCTAssertFalse(fixture.store.convertToTrackedPlans(projectPath: fixture.path) { _ in
            XCTFail("an ineligible convert must not complete")
        })

        markLocal(fixture)
        fixture.store.isProjectBusy = { $0 == fixture.path }
        XCTAssertEqual(fixture.store.convertSkipReason(for: fixture.path), .busy)
        XCTAssertFalse(fixture.store.convertToTrackedPlans(projectPath: fixture.path) { _ in })

        XCTAssertEqual(fixture.store.convertSkipReason(for: "/nope"), .unknownProject)
        XCTAssertEqual(fixture.recorder.calls, [])
    }

    func testConvertPausesThePathWhileMigrateRuns() throws {
        let fixture = try makeMigrateFixture()
        let gate = DispatchSemaphore(value: 0)
        fixture.recorder.gate = gate
        markLocal(fixture)

        var completed: PlansGitHelper.MigrateResult?
        let finished = expectation(description: "migrate finished")
        XCTAssertTrue(fixture.store.convertToTrackedPlans(projectPath: fixture.path) { result in
            completed = result
            finished.fulfill()
        })
        XCTAssertTrue(fixture.store.pausedPaths.contains(fixture.path))
        XCTAssertEqual(fixture.store.convertSkipReason(for: fixture.path), .inProgress)
        XCTAssertFalse(fixture.store.convertToTrackedPlans(projectPath: fixture.path) { _ in })

        // Migrate moves `.plans` aside: a reload must keep the last parse
        // rather than parse the missing directory as an empty project.
        try FileManager.default.removeItem(at: fixture.projectDir.appendingPathComponent(".plans"))
        fixture.clock.advance(60)
        fixture.store.reload()
        XCTAssertEqual(fixture.store.lastReloadParsedPathsForTesting, [])
        XCTAssertEqual(fixture.store.projects.first?.tasks.map(\.id), ["001"])
        XCTAssertEqual(fixture.store.lastGitPassQueriedPathsForTesting, [],
                       "a paused path must not be git-queried, even past the throttle window")

        // A git result that lands mid-migrate is dropped for the paused path.
        fixture.store.applyGitInfoForTesting([
            PlansStore.GitResult(path: fixture.path, branch: nil, dirty: nil, mode: PlansStorageMode.none)
        ])
        XCTAssertEqual(fixture.store.projects.first?.plansMode, .local)

        // Sync stays off for the path too.
        XCTAssertEqual(fixture.store.syncSkipReason(for: fixture.path, trigger: .manual), .paused)

        gate.signal()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(completed?.outcome, .ok("plans moved to branch plans"))
        XCTAssertFalse(fixture.store.pausedPaths.contains(fixture.path))
        XCTAssertEqual(fixture.store.lastGitPassQueriedPathsForTesting, [fixture.path],
                       "a finished migrate forces a mode re-query")
        XCTAssertEqual(fixture.recorder.calls, [fixture.path])
    }

    func testConvertErrorIsReportedAndNotRetried() throws {
        let fixture = try makeMigrateFixture()
        fixture.recorder.result = PlansGitHelper.MigrateResult(
            outcome: .error("verify failed; backup kept at /tmp/plans-backup", backupPath: "/tmp/plans-backup")
        )
        markLocal(fixture)

        var completed: PlansGitHelper.MigrateResult?
        let finished = expectation(description: "migrate finished")
        XCTAssertTrue(fixture.store.convertToTrackedPlans(projectPath: fixture.path) { result in
            completed = result
            finished.fulfill()
        })
        wait(for: [finished], timeout: 5)

        XCTAssertEqual(completed?.outcome,
                       .error("verify failed; backup kept at /tmp/plans-backup", backupPath: "/tmp/plans-backup"))
        XCTAssertFalse(fixture.store.pausedPaths.contains(fixture.path))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(fixture.recorder.calls.count, 1)
    }
}
