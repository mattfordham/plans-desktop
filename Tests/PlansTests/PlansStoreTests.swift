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
}
