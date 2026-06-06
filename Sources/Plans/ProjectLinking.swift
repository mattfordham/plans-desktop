import SwiftUI

/// Shared project-linking UI flow (§018), reused by both Surface A (the menu bar
/// panel, `MenuBarView`) and Surface B (the browser window, `BrowserWindow`).
///
/// This is the SINGLE implementation of "present a directory picker, then link
/// the chosen folder via the store, surfacing any rejection as a modal alert".
/// Keeping it as file-scope `@MainActor` helpers (rather than a `View`-method)
/// lets every surface call the identical flow without duplicating the
/// NSOpenPanel + NSAlert plumbing or re-deriving error messages.

/// Presents a directory-only open panel and, on confirmation, links the chosen
/// project via the store. A validation failure (no `.plans/` in the selection)
/// is surfaced as a modal alert with an actionable message; any other thrown
/// error is surfaced with its localized description.
///
/// Call this from any surface (menu bar, browser window) — it owns the whole
/// pick → link → report flow so callers need only forward the store.
@MainActor
func linkProjectWithUserPrompt(using store: PlansStore) {
    guard let url = presentProjectDirectoryPanel() else { return }
    do {
        try store.linkProject(at: url.path)
    } catch PlansStore.LinkError.missingPlansDirectory {
        presentLinkError(
            "That folder isn’t a plans-cc project.",
            informativeText:
                "No “.plans” directory found at \(url.path). "
                + "Pick a project folder that contains a “.plans” directory."
        )
    } catch {
        presentLinkError(
            "Couldn’t link that project.",
            informativeText: error.localizedDescription
        )
    }
}

/// Presents a modal open panel configured for selecting a single project
/// directory, returning the chosen URL or `nil` if the user cancelled.
@MainActor
func presentProjectDirectoryPanel() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Link"
    panel.message = "Choose a plans-cc project folder to link."
    // Bring the panel to the front: the menu bar panel isn't a key window, so
    // without this the open panel can appear behind other apps.
    NSApp.activate(ignoringOtherApps: true)
    return panel.runModal() == .OK ? panel.url : nil
}

/// Shows a modal alert describing why a link attempt failed.
@MainActor
func presentLinkError(_ messageText: String, informativeText: String) {
    let alert = NSAlert()
    alert.messageText = messageText
    alert.informativeText = informativeText
    alert.alertStyle = .warning
    alert.runModal()
}
