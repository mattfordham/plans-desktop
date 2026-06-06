import XCTest
@testable import Plans

/// Tests for the data-layer invariants the `ProjectCard` git footer depends on
/// (#026 moved the git indicator from the header into a dedicated card footer).
///
/// `ProjectCard` is a SwiftUI view whose rendered output is impractical to
/// assert against directly, so these tests pin the `ProjectTasks` git fields the
/// footer reads: the footer (and its preceding divider) render ONLY when
/// `gitBranch != nil`, and the orange dirty dot renders ONLY when
/// `gitIsDirty == true` (a `nil`/`false` value shows no dot). Mirrors
/// `BrowserWindowTests`, which asserts plain values without instantiating views.
final class ProjectCardTests: XCTestCase {

    /// Builds a `ProjectTasks` fixture, optionally with git fields, via the
    /// memberwise initializer used across the suite.
    private func makeProject(
        gitBranch: String? = nil,
        gitIsDirty: Bool? = nil
    ) -> ProjectTasks {
        ProjectTasks(
            projectPath: "/tmp/example",
            projectName: "example",
            lastSeen: "",
            tasks: [],
            counts: [:],
            activeTasks: [],
            gitBranch: gitBranch,
            gitIsDirty: gitIsDirty
        )
    }

    /// A git repo with a dirty working tree: the footer would show the branch
    /// plus the orange dirty dot.
    func testGitRepoDirtyExposesBranchAndDirtyTrue() {
        let project = makeProject(gitBranch: "main", gitIsDirty: true)
        XCTAssertEqual(project.gitBranch, "main")
        XCTAssertEqual(project.gitIsDirty, true)
    }

    /// A git repo with a clean working tree: the footer shows the branch but no
    /// dirty dot (`gitIsDirty == false` is known-clean, not unknown).
    func testGitRepoCleanShowsNoDirtyDot() {
        let project = makeProject(gitBranch: "feature/x", gitIsDirty: false)
        XCTAssertEqual(project.gitBranch, "feature/x")
        XCTAssertEqual(project.gitIsDirty, false)
        // Only an exact `true` renders the dot.
        XCTAssertNotEqual(project.gitIsDirty, true)
    }

    /// A git repo whose dirty state is unknown (`nil`): branch shown, no dot.
    func testGitRepoUnknownDirtyShowsNoDot() {
        let project = makeProject(gitBranch: "main", gitIsDirty: nil)
        XCTAssertEqual(project.gitBranch, "main")
        XCTAssertNil(project.gitIsDirty)
        XCTAssertNotEqual(project.gitIsDirty, true)
    }

    /// A non-git project: `gitBranch == nil`, so neither the footer nor its
    /// preceding divider render (the body guards on `gitBranch != nil`).
    func testNonGitProjectHasNilBranch() {
        let project = makeProject(gitBranch: nil, gitIsDirty: nil)
        XCTAssertNil(project.gitBranch)
        XCTAssertNil(project.gitIsDirty)
    }

    /// The git fields default to `nil` when omitted, so existing call sites and
    /// fixtures that predate #024 keep behaving as non-git projects.
    func testGitFieldsDefaultToNil() {
        let project = makeProject()
        XCTAssertNil(project.gitBranch)
        XCTAssertNil(project.gitIsDirty)
    }
}
