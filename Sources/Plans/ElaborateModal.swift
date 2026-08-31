import SwiftUI
import OSLog

private let elaborateLog = Logger(subsystem: "com.plans.desktop", category: "ElaborateModal")

/// The "Elaborate" capture sheet (#074) — the dialog the Elaborate action now
/// opens instead of firing the run straight off the glyph/button.
///
/// Like its sibling `ReElaborateModal` this sheet is single-purpose: the target
/// project and task are FIXED (passed via `init(taskID:projectPath:)`), so there
/// is no project picker, no image paste, and NO draft persistence. It differs in
/// two ways: the guidance is OPTIONAL (an empty box submits exactly the bare
/// elaboration the button used to fire), and it offers the "Deep" toggle lifted
/// from `NewPlanModal`. On submit it hands the trimmed guidance — or `nil` when
/// blank — plus the Deep flag to `TaskRunner.run(... mode: .elaborate)`, whose
/// spawned process is the SOLE writer of `.plans/` (§2 read-only); this view
/// never touches the filesystem itself.
///
/// It reuses `NewPlanModal`'s `PlanTextEditor` and editor styling so the box
/// reads as the same capture surface. Frame and min-size match `NewPlanModal` so
/// the sheet feels like the capture modal.
struct ElaborateModal: View {
    /// The task being elaborated; fixed for this sheet's lifetime.
    let taskID: String

    /// The owning project's path; fixed for this sheet's lifetime. Handed to the
    /// runner so the elaborate run targets the right project's `.plans/`.
    let projectPath: String

    /// The "Work this task" runner whose `.elaborate` run drives plan-elaborate
    /// (the sole `.plans/` writer, §2).
    @Environment(TaskRunner.self) private var runner

    /// Dismisses the sheet (Cancel and post-submit).
    @Environment(\.dismiss) private var dismiss

    /// The in-flight guidance text. OPTIONAL — an empty box is a valid submit.
    /// Not persisted; this sheet keeps no draft.
    @State private var text = ""

    /// Whether the "Deep" toggle is on (#065): draft the elaboration via a
    /// reasoning sub-agent (plans-cc `deep` mode). Unlike `NewPlanModal` — where
    /// Deep is disabled until Elaborate is on — this whole sheet IS an
    /// elaboration, so the toggle is always enabled here.
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

    /// The trimmed guidance. Empty is allowed — it simply means "no guidance",
    /// and submit stays enabled (see `submit`).
    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Elaborate #\(taskID)")
                .font(.headline)

            editor

            HStack(spacing: 16) {
                // Always enabled: this sheet's only action is an elaboration, so
                // unlike `NewPlanModal` there is no Elaborate toggle to gate it.
                Toggle("Deep", isOn: $deep)
                    .toggleStyle(.checkbox)
                    .help("Draft the elaboration via a reasoning sub-agent (plans-cc `deep` mode)")
                Spacer()
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // ⌘↩ submits (a bare Return inserts a newline in the multi-line
                // editor, so the submit shortcut is the Command-modified Return).
                // Never disabled — the guidance is optional.
                Button("Elaborate") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
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
                // font — same alignment trick as `NewPlanModal.editor`. The
                // wording flags that the field is optional, since submitting an
                // empty box is a first-class path here.
                Text("Add optional guidance for elaborating plan #\(taskID)…")
                    .font(Font(Self.editorFont))
                    .foregroundStyle(.secondary)
                    .padding(.leading, Self.editorInset.width + 5)
                    .padding(.top, Self.editorInset.height)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Submit

    /// Hands the guidance and the Deep flag to `TaskRunner.run` in `.elaborate`
    /// mode (the spawned process is the sole `.plans/` writer, §2) and dismisses.
    /// An empty/whitespace-only box passes `nil` — NOT `""` — so the run spawns
    /// with no `--description` at all and behaves exactly like the bare Elaborate
    /// this dialog replaced.
    private func submit() {
        let trimmed = trimmedText
        let description = trimmed.isEmpty ? nil : trimmed
        elaborateLog.notice("modal Elaborate submitted: task=\(self.taskID, privacy: .public) deep=\(self.deep) hasGuidance=\(description != nil)")
        runner.run(
            projectPath: projectPath,
            taskID: taskID,
            mode: .elaborate,
            description: description,
            deep: deep
        )
        dismiss()
    }
}
