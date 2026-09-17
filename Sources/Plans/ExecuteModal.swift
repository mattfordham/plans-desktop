import SwiftUI
import OSLog

private let executeLog = Logger(subsystem: "com.plans.desktop", category: "ExecuteModal")

/// The "Execute" confirmation sheet (#078) — the dialog the Execute action now
/// opens instead of firing the run straight off the glyph/button.
///
/// Like its siblings `ElaborateModal` and `ReElaborateModal` this sheet is
/// single-purpose: the target project and task are FIXED (passed via
/// `init(taskID:projectPath:)`), so there is no project picker, no image paste,
/// and NO draft persistence. Unlike them it carries NO text box at all — it is a
/// pure options sheet whose only control is the "Keep" toggle.
///
/// **Why no guidance box.** The obvious symmetry with `ElaborateModal` would be
/// an optional guidance field, but `.execute` has no description channel at any
/// layer, so such a field's contents would be silently discarded:
/// `RunMode.usesDescription` is `false` for `.execute` (so `TaskRun.spawn` never
/// emits `--description`), the `run-task.ts` launcher returns `description` only
/// for the `elaborate` branch, `buildExecutePrompt` takes no guidance parameter,
/// and the `plan-execute` skill parses stray non-numeric text as a step filter
/// rather than as guidance. Rendering a field that drops what the user types
/// would be a UX lie, so the sheet is deliberately keep-only.
///
/// On submit it hands the Keep flag to `TaskRunner.run(... mode: .execute)`,
/// whose spawned process is the SOLE writer of `.plans/` (§2 read-only); this
/// view never touches the filesystem itself.
struct ExecuteModal: View {
    /// The task being executed; fixed for this sheet's lifetime.
    let taskID: String

    /// The owning project's path; fixed for this sheet's lifetime. Handed to the
    /// runner so the execute run targets the right project's `.plans/`.
    let projectPath: String

    /// The "Work this task" runner whose `.execute` run drives plan-execute (the
    /// sole `.plans/` writer, §2).
    @Environment(TaskRunner.self) private var runner

    /// Dismisses the sheet (Cancel and post-submit).
    @Environment(\.dismiss) private var dismiss

    /// Whether the "Keep" toggle is on (#078): preserve the execution git
    /// worktree past finish so `/plan-review` can review the plan in place and
    /// several tasks can be reviewed in parallel. Unlike `NewPlanModal` — where
    /// Keep is disabled until Execute is on — this whole sheet IS an execute
    /// run, so the toggle is always enabled here (exactly as Deep is always
    /// enabled inside `ElaborateModal`). Not persisted; this sheet keeps no
    /// draft, so Keep starts off on every open and is an explicit opt-in.
    @State private var keep = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Execute #\(taskID)")
                .font(.headline)

            HStack(spacing: 16) {
                // Always enabled: this sheet's only action is an execute run, so
                // unlike `NewPlanModal` there is no Execute toggle to gate it.
                Toggle("Keep", isOn: $keep)
                    .toggleStyle(.checkbox)
                    .help("Keep the execution worktree after finishing, so the plan can be reviewed in place")
                Spacer()
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // ⌘↩ submits, matching the other run sheets' shortcut so the
                // gesture is identical across them. Never disabled — Keep off is
                // a first-class submit (it is the bare Execute this replaced).
                Button("Execute") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
        // Width matches the sibling run sheets so the modals feel like one
        // family, but the height is sized to THIS sheet's content rather than
        // inheriting `minHeight: 380` — with no text editor to fill it, that
        // would leave a tall band of empty space under a single checkbox.
        .frame(minWidth: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Submit

    /// Hands the Keep flag to `TaskRunner.run` in `.execute` mode (the spawned
    /// process is the sole `.plans/` writer, §2) and dismisses. No `description`
    /// is passed: the parameter defaults to `nil` and `.execute` would discard it
    /// anyway (`RunMode.usesDescription` is false), so with Keep off this spawns
    /// byte-for-byte the run the bare Execute button fired before #078.
    private func submit() {
        executeLog.notice("modal Execute submitted: task=\(self.taskID, privacy: .public) keep=\(self.keep)")
        runner.run(
            projectPath: projectPath,
            taskID: taskID,
            mode: .execute,
            keep: keep
        )
        dismiss()
    }
}
