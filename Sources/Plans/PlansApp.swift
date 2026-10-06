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
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The shared, observable store, created once and injected into both scenes.
    let store = PlansStore()

    /// The shared task-run coordinator, created once and injected into the menu
    /// bar + browser scenes. It tracks one `TaskRun` per active task, so multiple
    /// tasks can run concurrently while card rows / the plan-detail overlay pane
    /// each observe the run for their own task. Created here on the main actor.
    let taskRunner = TaskRunner()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Reconcile finished capture spinners against the freshly-parsed
        // projects at the END of EVERY reload — both the run-finish hand-off and
        // every 5s poll tick (#051). Wiring it to the store's post-reload hook
        // (rather than only the run-finish path) closes a filesystem-flush race:
        // if plans-cc writes the captured plan file AFTER the run-finish reconcile
        // pass, the next poll both parses the new plan row AND dismisses the
        // now-orphaned spinner, instead of leaving the spinner pinned beside the
        // real row until the bounded fallback elapses. `store.projects` is fully
        // repopulated by the synchronous task-parse pass before this fires.
        store.onDidReload = { [weak store, weak taskRunner] in
            guard let store else { return }
            taskRunner?.reconcileFinishedCaptures(against: store.projects)
        }
        // Background plans sync never starts while a run is in flight in the
        // same project, so it cannot race the run's own plans commits.
        store.isProjectBusy = { [weak taskRunner] projectPath in
            taskRunner?.hasRunningRun(inProject: projectPath) ?? false
        }
        store.startPolling()
        // Whenever any run finishes, reload immediately so the worked task's new
        // status surfaces rather than waiting for the next 5s poll tick; the
        // reload's post-reload hook (above) then reconciles in the same
        // main-actor turn, so a "creating" spinner row hands off to the new plan
        // row in one atomic SwiftUI transition. Then sync that project's plans
        // (branch mode only) so the run's commits and any remote plans meet
        // without waiting out the sync interval.
        taskRunner.onAnyRunFinished = { [weak store] projectPath in
            store?.reload()
            store?.syncAfterRun(inProject: projectPath)
        }
    }

    /// Guards quit when task spinners are still running (#044). AppKit calls this
    /// synchronously and expects a synchronous `TerminateReply`, so we run a modal
    /// `NSAlert` inline rather than awaiting anything. With nothing running we
    /// terminate immediately; otherwise we confirm, and on confirmation stop every
    /// in-flight run before terminating so child `node` processes don't outlive
    /// the app. Cancel aborts the quit. `runningRunCount` is the single source of
    /// truth, shared with the live spinner UI.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let count = taskRunner.runningRunCount
        guard count > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Quit Plans?"
        let noun = count == 1 ? "task" : "tasks"
        alert.informativeText =
            "You have \(count) running \(noun). Quitting will stop \(count == 1 ? "it" : "them")."
        // First button is the default; mark it destructive so the system can style
        // it (and it sits as the rightmost/primary action).
        let quitButton = alert.addButton(withTitle: "Quit")
        quitButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Stop every still-running run; finished-but-not-dismissed runs are
            // left alone (their `stop()` is a no-op anyway).
            for (taskID, run) in taskRunner.runs where run.isRunning {
                taskRunner.stop(taskID: taskID)
            }
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

@main
struct PlansApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The shared store, owned by the delegate so its initial launch load
    /// (via `startPolling()`) runs before the menu panel is first opened.
    private var store: PlansStore { appDelegate.store }

    /// The shared "Work this task" runner, owned by the delegate so a single
    /// instance is shared across every surface that can observe a run.
    private var taskRunner: TaskRunner { appDelegate.taskRunner }

    var body: some Scene {
        // Surface A — menu bar "glance". The `content:label:` overload lets the
        // icon-space label (`MenuBarLabel`) render a live, colored count summary
        // that updates with the store's 5s poll, instead of a static icon.
        MenuBarExtra {
            MenuBarView()
                .environment(store)
        } label: {
            MenuBarLabel()
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
                .environment(taskRunner)
        }
        .defaultLaunchBehavior(.presented)
        // #034: map ⌘N app-wide to the "New Plan" form. `replacing: .newItem`
        // overrides AppKit's default ⌘N ("New Window") so the shortcut opens the
        // plan-capture modal instead. The button can't reach `BrowserWindow`'s
        // sheet `@State`, so it bumps the store's non-persisted `newPlanTrigger`,
        // which the window observes and turns into the same modal the toolbar
        // "New Plan" button opens. `.disabled` reflects state at menu-build time
        // (no live projects → nothing to capture against), which is sufficient.
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Plan") { store.requestNewPlan() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(store.projects.isEmpty)
            }
        }
        // #073: the standalone per-plan detail window (§011) was removed —
        // plan detail now renders as an in-window modal overlay pane in
        // `BrowserWindow` (see `detailOverlay`), so there is no separate
        // detail scene here anymore.
    }
}
