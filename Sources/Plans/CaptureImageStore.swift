import Foundation
import OSLog

private let captureImageLog = Logger(subsystem: "com.plans.desktop", category: "CaptureImageStore")

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

    /// Flattens MULTIPLE staged image references into a plan `description` for
    /// submission (#069). Appends one markdown image paragraph per URL in order,
    /// reusing the single-URL overload's exact format string, so N saved
    /// attachments produce
    /// `<description>\n\n![pasted image](file://p1)\n\n![pasted image](file://p2)…`.
    /// An empty `imageURLs` list returns the description unchanged.
    ///
    /// Pure (no side effects): the actual file writes happen in `saveImage`. This
    /// is the function the submit path calls ONCE with every saved URL, replacing
    /// the previous per-image single-URL folding.
    static func flattenDescription(_ description: String, imageURLs: [URL]) -> String {
        imageURLs.reduce(description) { partial, url in
            flattenDescription(partial, imageURL: url)
        }
    }

    /// The end-to-end submit-path helper (#085): saves each staged image's PNG
    /// bytes under Application Support (via `saveImage`, NEVER `.plans/`, §2),
    /// collecting the saved URLs in staging order, then returns `description`
    /// with one markdown image reference appended per saved image (via the
    /// multi-URL `flattenDescription`).
    ///
    /// A per-image save failure is LOGGED AND SKIPPED — never thrown — so one bad
    /// blob can't crash or block the capture; the surviving images still get
    /// referenced. An empty `imageDatas` returns `description` unchanged (no
    /// disk writes, no reference appended).
    ///
    /// Shared by `NewPlanModal`, `ElaborateModal`, and `ReElaborateModal` so the
    /// three capture surfaces stage images identically. An INSTANCE method so
    /// tests can inject `applicationSupportDirectory` and assert the writes land
    /// in a temp dir rather than the real container.
    func saveAndFlatten(description: String, imageDatas: [Data]) -> String {
        var savedURLs: [URL] = []
        for imageData in imageDatas {
            do {
                savedURLs.append(try saveImage(imageData))
            } catch {
                captureImageLog.error("failed to save staged image, skipping it: \(error.localizedDescription, privacy: .public)")
            }
        }
        return Self.flattenDescription(description, imageURLs: savedURLs)
    }
}
