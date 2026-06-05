import SwiftUI

/// Sets the activation policy to `.regular` so the app can bring its window
/// to the front and receive focus. A `MenuBarExtra` app otherwise defaults
/// toward accessory behavior, where the opened window may not activate cleanly.
///
/// Also owns the shared store and starts its live refresh at launch.
/// With the `.menuBarExtraStyle(.window)` panel, `.onAppear` on the menu
/// content does not fire until the panel is first opened, so kicking off the
/// store here (in `applicationDidFinishLaunching`) guarantees the glance is
/// populated before the user first clicks the menu bar item. `startPolling()`
/// performs that initial synchronous load and then keeps both surfaces fresh
/// via a repeating timer (task #006).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The shared, observable store, created once and injected into both scenes.
    let store = PlansStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        store.startPolling()
    }
}

@main
struct PlansApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The shared store, owned by the delegate so its initial launch load
    /// (via `startPolling()`) runs before the menu panel is first opened.
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

        // Surface B — cross-project browser window. `.defaultLaunchBehavior(.presented)`
        // shows it automatically at launch so the browser is visible immediately
        // rather than only after a menu-bar drill-down; the delegate's
        // `startPolling()` has already performed the initial load, so it paints
        // with live data (and keeps refreshing). With no pre-selection it opens
        // in the default cross-project state.
        Window("Plans", id: "browser") {
            BrowserWindow()
                .environment(store)
        }
        .defaultLaunchBehavior(.presented)

        // Surface B detail — a standalone, value-based window per plan (§011).
        // Tapping a plan row in the browser opens this via `openWindow(id:value:)`,
        // keyed on the row's composite `TaskRow.ID`. `PlanDetailView` resolves the
        // id back to a row against the shared store and renders its body; passing a
        // value lets SwiftUI dedupe/reuse a window per plan id.
        WindowGroup("Plan", id: "plan-detail", for: TaskRow.ID.self) { $rowID in
            PlanDetailView(rowID: rowID)
                .environment(store)
        }
        // A roomy default so the detail body (header + markdown sections +
        // read-only How checklist) is comfortably visible without resizing on
        // first open — wide enough that markdown lines don't wrap prematurely.
        .defaultSize(width: 900, height: 600)
    }
}
