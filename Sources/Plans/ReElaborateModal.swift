import SwiftUI
import OSLog

private let reElaborateLog = Logger(subsystem: "com.plans.desktop", category: "ReElaborateModal")

/// The "Refine Plan" capture sheet (#056) — a stripped-down sibling of
/// `NewPlanModal` for an already-elaborated plan whose How checklist the user
/// wants to refine with extra guidance.
///
/// Unlike `NewPlanModal` this sheet is single-purpose: the target project and
/// task are FIXED (passed via `init(taskID:projectPath:)`), so there is no
/// project picker, no Elaborate/Execute toggles, and NO draft persistence — just
/// one auto-growing guidance editor. Images pasted or dropped into that editor
/// ARE staged (#085) — shown in a thumbnail strip and, at submit, written under
/// Application Support and appended to the guidance as markdown references. On
/// submit it hands the (image-flattened) guidance to
/// `TaskRunner.run(... mode: .reElaborate, description:)`, whose spawned process
/// is the SOLE writer of `.plans/` (§2 read-only); this view never touches the
/// filesystem itself except to stage images under Application Support.
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

    /// The PNG bytes of the images pasted/dropped into the guidance editor
    /// (#085), in staging order — empty when none are staged. NOT persisted (this
    /// sheet keeps no draft); written to disk under Application Support and
    /// appended to the guidance as markdown references only at submit time.
    @State private var imageDatas: [Data] = []

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

            imagePreview

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
                // Enabled when EITHER the text is non-empty OR at least one image
                // is staged (#085), so an image-only refine is submittable.
                Button("Refine") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(trimmedText.isEmpty && imageDatas.isEmpty)
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
    /// exceeds the visible box. Image paste/drop IS wired here (#085):
    /// `onImagePasted` stages the PNG bytes into `imageDatas`, which the
    /// `imagePreview` strip renders and `submit` flattens into the guidance.
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            PlanTextEditor(
                text: $text,
                font: Self.editorFont,
                inset: Self.editorInset,
                onImagePasted: { imageDatas.append($0) }
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

    // MARK: - Image preview (#085)

    /// A horizontally-scrolling row of thumbnails — one per staged pasted/dropped
    /// image — each with its OWN Remove control, shown only while at least one
    /// image is staged. When `imageDatas` is empty NOTHING is rendered, so the
    /// editor/placeholder layout is unchanged for the common no-image case.
    ///
    /// Each Remove drops JUST that staged blob (`imageDatas.remove(at:)`, bounds-
    /// guarded); the on-disk write + guidance flattening happen only at submit,
    /// never here. Ported from `NewPlanModal.imagePreview` minus the `persistDraft`
    /// call — this sheet keeps no draft. The row scrolls horizontally so many
    /// staged images can't blow out the modal width.
    ///
    /// Iterating `imageDatas.indices` is safe here: each Remove is a discrete user
    /// action that mutates state and forces a re-render before the next removal, so
    /// no stale index is ever used across two removals in one pass.
    @ViewBuilder
    private var imagePreview: some View {
        if !imageDatas.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(imageDatas.indices, id: \.self) { index in
                        if let nsImage = NSImage(data: imageDatas[index]) {
                            VStack(spacing: 4) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                                    )

                                Button {
                                    guard imageDatas.indices.contains(index) else { return }
                                    imageDatas.remove(at: index)
                                } label: {
                                    Label("Remove", systemImage: "xmark.circle")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove this staged image")
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Submit

    /// Hands the guidance to `TaskRunner.run` in `.reElaborate` mode (the spawned
    /// process is the sole `.plans/` writer, §2) and dismisses.
    ///
    /// When images are staged (#085), each is saved under Application Support and
    /// its markdown reference appended to the guidance via
    /// `CaptureImageStore.saveAndFlatten` — so an image-only refine (empty typed
    /// box, staged image) still sends a non-empty `description` carrying just the
    /// `![pasted image](file://…)` references. With NO images staged an
    /// empty/whitespace-only guidance is ignored (the submit button is also
    /// disabled in that case); a non-empty box passes the trimmed text.
    private func submit() {
        let trimmed = trimmedText
        // With no images staged, an empty box is a no-op (mirrors the disabled
        // button). When images ARE staged we proceed even on empty text — the
        // flattened references carry the guidance.
        guard !trimmed.isEmpty || !imageDatas.isEmpty else { return }
        let description = CaptureImageStore().saveAndFlatten(
            description: trimmed,
            imageDatas: imageDatas
        )
        reElaborateLog.notice("modal Refine submitted: task=\(self.taskID, privacy: .public) deep=\(self.deep)")
        runner.run(
            projectPath: projectPath,
            taskID: taskID,
            mode: .reElaborate,
            description: description,
            deep: deep
        )
        dismiss()
    }
}
