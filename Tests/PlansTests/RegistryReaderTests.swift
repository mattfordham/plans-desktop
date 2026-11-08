import XCTest
@testable import Plans

/// Tolerance & live-prune tests for `RegistryReader`, mirroring the behavior of
/// plans-cc `lib/registry.js`. Each test writes its fixtures into a unique temp
/// directory and points the reader at them via the injectable `registryURL`.
final class RegistryReaderTests: XCTestCase {
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

    /// Writes the given JSON string to a registry file in the temp dir and
    /// returns a reader pointed at it.
    private func makeReader(json: String) throws -> RegistryReader {
        let registryURL = tempDir.appendingPathComponent("projects.json")
        try json.write(to: registryURL, atomically: true, encoding: .utf8)
        return RegistryReader(registryURL: registryURL)
    }

    /// Creates a project directory (with an optional `.plans/` subdir) inside the
    /// temp dir and returns its filesystem path.
    @discardableResult
    private func makeProjectDir(
        name: String,
        withPlansDir: Bool
    ) throws -> String {
        let projectDir = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: projectDir,
            withIntermediateDirectories: true
        )
        if withPlansDir {
            try FileManager.default.createDirectory(
                at: projectDir.appendingPathComponent(".plans"),
                withIntermediateDirectories: true
            )
        }
        return projectDir.path
    }

    // MARK: - Valid registry

    func testValidRegistryKeepsLiveProjects() throws {
        let pathA = try makeProjectDir(name: "projectA", withPlansDir: true)
        let pathB = try makeProjectDir(name: "projectB", withPlansDir: true)
        let json = """
        {
          "version": 1,
          "projects": [
            { "path": "\(pathA)", "lastSeen": "2026-06-04T14:41:00Z" },
            { "path": "\(pathB)", "lastSeen": "2026-06-04T14:42:00Z" }
          ]
        }
        """
        let reader = try makeReader(json: json)

        let projects = reader.readProjects()
        // readProjects emits the realpath-canonical spelling (symlinks resolved,
        // case normalized); loadRegistry still returns the raw stored paths.
        XCTAssertEqual(projects.map(\.path), [canonical(pathA), canonical(pathB)])
        XCTAssertEqual(reader.loadRegistry().count, 2)
    }

    // MARK: - Tolerance (loadRegistry)

    func testMissingFileReturnsEmpty() {
        let missingURL = tempDir.appendingPathComponent("does-not-exist.json")
        let reader = RegistryReader(registryURL: missingURL)
        XCTAssertEqual(reader.loadRegistry().count, 0)
        XCTAssertEqual(reader.readProjects().count, 0)
    }

    func testEmptyFileReturnsEmpty() throws {
        let reader = try makeReader(json: "")
        XCTAssertEqual(reader.loadRegistry().count, 0)
        XCTAssertEqual(reader.readProjects().count, 0)
    }

    func testCorruptJSONReturnsEmpty() throws {
        let reader = try makeReader(json: "{ this is not valid json ]")
        XCTAssertEqual(reader.loadRegistry().count, 0)
        XCTAssertEqual(reader.readProjects().count, 0)
    }

    func testWrongShapeMissingProjectsReturnsEmpty() throws {
        let reader = try makeReader(json: #"{"version":1}"#)
        XCTAssertEqual(reader.loadRegistry().count, 0)
        XCTAssertEqual(reader.readProjects().count, 0)
    }

    func testWrongShapeProjectsNotArrayReturnsEmpty() throws {
        let reader = try makeReader(json: #"{"version":1,"projects":"nope"}"#)
        XCTAssertEqual(reader.loadRegistry().count, 0)
        XCTAssertEqual(reader.readProjects().count, 0)
    }

    func testUnknownVersionStillReadsProjects() throws {
        let path = try makeProjectDir(name: "future", withPlansDir: true)
        let json = """
        {
          "version": 99,
          "projects": [
            { "path": "\(path)", "lastSeen": "2026-06-04T14:41:00Z" }
          ]
        }
        """
        let reader = try makeReader(json: json)
        XCTAssertEqual(reader.loadRegistry().map(\.path), [path])
        XCTAssertEqual(reader.readProjects().map(\.path), [canonical(path)])
    }

    // MARK: - Live-prune (readProjects)

    func testStaleEntryWithoutPlansDirIsDropped() throws {
        let livePath = try makeProjectDir(name: "live", withPlansDir: true)
        let stalePath = try makeProjectDir(name: "stale", withPlansDir: false)
        let json = """
        {
          "version": 1,
          "projects": [
            { "path": "\(livePath)", "lastSeen": "2026-06-04T14:41:00Z" },
            { "path": "\(stalePath)", "lastSeen": "2026-06-04T14:42:00Z" }
          ]
        }
        """
        let reader = try makeReader(json: json)

        // loadRegistry keeps both (pre-prune); readProjects drops the stale one.
        XCTAssertEqual(reader.loadRegistry().count, 2)
        XCTAssertEqual(reader.readProjects().map(\.path), [canonical(livePath)])
    }

    func testDuplicatePathsDeduplicatedToSingleEntry() throws {
        let path = try makeProjectDir(name: "dup", withPlansDir: true)
        let json = """
        {
          "version": 1,
          "projects": [
            { "path": "\(path)", "lastSeen": "2026-06-04T14:41:00Z" },
            { "path": "\(path)", "lastSeen": "2026-06-04T14:42:00Z" }
          ]
        }
        """
        let reader = try makeReader(json: json)

        // Exact-duplicate path entries collapse to a single canonical entry
        // carrying the more-recent lastSeen.
        let projects = reader.readProjects()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.path, canonical(path))
        XCTAssertEqual(projects.first?.lastSeen, "2026-06-04T14:42:00Z")
    }

    /// `realpath(3)` for the test's expectations — resolves symlinks (e.g. the
    /// macOS `/var` -> `/private/var` link under the temp dir) and canonicalizes
    /// case to the real on-disk spelling, matching the reader's own helper.
    private func canonical(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func testCaseVariantPathsDeduplicatedToCanonicalSpelling() throws {
        // One on-disk dir, referenced by two registry entries whose paths
        // differ only by case. On a case-insensitive macOS volume both resolve
        // to the same dir, so the `.plans/`-exists prune keeps both — the
        // reader must collapse them to a single canonical entry.
        let realPath = try makeProjectDir(name: "CaseDup", withPlansDir: true)

        // Build a case-variant of the project dir's last component.
        let realURL = URL(fileURLWithPath: realPath)
        let variantPath = realURL
            .deletingLastPathComponent()
            .appendingPathComponent(realURL.lastPathComponent.uppercased())
            .path
        // Precondition: the variant must actually differ from the real spelling,
        // otherwise this test would silently not exercise case-variance.
        XCTAssertNotEqual(variantPath, realPath)

        let json = """
        {
          "version": 1,
          "projects": [
            { "path": "\(variantPath)", "lastSeen": "2026-06-04T14:41:00Z" },
            { "path": "\(realPath)", "lastSeen": "2026-06-04T14:42:00Z" }
          ]
        }
        """
        let reader = try makeReader(json: json)

        let projects = reader.readProjects()
        XCTAssertEqual(projects.count, 1)
        // Emits the realpath-canonical, real on-disk spelling (not the
        // case-variant, and with symlinks resolved).
        XCTAssertEqual(projects.first?.path, canonical(realPath))
        // Keeps the more-recent lastSeen.
        XCTAssertEqual(projects.first?.lastSeen, "2026-06-04T14:42:00Z")
    }
}
