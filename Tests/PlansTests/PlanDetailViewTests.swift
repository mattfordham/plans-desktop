import XCTest
@testable import Plans

/// Tests for `PlanDetailView.taskFileURL(projectPath:taskID:isCompletedDir:)`,
/// the pure helper that reconstructs a task's on-disk markdown file by scanning
/// `<projectPath>/.plans/<pending|completed>/` for the first `.md` whose name
/// begins with `<taskID>-`. Fixtures are written into a unique per-test temp
/// directory (the same temp-dir pattern as `TaskParserTests`).
final class PlanDetailViewTests: XCTestCase {
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

    /// Writes a task file `filename` into `<tempDir>/.plans/<subdir>/`.
    private func writeTaskFile(filename: String, in subdir: String) throws {
        let dir = tempDir
            .appendingPathComponent(".plans")
            .appendingPathComponent(subdir)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        try "# placeholder\n".write(
            to: dir.appendingPathComponent(filename),
            atomically: true,
            encoding: .utf8
        )
    }

    func testResolvesPendingFileByIDPrefix() throws {
        try writeTaskFile(filename: "030-foo.md", in: "pending")

        let url = PlanDetailView.taskFileURL(
            projectPath: tempDir.path,
            taskID: "030",
            isCompletedDir: false
        )

        XCTAssertEqual(url?.lastPathComponent, "030-foo.md")
    }

    func testResolvesCompletedFileByIDPrefix() throws {
        try writeTaskFile(filename: "012-bar.md", in: "completed")

        let url = PlanDetailView.taskFileURL(
            projectPath: tempDir.path,
            taskID: "012",
            isCompletedDir: true
        )

        XCTAssertEqual(url?.lastPathComponent, "012-bar.md")
    }

    func testReturnsNilWhenNoMatchingFileExists() throws {
        // Directory exists but is empty.
        try FileManager.default.createDirectory(
            at: tempDir
                .appendingPathComponent(".plans")
                .appendingPathComponent("pending"),
            withIntermediateDirectories: true
        )

        let url = PlanDetailView.taskFileURL(
            projectPath: tempDir.path,
            taskID: "030",
            isCompletedDir: false
        )

        XCTAssertNil(url)
    }

    func testReturnsNilWhenIDPrefixDiffers() throws {
        try writeTaskFile(filename: "099-other.md", in: "pending")

        let url = PlanDetailView.taskFileURL(
            projectPath: tempDir.path,
            taskID: "030",
            isCompletedDir: false
        )

        XCTAssertNil(url)
    }

    // MARK: - RunProgressSheet.scrollTarget

    func testScrollTargetReturnsLastLineIDForNonEmptyList() {
        let lines = [
            LoggedEvent(event: .text(chunk: "a")),
            LoggedEvent(event: .text(chunk: "b")),
            LoggedEvent(event: .activity(tool: "Read", detail: nil)),
        ]

        XCTAssertEqual(
            RunProgressSheet.scrollTarget(for: lines),
            lines.last?.id
        )
    }

    func testScrollTargetReturnsNilForEmptyList() {
        XCTAssertNil(RunProgressSheet.scrollTarget(for: []))
    }

    // MARK: - PlanDetailView.canDelete gating (#060)

    /// `PlanDetailView.canDelete` is the pure predicate behind the Delete
    /// action's availability, and unlike its siblings (`canWork` gated to
    /// `.elaborated`, `canElaborate` gated to `.pending`) it is deliberately
    /// unconditional: an abandoned plan can sit at ANY lifecycle status, and a
    /// blocked plan is *more* deletable, not less. The real safety gate is the
    /// destructive `NSAlert` confirmation, not availability.
    ///
    /// This sweeps every `TaskStatus` case (via `CaseIterable`, so a new status
    /// is covered automatically) plus the unknown-status `nil`, crossed with
    /// both `isBlocked` values, so the "always available" contract is pinned
    /// down and any future accidental gating fails here.
    @MainActor
    func testCanDeleteIsAvailableForEveryStatusAndBlockedState() {
        let statuses: [TaskStatus?] = TaskStatus.allCases.map { $0 } + [nil]

        for status in statuses {
            for isBlocked in [false, true] {
                XCTAssertTrue(
                    PlanDetailView.canDelete(status: status, isBlocked: isBlocked),
                    "Delete must stay available for status "
                        + "\(status?.rawValue ?? "nil") / isBlocked=\(isBlocked)"
                )
            }
        }
    }
}
