import XCTest
@testable import Plans

/// Tests for `TaskParser`, mirroring the behavior of plans-cc
/// `lib/parse-tasks.js` (Data Contract 2, §5). Single-file parsing is exercised
/// via `parse(filename:text:isCompletedDir:)`; project-level assembly is
/// exercised via `parseProject(at:)` against fixtures written into a unique temp
/// directory (the same temp-dir pattern as `RegistryReaderTests`).
final class TaskParserTests: XCTestCase {
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
    /// `<tempDir>/.plans/<subdir>/`, creating intermediate dirs as needed.
    private func writeTaskFile(
        filename: String,
        text: String,
        in subdir: String
    ) throws {
        let dir = tempDir
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

    /// Creates an empty `<tempDir>/.plans/<subdir>/` directory.
    private func makeEmptyDir(_ subdir: String) throws {
        let dir = tempDir
            .appendingPathComponent(".plans")
            .appendingPathComponent(subdir)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Single-file: id + title

    func testIdFromFilenamePrefix() {
        let task = TaskParser().parse(
            filename: "042-some-long-slug.md",
            text: "# Anything",
            isCompletedDir: false
        )
        XCTAssertEqual(task.id, "042")
    }

    func testTitleExtractedFromFirstHeadingLine() {
        let text = """
        # My Task Title

        **Status:** pending
        """
        let task = TaskParser().parse(filename: "001-x.md", text: text, isCompletedDir: false)
        XCTAssertEqual(task.title, "My Task Title")
    }

    func testMissingTitleIsNil() {
        let text = """
        **Status:** pending

        ## How
        - [ ] do it
        """
        let task = TaskParser().parse(filename: "001-x.md", text: text, isCompletedDir: false)
        XCTAssertNil(task.title)
    }

    // MARK: - Single-file: frontmatter present / absent

    func testAllFrontmatterFieldsPresent() {
        let text = """
        # Title

        **ID:** 007
        **Created:** 2026-06-04T14:41
        **Type:** feature
        **Status:** in-progress
        **Branch:** feature/007-x
        **Worktree:** /Users/x/.worktrees/007-x
        **Blocked by:** 001 002
        """
        let task = TaskParser().parse(filename: "007-x.md", text: text, isCompletedDir: false)
        XCTAssertEqual(task.created, "2026-06-04T14:41")
        XCTAssertEqual(task.type, .feature)
        XCTAssertEqual(task.status, .inProgress)
        XCTAssertEqual(task.branch, "feature/007-x")
        XCTAssertEqual(task.blockedBy, ["001", "002"])
        XCTAssertTrue(task.isKeptWorktree)
    }

    func testKeptWorktreeTrueWhenWorktreeFieldPresent() {
        let text = """
        # Title

        **ID:** 007
        **Status:** review
        **Worktree:** /Users/x/.worktrees/007-x
        """
        let task = TaskParser().parse(filename: "007-x.md", text: text, isCompletedDir: false)
        XCTAssertTrue(task.isKeptWorktree)
    }

    func testKeptWorktreeFalseWhenWorktreeFieldAbsent() {
        let task = TaskParser().parse(
            filename: "008-x.md",
            text: "# Title only",
            isCompletedDir: false
        )
        XCTAssertFalse(task.isKeptWorktree)
    }

    func testKeptWorktreeFalseWhenWorktreeFieldEmpty() {
        let text = """
        # Title

        **ID:** 009
        **Status:** review
        **Worktree:**
        """
        let task = TaskParser().parse(filename: "009-x.md", text: text, isCompletedDir: false)
        XCTAssertFalse(task.isKeptWorktree)
    }

    // MARK: - Single-file: showsKeptWorktreeMarker (#086)

    func testShowsKeptWorktreeMarkerTrueWhenKeptAndReview() {
        let text = """
        # Title

        **ID:** 007
        **Status:** review
        **Worktree:** /Users/x/.worktrees/007-x
        """
        let task = TaskParser().parse(filename: "007-x.md", text: text, isCompletedDir: false)
        XCTAssertTrue(task.showsKeptWorktreeMarker)
    }

    func testShowsKeptWorktreeMarkerTrueWhenKeptAndInReview() {
        let text = """
        # Title

        **ID:** 007
        **Status:** in-review
        **Worktree:** /Users/x/.worktrees/007-x
        """
        let task = TaskParser().parse(filename: "007-x.md", text: text, isCompletedDir: false)
        XCTAssertTrue(task.showsKeptWorktreeMarker)
    }

    func testShowsKeptWorktreeMarkerFalseWhenInProgressWithLiveWorktree() {
        // Mirrors testAllFrontmatterFieldsPresent: an in-progress task can carry
        // a live **Worktree:** field, but the marker must NOT display there.
        let text = """
        # Title

        **ID:** 007
        **Created:** 2026-06-04T14:41
        **Type:** feature
        **Status:** in-progress
        **Branch:** feature/007-x
        **Worktree:** /Users/x/.worktrees/007-x
        **Blocked by:** 001 002
        """
        let task = TaskParser().parse(filename: "007-x.md", text: text, isCompletedDir: false)
        XCTAssertTrue(task.isKeptWorktree)
        XCTAssertFalse(task.showsKeptWorktreeMarker)
    }

    func testShowsKeptWorktreeMarkerFalseWhenNotKeptRegardlessOfStatus() {
        let text = """
        # Title

        **ID:** 007
        **Status:** review
        """
        let task = TaskParser().parse(filename: "007-x.md", text: text, isCompletedDir: false)
        XCTAssertFalse(task.isKeptWorktree)
        XCTAssertFalse(task.showsKeptWorktreeMarker)
    }

    func testShowsKeptWorktreeMarkerFalseWhenStatusNil() {
        let text = """
        # Title

        **ID:** 007
        **Worktree:** /Users/x/.worktrees/007-x
        """
        let task = TaskParser().parse(filename: "007-x.md", text: text, isCompletedDir: false)
        XCTAssertTrue(task.isKeptWorktree)
        XCTAssertNil(task.status)
        XCTAssertFalse(task.showsKeptWorktreeMarker)
    }

    func testAllFrontmatterFieldsAbsent() {
        let task = TaskParser().parse(
            filename: "008-x.md",
            text: "# Title only",
            isCompletedDir: false
        )
        XCTAssertNil(task.created)
        XCTAssertNil(task.type)
        XCTAssertNil(task.status)
        XCTAssertNil(task.branch)
        XCTAssertEqual(task.blockedBy, [])
    }

    func testUnrecognizedTypeAndStatusDecodeToNil() {
        let text = """
        # Title

        **Type:** epic
        **Status:** archived
        """
        let task = TaskParser().parse(filename: "009-x.md", text: text, isCompletedDir: false)
        XCTAssertNil(task.type)
        XCTAssertNil(task.status)
    }

    // MARK: - Single-file: sections

    func testSectionSplittingPreservesBodiesVerbatim() {
        let text = """
        # Title

        **Status:** pending

        ## What
        Line one.

        Line two with blank above.

        ## Why
        Because.
        """
        let task = TaskParser().parse(filename: "010-x.md", text: text, isCompletedDir: false)
        XCTAssertEqual(task.sections.count, 2)
        XCTAssertEqual(task.sections[0].heading, "What")
        XCTAssertEqual(
            task.sections[0].body,
            "Line one.\n\nLine two with blank above.\n"
        )
        XCTAssertEqual(task.sections[1].heading, "Why")
        XCTAssertEqual(task.sections[1].body, "Because.")
    }

    // MARK: - Single-file: How-progress

    func testHowProgressCountsOnlyWithinHow() {
        let text = """
        # Title

        ## What
        - [ ] this is not in How and must be ignored
        - [x] also ignored

        ## How
        - [x] done one
        - [X] done two uppercase
        - [ ] not done
        """
        let task = TaskParser().parse(filename: "011-x.md", text: text, isCompletedDir: false)
        XCTAssertEqual(task.howProgress.done, 2)
        XCTAssertEqual(task.howProgress.total, 3)
    }

    func testHowProgressZeroWhenNoHowSection() {
        let text = """
        # Title

        ## What
        - [ ] a checkbox outside How
        """
        let task = TaskParser().parse(filename: "012-x.md", text: text, isCompletedDir: false)
        XCTAssertEqual(task.howProgress.done, 0)
        XCTAssertEqual(task.howProgress.total, 0)
    }

    func testHowProgressZeroWhenHowHasNoCheckboxes() {
        let text = """
        # Title

        ## How
        Just prose, no checkboxes here.
        """
        let task = TaskParser().parse(filename: "013-x.md", text: text, isCompletedDir: false)
        XCTAssertEqual(task.howProgress.done, 0)
        XCTAssertEqual(task.howProgress.total, 0)
    }

    // MARK: - Single-file: completed-dir forces status

    func testCompletedDirForcesCompletedStatus() {
        let text = """
        # Title

        **Status:** in-progress
        """
        let task = TaskParser().parse(filename: "014-x.md", text: text, isCompletedDir: true)
        XCTAssertEqual(task.status, .completed)
        XCTAssertTrue(task.isCompletedDir)
    }

    // MARK: - Project: blocked-by resolution

    func testTaskIsBlockedWhenDependencyAbsentFromCompleted() throws {
        try writeTaskFile(
            filename: "020-blocked.md",
            text: """
            # Blocked task

            **Status:** pending
            **Blocked by:** 099
            """,
            in: "pending"
        )
        let project = TaskParser().parseProject(at: tempDir.path)
        let task = try XCTUnwrap(project.tasks.first { $0.id == "020" })
        XCTAssertTrue(task.isBlocked)
    }

    func testTaskIsUnblockedWhenAllDependenciesCompleted() throws {
        try writeTaskFile(
            filename: "021-depends.md",
            text: """
            # Depends

            **Status:** pending
            **Blocked by:** 001 002
            """,
            in: "pending"
        )
        try writeTaskFile(
            filename: "001-a.md",
            text: "# A\n\n**Status:** completed",
            in: "completed"
        )
        try writeTaskFile(
            filename: "002-b.md",
            text: "# B\n\n**Status:** completed",
            in: "completed"
        )
        let project = TaskParser().parseProject(at: tempDir.path)
        let task = try XCTUnwrap(project.tasks.first { $0.id == "021" })
        XCTAssertFalse(task.isBlocked)
    }

    func testTaskIsBlockedWhenOnlySomeDependenciesCompleted() throws {
        try writeTaskFile(
            filename: "022-partial.md",
            text: """
            # Partial

            **Status:** pending
            **Blocked by:** 001 003
            """,
            in: "pending"
        )
        try writeTaskFile(
            filename: "001-a.md",
            text: "# A\n\n**Status:** completed",
            in: "completed"
        )
        let project = TaskParser().parseProject(at: tempDir.path)
        let task = try XCTUnwrap(project.tasks.first { $0.id == "022" })
        // 003 is absent from completed/, so still blocked.
        XCTAssertTrue(task.isBlocked)
    }

    func testTaskWithoutBlockedByIsNotBlocked() throws {
        try writeTaskFile(
            filename: "023-free.md",
            text: "# Free\n\n**Status:** pending",
            in: "pending"
        )
        let project = TaskParser().parseProject(at: tempDir.path)
        let task = try XCTUnwrap(project.tasks.first { $0.id == "023" })
        XCTAssertFalse(task.isBlocked)
    }

    // MARK: - Project: completed dir forces status at project level

    func testProjectCompletedDirForcesStatusOverFrontmatter() throws {
        try writeTaskFile(
            filename: "030-done.md",
            text: """
            # Done but says in-progress

            **Status:** in-progress
            """,
            in: "completed"
        )
        let project = TaskParser().parseProject(at: tempDir.path)
        let task = try XCTUnwrap(project.tasks.first { $0.id == "030" })
        XCTAssertEqual(task.status, .completed)
    }

    // MARK: - Project: tolerance of missing / empty dirs

    func testMissingPlansDirsTolerated() {
        // No .plans dir at all.
        let project = TaskParser().parseProject(at: tempDir.path)
        XCTAssertTrue(project.tasks.isEmpty)
        XCTAssertTrue(project.activeTasks.isEmpty)
        XCTAssertTrue(project.counts.isEmpty)
    }

    func testEmptyDirsTolerated() throws {
        try makeEmptyDir("pending")
        try makeEmptyDir("completed")
        let project = TaskParser().parseProject(at: tempDir.path)
        XCTAssertTrue(project.tasks.isEmpty)
        XCTAssertTrue(project.activeTasks.isEmpty)
        XCTAssertTrue(project.counts.isEmpty)
    }

    func testOnlyMarkdownFilesAreParsed() throws {
        try writeTaskFile(
            filename: "040-real.md",
            text: "# Real\n\n**Status:** pending",
            in: "pending"
        )
        try writeTaskFile(
            filename: "README.txt",
            text: "not a task",
            in: "pending"
        )
        let project = TaskParser().parseProject(at: tempDir.path)
        XCTAssertEqual(project.tasks.map(\.id), ["040"])
    }

    // MARK: - Project: counts

    func testPerProjectCountsByStatus() throws {
        try writeTaskFile(
            filename: "050-a.md",
            text: "# A\n\n**Status:** pending",
            in: "pending"
        )
        try writeTaskFile(
            filename: "051-b.md",
            text: "# B\n\n**Status:** in-progress",
            in: "pending"
        )
        try writeTaskFile(
            filename: "052-c.md",
            text: "# C\n\n**Status:** pending",
            in: "pending"
        )
        // No status at all — must not count toward any bucket.
        try writeTaskFile(
            filename: "053-d.md",
            text: "# D",
            in: "pending"
        )
        try writeTaskFile(
            filename: "010-done.md",
            text: "# Done\n\n**Status:** anything",
            in: "completed"
        )
        let project = TaskParser().parseProject(at: tempDir.path)
        XCTAssertEqual(project.counts[.pending], 2)
        XCTAssertEqual(project.counts[.inProgress], 1)
        XCTAssertEqual(project.counts[.completed], 1)
        XCTAssertNil(project.counts[.elaborated])
        // Five tasks total parsed; the nil-status one is counted by no bucket.
        XCTAssertEqual(project.tasks.count, 5)
        XCTAssertEqual(project.counts.values.reduce(0, +), 4)
    }

    // MARK: - Project: active-task sort order

    func testActiveTasksSortedByStatusPriorityThenId() throws {
        // Active rows sort by status (reverse of the header badge `glanceOrder`:
        // in-review at top, then review, in-progress, elaborated, pending at
        // bottom) then by id ascending. Deliberately out of order on disk; ids
        // chosen so id-ascending differs from status priority where statuses tie.
        try writeTaskFile(filename: "060-pending.md", text: "# p\n\n**Status:** pending", in: "pending")
        try writeTaskFile(filename: "061-elaborated.md", text: "# e\n\n**Status:** elaborated", in: "pending")
        try writeTaskFile(filename: "062-review.md", text: "# r\n\n**Status:** review", in: "pending")
        try writeTaskFile(filename: "063-inreview.md", text: "# ir\n\n**Status:** in-review", in: "pending")
        try writeTaskFile(filename: "064-inprogress.md", text: "# ip\n\n**Status:** in-progress", in: "pending")
        // Two with the same status to verify id-ascending tiebreak.
        try writeTaskFile(filename: "065-pending2.md", text: "# p2\n\n**Status:** pending", in: "pending")
        // A completed task must be excluded from activeTasks.
        try writeTaskFile(filename: "010-done.md", text: "# done\n\n**Status:** completed", in: "completed")
        // A nil-status task must also be excluded.
        try writeTaskFile(filename: "066-nostatus.md", text: "# no", in: "pending")

        let project = TaskParser().parseProject(at: tempDir.path)
        let orderedIds = project.activeTasks.map(\.id)
        // in-review (063) > review (062) > in-progress (064) > elaborated (061)
        // > pending (060, 065 ascending id tiebreak).
        XCTAssertEqual(
            orderedIds,
            ["063", "062", "064", "061", "060", "065"]
        )
    }

    // MARK: - Project: name from path

    func testProjectNameFromLastPathComponent() throws {
        try writeTaskFile(
            filename: "070-x.md",
            text: "# X\n\n**Status:** pending",
            in: "pending"
        )
        let project = TaskParser().parseProject(at: tempDir.path)
        // The project name is the titleized last path component (the raw dir
        // name is run through `String.titleized()` at the single derivation
        // site in `TaskParser`).
        XCTAssertEqual(project.projectName, tempDir.lastPathComponent.titleized())
        XCTAssertEqual(project.projectPath, tempDir.path)
    }

    // MARK: - Project change signature (#066 Step 3)

    /// A stable, cheap signature for a project's `.plans/` state must be equal
    /// across two consecutive computations when nothing changed on disk. This is
    /// the property the reload change-gate relies on: an equal signature means
    /// "safe to reuse the previous parse result".
    func testProjectSignatureIsStableWhenNothingChanges() throws {
        try writeTaskFile(
            filename: "001-a.md",
            text: "# A\n\n**Status:** pending",
            in: "pending"
        )
        try writeTaskFile(
            filename: "002-b.md",
            text: "# B\n\n**Status:** completed",
            in: "completed"
        )
        let parser = TaskParser()
        let first = parser.projectSignature(at: tempDir.path)
        let second = parser.projectSignature(at: tempDir.path)
        XCTAssertEqual(first, second)
    }

    /// Adding a task file must change the signature (a new directory entry).
    func testProjectSignatureChangesWhenFileAdded() throws {
        try writeTaskFile(
            filename: "001-a.md",
            text: "# A\n\n**Status:** pending",
            in: "pending"
        )
        let parser = TaskParser()
        let before = parser.projectSignature(at: tempDir.path)
        try writeTaskFile(
            filename: "003-c.md",
            text: "# C\n\n**Status:** pending",
            in: "pending"
        )
        XCTAssertNotEqual(before, parser.projectSignature(at: tempDir.path))
    }

    /// Deleting a task file must change the signature.
    func testProjectSignatureChangesWhenFileDeleted() throws {
        try writeTaskFile(
            filename: "001-a.md",
            text: "# A\n\n**Status:** pending",
            in: "pending"
        )
        try writeTaskFile(
            filename: "003-c.md",
            text: "# C\n\n**Status:** pending",
            in: "pending"
        )
        let parser = TaskParser()
        let before = parser.projectSignature(at: tempDir.path)
        try FileManager.default.removeItem(
            at: tempDir
                .appendingPathComponent(".plans")
                .appendingPathComponent("pending")
                .appendingPathComponent("003-c.md")
        )
        XCTAssertNotEqual(before, parser.projectSignature(at: tempDir.path))
    }

    /// THE critical case (#066 Step 3): editing an EXISTING file's contents in
    /// place — same filename, same directory entries, so the containing
    /// directory's own mtime is not a reliable signal. The signature must still
    /// change, otherwise edits to existing tasks would silently stop surfacing.
    ///
    /// The edit here also changes the file's SIZE, so the signature catches it
    /// even on a filesystem with coarse mtime granularity.
    func testProjectSignatureChangesWhenExistingFileEditedInPlace() throws {
        try writeTaskFile(
            filename: "001-a.md",
            text: "# A\n\n**Status:** pending",
            in: "pending"
        )
        let parser = TaskParser()
        let before = parser.projectSignature(at: tempDir.path)

        try writeTaskFile(
            filename: "001-a.md",
            text: "# A\n\n**Status:** in-progress\n\n## How\n\n- [ ] step one",
            in: "pending"
        )
        XCTAssertNotEqual(before, parser.projectSignature(at: tempDir.path))
    }

    /// A same-length in-place edit (identical byte count) must ALSO be caught —
    /// size alone is not sufficient, so the signature has to include per-file
    /// modification timestamps too. The file's mtime is explicitly advanced to
    /// defeat sub-second filesystem timestamp granularity, which is exactly what
    /// a real editor write does (it stamps a new mtime).
    func testProjectSignatureChangesWhenExistingFileEditedToSameLength() throws {
        try writeTaskFile(
            filename: "001-a.md",
            text: "# A\n\n**Status:** pending",
            in: "pending"
        )
        let fileURL = tempDir
            .appendingPathComponent(".plans")
            .appendingPathComponent("pending")
            .appendingPathComponent("001-a.md")
        let parser = TaskParser()
        let before = parser.projectSignature(at: tempDir.path)

        // Same byte count as "pending" -> "PENDING" is identical length; use a
        // different 7-character status-ish body so only the bytes differ.
        try "# A\n\n**Status:** review!".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: fileURL.path
        )
        XCTAssertNotEqual(before, parser.projectSignature(at: tempDir.path))
    }

    /// Moving a file from `pending/` to `completed/` (what `plan-complete` does)
    /// must change the signature — both directories' entry sets change.
    func testProjectSignatureChangesWhenFileMovedToCompleted() throws {
        try writeTaskFile(
            filename: "001-a.md",
            text: "# A\n\n**Status:** pending",
            in: "pending"
        )
        try makeEmptyDir("completed")
        let parser = TaskParser()
        let before = parser.projectSignature(at: tempDir.path)

        try FileManager.default.moveItem(
            at: tempDir.appendingPathComponent(".plans/pending/001-a.md"),
            to: tempDir.appendingPathComponent(".plans/completed/001-a.md")
        )
        XCTAssertNotEqual(before, parser.projectSignature(at: tempDir.path))
    }

    /// A project with no `.plans/` directories at all yields a signature rather
    /// than crashing, and that signature is stable — tolerant, like every other
    /// parser path.
    func testProjectSignatureForMissingDirectoriesIsStable() {
        let missing = tempDir.appendingPathComponent("no-such-project").path
        let parser = TaskParser()
        XCTAssertEqual(
            parser.projectSignature(at: missing),
            parser.projectSignature(at: missing)
        )
    }

    // MARK: - Project: backlog (#077)

    /// A file under `.plans/backlog/` is surfaced in `backloggedTasks` with
    /// `isBacklogged == true` and its REAL `**Status:**` preserved (backlog is a
    /// source directory, NOT a status — it is never forced to `.completed` or any
    /// other status).
    func testBackloggedTasksPreserveRealStatus() throws {
        try writeTaskFile(
            filename: "080-backlogged.md",
            text: """
            # Backlogged task

            **Status:** elaborated
            """,
            in: "backlog"
        )
        let project = TaskParser().parseProject(at: tempDir.path)
        let task = try XCTUnwrap(project.backloggedTasks.first { $0.id == "080" })
        XCTAssertTrue(task.isBacklogged)
        // Real status preserved — NOT forced to completed/anything.
        XCTAssertEqual(task.status, .elaborated)
        XCTAssertFalse(task.isCompletedDir)
    }

    /// A backlogged task must NOT leak into `tasks`, `counts`, or `activeTasks`,
    /// and `hasOutstandingWork` must be `false` when the ONLY tasks present are
    /// backlogged (no pending/active work).
    func testBackloggedTasksDoNotLeakIntoActiveCountsOrOutstanding() throws {
        try writeTaskFile(
            filename: "081-backlogged.md",
            text: """
            # Backlogged pending

            **Status:** pending
            """,
            in: "backlog"
        )
        let project = TaskParser().parseProject(at: tempDir.path)
        XCTAssertEqual(project.backloggedTasks.map(\.id), ["081"])
        // Does not leak into the main collections.
        XCTAssertTrue(project.tasks.isEmpty)
        XCTAssertTrue(project.activeTasks.isEmpty)
        XCTAssertTrue(project.counts.isEmpty)
        // No outstanding work: backlog does not count as active.
        XCTAssertFalse(project.hasOutstandingWork)
    }

    /// Adding a file under `.plans/backlog/` must change the project signature so
    /// a backlog/restore move triggers a reload.
    func testProjectSignatureChangesWhenBacklogFileAdded() throws {
        try writeTaskFile(
            filename: "001-a.md",
            text: "# A\n\n**Status:** pending",
            in: "pending"
        )
        let parser = TaskParser()
        let before = parser.projectSignature(at: tempDir.path)
        try writeTaskFile(
            filename: "082-backlogged.md",
            text: "# B\n\n**Status:** pending",
            in: "backlog"
        )
        XCTAssertNotEqual(before, parser.projectSignature(at: tempDir.path))
    }

    /// A project with NO `.plans/backlog/` directory yields an empty
    /// `backloggedTasks` (no-op, no crash).
    func testMissingBacklogDirYieldsEmptyBackloggedTasks() throws {
        try writeTaskFile(
            filename: "083-x.md",
            text: "# X\n\n**Status:** pending",
            in: "pending"
        )
        let project = TaskParser().parseProject(at: tempDir.path)
        XCTAssertTrue(project.backloggedTasks.isEmpty)
    }
}
