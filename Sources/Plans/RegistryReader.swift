import Foundation

/// A single project entry in the plans-cc registry. `lastSeen` is kept as a
/// raw `String` for now; parsing it into a `Date` for staleness sorting is
/// deferred to task #006.
struct RegistryProject: Codable {
    let path: String
    let lastSeen: String
}

/// The decoded shape of `projects.json`. `version` is decoded for fidelity but
/// behavior is never gated on it — mirroring plans-cc `lib/registry.js`, which
/// reads `projects` regardless of version. `projects` is required, so a JSON
/// object lacking a `projects` array fails to decode and is treated as empty.
struct Registry: Codable {
    let version: Int
    let projects: [RegistryProject]
}

/// Reads the plans-cc project registry from `~/.claude/plans-cc/projects.json`.
///
/// The registry file path and the `FileManager` are injectable so tests can
/// point the reader at fixtures rather than the real home directory. This
/// mirrors the tolerance of plans-cc `lib/registry.js`: any failure (missing
/// file, empty file, invalid JSON, or wrong shape) yields an empty list rather
/// than throwing.
struct RegistryReader {
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

    /// Loads the registry, returning its projects. Never throws: any I/O or
    /// decode failure — including a missing/empty file, invalid JSON, or a JSON
    /// object lacking a `projects` array — results in an empty array.
    func loadRegistry() -> [RegistryProject] {
        do {
            let data = try Data(contentsOf: registryURL)
            let registry = try JSONDecoder().decode(Registry.self, from: data)
            return registry.projects
        } catch {
            return []
        }
    }

    /// Returns the live projects: `loadRegistry()` filtered to entries whose
    /// `<path>/.plans` directory exists on disk, then deduplicated by canonical
    /// (realpath) path. Mirrors `readProjects` in plans-cc `lib/registry.js`
    /// (filter by `hasPlansDir`): a missing or non-existent `.plans` directory
    /// drops the entry.
    ///
    /// On case-insensitive macOS volumes the registry can hold the same folder
    /// twice with paths differing only by case; `fileExists` is case-insensitive
    /// there, so both would survive the prune and the project would appear
    /// twice. To prevent that, surviving entries are collapsed by canonical
    /// path: one entry per `realpath`, keeping the most-recent `lastSeen` and
    /// emitting the real on-disk spelling, while preserving the first-seen order
    /// of canonical paths.
    func readProjects() -> [RegistryProject] {
        let live = loadRegistry().filter { project in
            let plansPath = URL(fileURLWithPath: project.path)
                .appendingPathComponent(".plans")
                .path
            return fileManager.fileExists(atPath: plansPath)
        }

        var order: [String] = []
        var byCanonical: [String: RegistryProject] = [:]
        for project in live {
            let canonical = Self.realpath(project.path)
            // Emit the real on-disk spelling, not the stored (case-variant) one.
            let normalized = RegistryProject(
                path: canonical,
                lastSeen: project.lastSeen
            )
            if let existing = byCanonical[canonical] {
                // Prefer the more-recent lastSeen. ISO-8601 UTC strings of equal
                // length sort lexically in timestamp order, so string compare
                // avoids a dependency on date parsing here.
                if normalized.lastSeen > existing.lastSeen {
                    byCanonical[canonical] = normalized
                }
            } else {
                byCanonical[canonical] = normalized
                order.append(canonical)
            }
        }
        return order.compactMap { byCanonical[$0] }
    }

    /// `realpath(3)`, degrading to a standardized absolute path when the path
    /// cannot be resolved. `Darwin.realpath` resolves symlinks and canonicalizes
    /// case to the real on-disk spelling — the Swift equivalent of plans-cc's
    /// `fs.realpathSync.native`.
    private static func realpath(_ path: String) -> String {
        if let resolved = Darwin.realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
