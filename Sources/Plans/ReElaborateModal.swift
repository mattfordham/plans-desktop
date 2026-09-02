import SwiftUI
import OSLog

private let reElaborateLog = Logger(subsystem: "com.plans.desktop", category: "ReElaborateModal")

/// The "Refine Plan" capture sheet (#056) — a stripped-down sibling of
/// `NewPlanModal` for an already-elaborated plan whose How checklist the user
/// wants to refine with extra guidance.
///
/// Unlike `NewPlanModal` this sheet is single-purpose: the target project and
/// task are FIXED (passed via `init(taskID:projectPath:)`), so there is no
/// project picker, no Elaborate/Execute toggles, no image paste, and NO draft
/// persistence — just one auto-growing guidance editor. On submit it hands the
/// trimmed guidance to `TaskRunner.run(... mode: .reElaborate, description:)`,
/// whose spawned process is the SOLE writer of `.plans/` (§2 read-only); this
/// view never touches the filesystem itself.
///
/// It reuses `NewPlanModal`'s `PlanTextEditor` and editor styling so the box
/// reads as the same capture surface, just narrowed to the single field. Frame
/// and min-size match `NewPlanModal` so the sheet feels like the capture modal.
struct ReElaborateModal: View {
    /// The task whose plan is being refined; fixed for this sheet's lifetime.
    let taskID: String

    /// The owning project's path; fixed for this sheet's lifetime. Handed to the
    /// runner so the re-elaborate run targets the right project's `.plans/`.
    let projectPath: String

    /// The "Work this task" runner whose `.reElaborate` run drives plan-elaborate
    /// Path C with the user's guidance (the sole `.plans/` writer, §2).
    @Environment(TaskRunner.self) private var runner

    /// Dismisses the sheet (Cancel and post-submit).
    @Environment(\.dismiss) private var dismiss

    /// The in-flight guidance text. Not persisted — this sheet keeps no draft.
    @State private var text = ""

    /// Whether the "Deep" toggle is on (#075): draft the refinement pass via a
    /// reasoning sub-agent (plans-cc `deep` mode). Unlike `NewPlanModal` there is
    /// no Elaborate toggle here, so Deep is unconditional — it drives the
    /// `.reElaborate` run's `--deep` flag and composes orthogonally with it.
    @State private var deep = false

    /// The minimum editor height (one comfortable multi-line box) before it
    /// stretches to fill the remaining sheet space. Matches `NewPlanModal`.
    private static let editorMinHeight: CGFloat = 160

    /// The guidance editor's font — the same prompt-box-sized hero
    /// `NewPlanModal` uses, shared by the real text and the placeholder.
    private static let editorFont = NSFont.preferredFont(forTextStyle: .title2)

    /// The editor's `textContainerInset`. The placeholder is positioned against
    /// this exact value (plus the text container's line-fragment padding) so it
    /// lands precisely on the caret — same approach as `NewPlanModal`.
    private static let editorInset = CGSize(width: 12, height: 10)

    /// The trimmed guidance; empty means submit is disabled.
    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Refine Plan #\(taskID)")
                .font(.headline)

            editor

            Divider()

            HStack {
                Spacer()
                Toggle("Deep", isOn: $deep)
                    .toggleStyle(.checkbox)
                    .help("Draft the elaboration via a reasoning sub-agent (plans-cc `deep` mode)")
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // ⌘↩ submits (a bare Return inserts a newline in the multi-line
                // editor, so the submit shortcut is the Command-modified Return).
                Button("Refine") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(trimmedText.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Editor (auto-growing guidance box)

    /// The guidance editor with the placeholder + rounded-border styling lifted
    /// from `NewPlanModal.editor` (reusing its `PlanTextEditor`). It stretches to
    /// fill the remaining vertical space in the sheet (floored at
    /// `editorMinHeight`); the editor scrolls internally once the content
    /// exceeds the visible box. No image paste is wired here — `onImagePasted`
    /// is a no-op since this sheet stages no images.
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            PlanTextEditor(
                text: $text,
                font: Self.editorFont,
                inset: Self.editorInset,
                onImagePasted: { _ in }
            )
                .frame(minHeight: Self.editorMinHeight, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                )

            if text.isEmpty {
                // The placeholder shares the editor's exact text origin (the
                // `editorInset` plus the text container's ~5pt leading line
                // fragment padding), so it sits precisely on the caret at any
                // font — same alignment trick as `NewPlanModal.editor`.
                Text("Add guidance to refine plan #\(taskID)…")
                    .font(Font(Self.editorFont))
                    .foregroundStyle(.secondary)
                    .padding(.leading, Self.editorInset.width + 5)
                    .padding(.top, Self.editorInset.height)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Submit

    /// Hands the trimmed guidance to `TaskRunner.run` in `.reElaborate` mode (the
    /// spawned process is the sole `.plans/` writer, §2) and dismisses. An
    /// empty/whitespace-only guidance is ignored (the submit button is also
    /// disabled in that case).
    private func submit() {
        let trimmed = trimmedText
        guard !trimmed.isEmpty else { return }
        reElaborateLog.notice("modal Refine submitted: task=\(self.taskID, privacy: .public) deep=\(self.deep)")
        runner.run(
            projectPath: projectPath,
            taskID: taskID,
            mode: .reElaborate,
            description: trimmed,
            deep: deep
        )
        dismiss()
    }
}
