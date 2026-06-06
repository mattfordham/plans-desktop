import XCTest
@testable import Plans

/// Tests for `RegistryWriter.upsertProject(path:)`, covering create-new,
/// upsert-updates-lastSeen, no-duplicate-on-existing-path, and atomic-write
/// (the resulting file is always valid, decodable JSON). Each test writes its
/// fixtures into a unique temp directory and points the writer/reader at them
/// via the injectable `registryURL`, mirroring `RegistryReaderTests`.
final class RegistryWriterTests: XCTestCase {
    private var tempDir: URL!
    private var registryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        registryURL = tempDir.appendingPathComponent("projects.json")
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        registryURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeWriter() -> RegistryWriter {
        RegistryWriter(registryURL: registryURL)
    }

    /// Decodes the on-disk registry, failing the test if it is missing or not
    /// valid JSON matching the `Registry` shape.
    private func readBack() throws -> Registry {
        let data = try Data(contentsOf: registryURL)
        return try JSONDecoder().decode(Registry.self, from: data)
    }

    private func writeRegistry(_ json: String) throws {
        try json.write(to: registryURL, atomically: true, encoding: .utf8)
    }

    // MARK: - create-new-registry

    func testUpsertCreatesRegistryWhenNoneExists() throws {
        let writer = makeWriter()
        try writer.upsertProject(path: "/Users/test/alpha")

        let registry = try readBack()
        XCTAssertEqual(registry.version, 1)
        XCTAssertEqual(registry.projects.map(\.path), ["/Users/test/alpha"])
        XCTAssertFalse(registry.projects[0].lastSeen.isEmpty)
    }

    func testUpsertWritesIso8601MillisecondsUtcLastSeen() throws {
        let writer = makeWriter()
        try writer.upsertProject(path: "/Users/test/alpha")

        let registry = try readBack()
        let lastSeen = registry.projects[0].lastSeen
        // e.g. 2026-06-05T17:18:30.904Z — millisecond fraction and trailing Z.
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#
        XCTAssertNotNil(
            lastSeen.range(of: pattern, options: .regularExpression),
            "lastSeen \(lastSeen) is not ISO-8601 UTC with milliseconds"
        )
    }

    // MARK: - upsert-updates-lastSeen

    func testUpsertUpdatesLastSeenForExistingPath() throws {
        try writeRegistry("""
        {
          "version": 1,
          "projects": [
            { "path": "/Users/test/alpha", "lastSeen": "2020-01-01T00:00:00.000Z" }
          ]
        }
        """)

        let writer = makeWriter()
        try writer.upsertProject(path: "/Users/test/alpha")

        let registry = try readBack()
        XCTAssertEqual(registry.projects.count, 1)
        XCTAssertNotEqual(
            registry.projects[0].lastSeen,
            "2020-01-01T00:00:00.000Z"
        )
    }

    // MARK: - no-duplicate-on-existing-path

    func testUpsertDoesNotDuplicateExistingPath() throws {
        let writer = makeWriter()
        try writer.upsertProject(path: "/Users/test/alpha")
        try writer.upsertProject(path: "/Users/test/alpha")

        let registry = try readBack()
        XCTAssertEqual(registry.projects.map(\.path), ["/Users/test/alpha"])
    }

    func testUpsertAppendsNewPathPreservingExisting() throws {
        let writer = makeWriter()
        try writer.upsertProject(path: "/Users/test/alpha")
        try writer.upsertProject(path: "/Users/test/beta")

        let registry = try readBack()
        XCTAssertEqual(
            registry.projects.map(\.path),
            ["/Users/test/alpha", "/Users/test/beta"]
        )
    }

    // MARK: - tolerance

    func testUpsertOnCorruptRegistryStartsFresh() throws {
        try writeRegistry("this is not json {{{")

        let writer = makeWriter()
        try writer.upsertProject(path: "/Users/test/alpha")

        let registry = try readBack()
        XCTAssertEqual(registry.version, 1)
        XCTAssertEqual(registry.projects.map(\.path), ["/Users/test/alpha"])
    }

    // MARK: - atomic-write produces valid JSON

    func testUpsertResultIsValidDecodableJson() throws {
        let writer = makeWriter()
        try writer.upsertProject(path: "/Users/test/alpha")
        try writer.upsertProject(path: "/Users/test/beta")

        // readBack() throws if the on-disk content is not valid Registry JSON.
        let registry = try readBack()
        XCTAssertEqual(registry.projects.count, 2)
    }
}
