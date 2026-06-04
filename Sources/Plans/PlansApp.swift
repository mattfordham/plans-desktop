import SwiftUI

/// Sets the activation policy to `.regular` so the app can bring its window
/// to the front and receive focus. A `MenuBarExtra` app otherwise defaults
/// toward accessory behavior, where the opened window may not activate cleanly.
///
/// Also owns the shared store and drives its one-shot `reload()` at launch.
/// With the `.menuBarExtraStyle(.window)` panel, `.onAppear` on the menu
/// content does not fire until the panel is first opened, so loading here (in
/// `applicationDidFinishLaunching`) guarantees the glance is populated before
/// the user first clicks the menu bar item. Continuous live refresh is task
/// #006.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The shared, observable store, created once and injected into both scenes.
    let store = PlansStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        store.reload()
    }
}

@main
struct PlansApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The shared store, owned by the delegate so its one-shot launch
    /// `reload()` runs before the menu panel is first opened.
    private var store: PlansStore { appDelegate.store }

    var body: some Scene {
        // Surface A — menu bar "glance"
        MenuBarExtra("Plans", systemImage: "list.bullet") {
            MenuBarView()
                .environment(store)
        }
        // A free-floating panel so the custom dotted, tappable rows render and
        // handle taps reliably (the default `.menu` style does not).
        .menuBarExtraStyle(.window)

        // Surface B — cross-project browser window
        Window("Plans", id: "browser") {
            BrowserWindow()
                .environment(store)
        }
    }
}
