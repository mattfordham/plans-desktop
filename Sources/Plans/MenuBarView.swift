import SwiftUI

/// Surface A content: the menu bar item's drop-down panel (the §4 "glance").
///
/// Renders one row per live project showing its name and a per-status icon +
/// count for each non-zero, non-completed status, iterating `TaskStatus.glanceOrder`
/// (the plans-cc TUI dashboard's `STAT_CARDS` order, which omits `completed`).
/// Empty states cover both a project with no outstanding tasks and the
/// no-projects case (§4.4 / §8.1).
///
/// Each project row is tappable: tapping sets the drill-down selection on the
/// store and opens the Surface B browser window, focusing the app. The
/// `MenuBarExtra` scene uses `.menuBarExtraStyle(.window)` (set in `PlansApp`)
/// so these custom rows render as a real tappable panel.
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(PlansStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.projects.isEmpty {
                Text("No projects")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                ForEach(store.projects, id: \.projectPath) { project in
                    Button {
                        drillInto(project)
                    } label: {
                        ProjectGlanceRow(project: project)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Button("Link Project…") {
                linkProjectWithUserPrompt(using: store)
            }
            .buttonStyle(.plain)

            Button("Open Browser") {
                // No pre-focus: explicitly clear any prior drill-down so the
                // browser opens in its default (cross-project) state.
                store.selectedProjectPath = nil
                openWindow(id: "browser")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)

            Button("Quit") {
                // Route through `NSApp.terminate`, so the delegate's
                // `applicationShouldTerminate(_:)` quit-confirmation hook (#044)
                // runs before the app exits. `NSApp` is the same shared
                // application instance as `NSApplication.shared`.
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(width: 280)
    }

    /// Sets the drill-down selection and opens/focuses the browser window,
    /// mirroring the "Open Browser" button's window-opening behavior.
    private func drillInto(_ project: ProjectTasks) {
        store.selectedProjectPath = project.projectPath
        openWindow(id: "browser")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// A single project's glance row: the project name plus a per-status icon +
/// count for every status that has a non-zero count, in `TaskStatus.glanceOrder`
/// (the TUI dashboard order). `completed` is excluded from that order, so
/// finished tasks never appear. Zero-count statuses (absent from `counts` or
/// `0`) are also omitted. A project with no outstanding tasks shows a muted
/// "no tasks" affordance.
private struct ProjectGlanceRow: View {
    let project: ProjectTasks

    /// The statuses to show, in `TaskStatus.glanceOrder` (TUI `STAT_CARDS`
    /// order, `completed` excluded), paired with their non-zero counts.
    /// Statuses absent from `counts` or with a `0` count are dropped.
    private var statusCounts: [(status: TaskStatus, count: Int)] {
        TaskStatus.glanceOrder.compactMap { status in
            guard let count = project.counts[status], count > 0 else { return nil }
            return (status, count)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(project.projectName)

            Spacer(minLength: 8)

            if statusCounts.isEmpty {
                Text("no tasks")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(statusCounts, id: \.status) { entry in
                    HStack(spacing: 2) {
                        Image(systemName: entry.status.symbolName)
                            .imageScale(.small)
                            .foregroundStyle(entry.status.glanceColor)
                            .frame(width: 14, alignment: .center)
                        Text("\(entry.count)")
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
