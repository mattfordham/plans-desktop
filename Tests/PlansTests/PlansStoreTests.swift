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

    // MARK: - Capture draft image data (#048)

    func testCaptureDraftImageDataRoundTripsAcrossStoreInstances() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        // A small PNG magic-prefix byte sequence stands in for image bytes.
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])

        let store = PlansStore(registryReader: reader, defaults: defaults)
        let draft = PlansStore.CaptureDraft(
            text: "hi",
            execute: false,
            elaborate: false,
            imageData: pngBytes
        )
        store.setDraft(draft, for: "/proj")

        // Visible immediately on the same store.
        XCTAssertEqual(store.draft(for: "/proj")?.imageData, pngBytes)

        // A fresh store over the SAME defaults restores the image bytes.
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        let restored = try XCTUnwrap(reloaded.draft(for: "/proj"))
        XCTAssertEqual(restored.imageData, pngBytes)
    }

    func testCaptureDraftNilImageDataRoundTripsAsNil() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()

        let store = PlansStore(registryReader: reader, defaults: defaults)
        let draft = PlansStore.CaptureDraft(
            text: "hi",
            execute: false,
            elaborate: false,
            imageData: nil
        )
        store.setDraft(draft, for: "/proj")

        XCTAssertNil(store.draft(for: "/proj")?.imageData)

        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        let restored = try XCTUnwrap(reloaded.draft(for: "/proj"))
        XCTAssertNil(restored.imageData)
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
}
