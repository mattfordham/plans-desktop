import SwiftUI

/// The in-flight capture spinner rows for one project, shared (#103) by the
/// `ProjectCard` ("All projects" stack) and the single-project `TaskListView`
/// so a plan being captured surfaces identically on both surfaces.
///
/// It reads the live in-flight-capture registry (`TaskRunner.runningCaptures`)
/// directly — a capture has no parsed `.plans/` file yet, so it exists only as
/// a synthetic `capture:<path>:<uuid>` run and never enters the parsed-task row
/// pipeline. Each row is a small spinner (or a warning glyph once a capture has
/// finished IN ERROR) plus the run's free-text `description`, tappable to toggle
/// that run's `RunProgressSheet` progress popover anchored to the row bounds. On
/// the popover's close the finished run is dropped (`runner.dismiss`) and the
/// store reloaded so the new task surfaces via the normal read path.
///
/// Renders as nothing when no captures are running for the project, so an idle
/// surface shows no empty gap. The caller applies its own card gutter inset.
struct CaptureProgressRows: View {
    /// The project whose in-flight captures to render, by path. The sole key
    /// into `runner.runningCaptures(projectPath:)`.
    let projectPath: String

    /// The shared "Work this task" runner — the live in-flight-capture registry.
    /// Read-only here; the run process is the sole writer of `.plans/` (§2).
    @Environment(TaskRunner.self) private var runner

    /// The shared task store, reloaded after a run's progress popover closes so
    /// the task's new status surfaces via the existing read path. Read-only (§2).
    @Environment(PlansStore.self) private var store

    /// Which run's progress popover is currently open, by task id, or `nil` when
    /// none is. At most one is open at a time; the per-run `Binding<Bool>` from
    /// `progressPopover(for:)` drives each row's `.popover`.
    @State private var progressPopoverTaskID: String? = nil

    /// A per-run `Binding<Bool>` for the run-progress popover: `true` only when
    /// `progressPopoverTaskID` is this `taskID`, and on set assigns the id when
    /// raised / clears it when lowered — so opening one row's popover (or its
    /// self-dismiss) drives the single shared state.
    private func progressPopover(for taskID: String) -> Binding<Bool> {
        Binding(
            get: { progressPopoverTaskID == taskID },
            set: { progressPopoverTaskID = $0 ? taskID : nil }
        )
    }

    var body: some View {
        let captures = runner.runningCaptures(projectPath: projectPath)
        if !captures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(captures, id: \.taskID) { run in
                    captureRow(run)
                }
            }
        }
    }

    /// A single capture row: a small spinner plus the run's description,
    /// tappable (same `contentShape` + `onTapGesture` primitive as the per-row
    /// spinner) to toggle that run's progress popover, anchored to the row bounds.
    /// On the popover's close the finished run is dropped and the store reloaded
    /// so the new task surfaces via the read path.
    ///
    /// A capture that finished IN ERROR swaps the spinner for a warning glyph —
    /// reconciliation pins errored runs (they are never auto-dismissed), so this
    /// row is how the failure is raised; closing its popover is what clears it.
    @ViewBuilder
    private func captureRow(_ run: TaskRun) -> some View {
        let failed = !run.isRunning && run.error != nil
        HStack(spacing: 8) {
            if failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .imageScale(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(run.description ?? "Capturing…")
                .font(.body)
                .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            progressPopoverTaskID = (progressPopoverTaskID == run.taskID) ? nil : run.taskID
        }
        .popover(isPresented: progressPopover(for: run.taskID),
                 attachmentAnchor: .rect(.bounds)) {
            RunProgressSheet(run: run, taskID: run.taskID)
                .frame(width: 480)
                .onDisappear {
                    runner.dismiss(taskID: run.taskID, in: projectPath)
                    store.reload()
                }
        }
        .help(failed ? "Capture failed — click for details, close to dismiss"
                     : "Show capture progress")
    }
}
