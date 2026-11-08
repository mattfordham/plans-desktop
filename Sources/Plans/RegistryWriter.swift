import Foundation

/// Writes the plans-cc project registry at `~/.claude/plans-cc/projects.json`,
/// the write-side counterpart to `RegistryReader`. Reuses the shared `Registry`
/// / `RegistryProject` Codable types defined in `RegistryReader.swift`.
///
/// The registry file path and the `FileManager` are injectable so tests can
/// point the writer at fixtures rather than the real home directory, mirroring
/// `RegistryReader`'s shape. Reads are tolerant (missing/corrupt registry →
/// fresh `version: 1` registry); writes are atomic (a temp file is written and
/// then moved into place) so a concurrent reader never observes a partial file.
struct RegistryWriter {
    let registryURL: URL
    let fileManager: FileManager

    /// Defaults to the real registry location under the current user's home
    /// directory. Inject a custom `registryURL`/`fileManager` in tests.
    init(
        registryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.registryURL = registryURL ?? fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("plans-cc")
            .appendingPathComponent("projects.json")
    }

    /// An ISO-8601 UTC formatter with millisecond precision, e.g.
    /// `2026-06-05T17:18:30.904Z`, matching the `lastSeen` shape plans-cc emits.
    /// Created fresh per call rather than shared: `ISO8601DateFormatter` is not
    /// `Sendable`, and registry writes are infrequent enough that the allocation
    /// cost is irrelevant.
    private static func makeLastSeenFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }

    /// Upserts `path` into the registry: if an entry resolving to the same
    /// canonical (realpath) path already exists, its `lastSeen` is refreshed in
    /// place (preserving order and the existing entry's stored spelling);
    /// otherwise a new entry is appended. Matching is by canonical path so a
    /// case-variant of an already-registered directory refreshes the existing
    /// entry rather than appending a duplicate — mirroring `RegistryReader`'s
    /// canonical dedupe. The full registry is then written back atomically.
    func upsertProject(path: String, now: Date = Date()) throws {
        let lastSeen = Self.makeLastSeenFormatter().string(from: now)
        var projects = loadProjects()

        let canonical = Self.realpath(path)
        if let index = projects.firstIndex(
            where: { Self.realpath($0.path) == canonical }
        ) {
            // Refresh in place: keep the existing stored path spelling, update
            // only lastSeen.
            projects[index] = RegistryProject(
                path: projects[index].path,
                lastSeen: lastSeen
            )
        } else {
            projects.append(RegistryProject(path: path, lastSeen: lastSeen))
        }

        try write(Registry(version: 1, projects: projects))
    }

    /// `realpath(3)`, degrading to a standardized absolute path when the path
    /// cannot be resolved. Mirrors `RegistryReader.realpath`: `Darwin.realpath`
    /// resolves symlinks and canonicalizes case to the real on-disk spelling;
    /// for paths that do not exist on disk the fallback standardizes the string
    /// so identical strings canonicalize identically.
    private static func realpath(_ path: String) -> String {
        if let resolved = Darwin.realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Loads the existing registry's projects. Tolerant: a missing file, empty
    /// file, invalid JSON, or wrong shape all yield an empty array (a fresh
    /// `version: 1` registry is then synthesized on write).
    private func loadProjects() -> [RegistryProject] {
        guard
            let data = try? Data(contentsOf: registryURL),
            let registry = try? JSONDecoder().decode(Registry.self, from: data)
        else {
            return []
        }
        return registry.projects
    }

    /// Encodes `registry` (pretty-printed, sorted keys for stable output) and
    /// writes it to `registryURL` atomically: the encoded bytes go to a sibling
    /// temp file which is then moved into place, replacing any existing file, so
    /// a reader never sees a half-written registry. Intermediate directories are
    /// created as needed.
    private func write(_ registry: Registry) throws {
        let directory = registryURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)

        // `Data.write(options: .atomic)` writes to a temp file and renames it
        // into place, giving an all-or-nothing replacement.
        try data.write(to: registryURL, options: .atomic)
    }
}
