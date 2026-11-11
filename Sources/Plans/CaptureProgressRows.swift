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

    /// #117: selects a capture's synthetic row (opening the "Capturing…"
    /// placeholder detail + its dock) by its synthetic id. Replaces the former
    /// per-row progress popover.
    let onOpenDetail: (TaskRow.ID) -> Void

    /// The currently selected detail-column row id, so a selected capture row
    /// paints the shared selection background. `nil` when none is selected.
    var selectedRowID: TaskRow.ID? = nil

    /// The shared "Work this task" runner — the live in-flight-capture registry.
    /// Read-only here; the run process is the sole writer of `.plans/` (§2).
    @Environment(TaskRunner.self) private var runner

    @State private var hoveringTaskID: String? = nil

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

    /// A single capture row: a small spinner plus the run's description. #117:
    /// tapping it SELECTS the synthetic capture row — opening the "Capturing…"
    /// placeholder detail and its always-present dock (which hosts the capture's
    /// log and a Dismiss for an errored capture) — rather than a per-row popover.
    ///
    /// A capture that finished IN ERROR swaps the spinner for a warning glyph —
    /// reconciliation pins errored runs (they are never auto-dismissed), so this
    /// row is how the failure is raised; the dock's Dismiss is what clears it.
    @ViewBuilder
    private func captureRow(_ run: TaskRun) -> some View {
        let failed = !run.isRunning && run.error != nil
        let isSelected = selectedRowID == run.taskID
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
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18)
                                 : (hoveringTaskID == run.taskID ? Color.primary.opacity(0.06)
                                                                 : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenDetail(run.taskID)
        }
        .onHover { hoveringTaskID = $0 ? run.taskID : nil }
        .help(failed ? "Capture failed — open to see details and dismiss"
                     : "Open capture progress")
    }
}
