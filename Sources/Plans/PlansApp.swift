import SwiftUI

/// Sets the activation policy to `.regular` so the app can bring its window
/// to the front and receive focus. A `MenuBarExtra` app otherwise defaults
/// toward accessory behavior, where the opened window may not activate cleanly.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}

@main
struct PlansApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Surface A — menu bar "glance"
        MenuBarExtra("Plans", systemImage: "list.bullet") {
            MenuBarView()
        }

        // Surface B — cross-project browser window
        Window("Plans", id: "browser") {
            BrowserWindow()
        }
    }
}
