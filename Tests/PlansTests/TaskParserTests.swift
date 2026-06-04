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
        **Blocked by:** 001 002
        """
        let task = TaskParser().parse(filename: "007-x.md", text: text, isCompletedDir: false)
        XCTAssertEqual(task.created, "2026-06-04T14:41")
        XCTAssertEqual(task.type, .feature)
        XCTAssertEqual(task.status, .inProgress)
        XCTAssertEqual(task.branch, "feature/007-x")
        XCTAssertEqual(task.blockedBy, ["001", "002"])
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
        // Deliberately out of order on disk; ids chosen so id-ascending differs
        // from status priority where statuses tie.
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
        XCTAssertEqual(
            orderedIds,
            ["064", "063", "062", "061", "060", "065"]
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
        XCTAssertEqual(project.projectName, tempDir.lastPathComponent)
        XCTAssertEqual(project.projectPath, tempDir.path)
    }
}
