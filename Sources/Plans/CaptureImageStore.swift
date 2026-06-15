import Foundation

/// Persists pasted/dropped images for the "New Plan" capture form (#048) into an
/// **app-owned** location and flattens an image reference into a plan
/// description.
///
/// **HARD CONSTRAINT (§2).** This app NEVER writes to any `.plans/` directory.
/// Captured image bytes are written ONLY under the app's Application Support
/// container — `~/Library/Application Support/Plans/attachments/<uuid>.png` —
/// which is outside every project's `.plans/` tree. The spawned capture process
/// remains the sole `.plans/` writer; this store only stages an image the user
/// can reference from the description.
///
/// The Application Support base directory and the `FileManager` are injectable
/// (constructor params defaulting to the real values) so tests can point the
/// store at a temp directory rather than the real container — mirroring
/// `RegistryWriter`'s shape. Writes are atomic (`Data.write(options: .atomic)`
/// writes a temp file then renames it into place), and intermediate directories
/// are created as needed.
struct CaptureImageStore {
    let fileManager: FileManager
    /// The Application Support base directory under which `Plans/attachments/`
    /// is created. Defaults to the real per-user Application Support directory;
    /// inject a temp dir in tests.
    let applicationSupportDirectory: URL

    /// Defaults to the real per-user Application Support directory. Inject a
    /// custom `applicationSupportDirectory`/`fileManager` in tests.
    ///
    /// Resolving the real base eagerly creates the Application Support directory
    /// (`create: true`) — the same directory the system expects app data to live
    /// in. If resolution fails (it effectively never does on macOS), it falls
    /// back to a `Library/Application Support` path under the user's home.
    init(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let base = applicationSupportDirectory {
            self.applicationSupportDirectory = base
        } else {
            self.applicationSupportDirectory =
                (try? fileManager.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )) ?? fileManager
                    .homeDirectoryForCurrentUser
                    .appendingPathComponent("Library")
                    .appendingPathComponent("Application Support")
        }
    }

    /// The app-owned attachments directory: `<applicationSupport>/Plans/attachments`.
    /// This is OUTSIDE any `.plans/` directory (§2) — image bytes never touch a
    /// project's task tree.
    var attachmentsDirectory: URL {
        applicationSupportDirectory
            .appendingPathComponent("Plans")
            .appendingPathComponent("attachments")
    }

    /// Writes `pngData` to `attachmentsDirectory/<uuid>.png` and returns the
    /// absolute file URL of the written image. The attachments directory (and any
    /// missing intermediates) is created first; the write is atomic (a temp file
    /// is written then renamed into place) so a reader never observes a partial
    /// image. Throws on any directory-creation or write failure.
    ///
    /// §2: the destination is always under Application Support, NEVER `.plans/`.
    func saveImage(_ pngData: Data) throws -> URL {
        let directory = attachmentsDirectory
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        // `Data.write(options: .atomic)` writes to a temp file and renames it
        // into place, giving an all-or-nothing replacement.
        try pngData.write(to: url, options: .atomic)
        return url
    }

    /// Flattens a staged image reference into a plan `description` for submission
    /// (#048). Given a trimmed `description` and the absolute `imageURL` of a
    /// saved attachment, returns the description with a markdown image reference
    /// appended on its own paragraph:
    /// `<description>\n\n![pasted image](file://<abs-path>)`. Given a `nil`
    /// `imageURL`, returns the description unchanged.
    ///
    /// Pure (no side effects): the actual file write happens in `saveImage`. This
    /// is the function the submit path uses to embed the reference, and is the
    /// unit under test in the dedicated test step.
    static func flattenDescription(_ description: String, imageURL: URL?) -> String {
        guard let imageURL else { return description }
        return "\(description)\n\n![pasted image](file://\(imageURL.path))"
    }
}
