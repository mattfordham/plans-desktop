import SwiftUI
import OSLog

private let modalLog = Logger(subsystem: "com.plans.desktop", category: "NewPlanModal")

/// The project-scoped "New Plan" capture sheet (#031), replacing the per-card
/// inline capture popover with a single, larger modal form.
///
/// The sheet lets the user pick a target project, type a plan description into an
/// auto-growing editor, toggle "Elaborate" and "Execute", and submit. Submission
/// hands the description to `TaskRunner.capture` — the bundled Agent-SDK process
/// it spawns is the SOLE writer of `.plans/` (§2 read-only); this view never
/// touches the filesystem itself.
///
/// **Draft-resilient.** The in-flight text and toggles are persisted per project
/// through `PlansStore` (UserDefaults only, never `.plans/`), so dismissing the
/// sheet (Cancel) and reopening it — or relaunching the app — restores exactly
/// what the user was typing. Switching the project picker swaps to THAT project's
/// saved draft. "Clear" empties the form and drops the saved draft; a successful
/// submit also drops it. Presentation is wired in by `BrowserWindow`/`ProjectCard`
/// in a later segment — this view is self-contained.
struct NewPlanModal: View {
    /// The shared store: source of the project list and the draft persistence.
    /// Read/write of drafts only — never writes `.plans/` (§2).
    @Environment(PlansStore.self) private var store

    /// The "Work this task" runner whose `capture` spawns the capture/execute
    /// run (the sole `.plans/` writer, §2).
    @Environment(TaskRunner.self) private var runner

    /// Dismisses the sheet (Cancel and post-submit).
    @Environment(\.dismiss) private var dismiss

    /// The currently-selected target project path, seeded from the init argument
    /// and driven by the project `Picker`.
    @State private var projectPath: String

    /// The in-flight plan description text.
    @State private var text = ""

    /// Whether the "Execute" toggle is on (run autonomously in a worktree).
    @State private var execute = false

    /// Whether the "Elaborate" toggle is on (flesh the plan out after capture).
    @State private var elaborate = false

    /// The PNG bytes of an image pasted/dropped into the editor (#048), or nil
    /// when none is staged. Persisted in the per-project draft (UserDefaults only,
    /// never `.plans/` §2); written to disk under Application Support and appended
    /// to the description as a markdown reference only at submit time.
    @State private var imageData: Data?

    /// Guards the project-switch draft swap: when a project change is loading the
    /// new project's draft into the fields (text, toggles, AND the staged
    /// `imageData`), the field `.onChange` handlers must NOT persist back (that
    /// would overwrite the new project's draft with the old project's state
    /// mid-swap). Set true around the swap.
    @State private var isSwitchingProject = false

    /// A local snapshot of the staleness-ordered project list driving the picker
    /// (#036). The body must NOT read `store.projects` directly: the store
    /// reassigns `projects` on every 5s poll, which would invalidate this view —
    /// and the `TextEditor` being typed into — on each tick, producing the typing
    /// lag. Instead we capture the list once in `.onAppear` and refresh it only
    /// when the set of project paths actually changes (see `refreshProjectsSnapshot`).
    @State private var orderedProjectsSnapshot: [ProjectTasks] = []

    /// The minimum editor height (one comfortable multi-line box) before it
    /// stretches to fill the remaining sheet space.
    private static let editorMinHeight: CGFloat = 160

    /// The description editor's font — a prompt-box-sized hero (Claude/ChatGPT
    /// style). Shared by the real text and the placeholder so they never diverge.
    private static let editorFont = NSFont.preferredFont(forTextStyle: .title2)

    /// The editor's `textContainerInset`. The placeholder is positioned against
    /// this exact value (plus the text container's line-fragment padding) so it
    /// lands precisely on the caret regardless of font size.
    private static let editorInset = CGSize(width: 12, height: 10)

    /// Seeds `projectPath` from the initially-selected project. The remaining
    /// fields are restored from that project's saved draft in `.onAppear` (the
    /// store is only available from the environment, not at init time).
    init(initialProjectPath: String) {
        _projectPath = State(initialValue: initialProjectPath)
    }

    /// The projects offered by the picker, in the same staleness order the grid
    /// uses so the list reads consistently with the dashboard. This is the single
    /// source of the snapshot computation — `refreshProjectsSnapshot` reads it.
    private var orderedProjects: [ProjectTasks] {
        BrowserViewModel.sortByStaleness(store.projects)
    }

    /// The trimmed description; empty means submit is disabled.
    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The submit button label, reflecting the active toggles (Execute wins, then
    /// Elaborate, else a plain Capture) — matching `runner.capture`'s precedence.
    private var submitLabel: String {
        if execute { return "Execute" }
        if elaborate { return "Elaborate & Capture" }
        return "Capture"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Plan")
                .font(.headline)

            Picker("Project", selection: $projectPath) {
                ForEach(orderedProjectsSnapshot, id: \.projectPath) { project in
                    Text(project.projectName).tag(project.projectPath)
                }
            }

            editor

            imagePreview

            HStack(spacing: 16) {
                Toggle("Elaborate", isOn: $elaborate)
                    .toggleStyle(.checkbox)
                    .help("Flesh the plan out after capturing it")
                Toggle("Execute", isOn: $execute)
                    .toggleStyle(.checkbox)
                    .help("Capture, elaborate, and run the new plan autonomously in a worktree")
                Spacer()
            }

            Divider()

            HStack {
                Button("Clear") { clear() }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // ⌘↩ submits (a bare Return inserts a newline in the multi-line
                // editor, so the submit shortcut is the Command-modified Return).
                Button(submitLabel) { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(trimmedText.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            refreshProjectsSnapshot()
            loadDraft(for: projectPath)
        }
        // Refresh the picker's snapshot ONLY when the SET of project paths changes
        // (project added/removed/linked), keyed on the value-equatable path list —
        // NOT the whole `[ProjectTasks]` array. Routine 5s re-parses that keep the
        // same paths leave this untouched, so typing in the editor doesn't churn.
        .onChange(of: store.projects.map(\.projectPath)) { _, _ in
            refreshProjectsSnapshot()
        }
        .onChange(of: projectPath) { _, newPath in
            // Switching projects swaps to THAT project's saved draft rather than
            // carrying the old fields over. Suppress the field-change persistence
            // while the swap loads (see `isSwitchingProject`).
            loadDraft(for: newPath)
        }
        .onChange(of: text) { _, _ in persistDraft() }
        .onChange(of: execute) { _, _ in persistDraft() }
        .onChange(of: elaborate) { _, _ in persistDraft() }
        .onChange(of: imageData) { _, _ in persistDraft() }
    }

    // MARK: - Editor (auto-growing description box)

    /// The description editor with the placeholder + rounded-border styling lifted
    /// from `ProjectCard.capturePopover`. It stretches to fill the remaining
    /// vertical space in the sheet (floored at `editorMinHeight`), so the form
    /// always fills the panel and grows when the window is resized; the
    /// `TextEditor` scrolls internally once the content exceeds the visible box.
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            PlanTextEditor(
                text: $text,
                font: Self.editorFont,
                inset: Self.editorInset,
                onImagePasted: { imageData = $0 }
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
                // The placeholder shares the editor's exact text origin: the
                // underlying NSTextView's text starts at `editorInset` (its
                // `textContainerInset`) plus the text container's own ~5pt line
                // fragment padding on the leading edge. Matching those here keeps
                // "Describe the plan…" sitting precisely on the caret at any font.
                Text("Describe the plan…")
                    .font(Font(Self.editorFont))
                    .foregroundStyle(.secondary)
                    .padding(.leading, Self.editorInset.width + 5)
                    .padding(.top, Self.editorInset.height)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Image preview (#048)

    /// A small thumbnail of the staged pasted/dropped image plus a Remove control,
    /// shown only while an image is staged. When `imageData` is nil NOTHING is
    /// rendered, so the editor/placeholder layout is unchanged for the common
    /// no-image case. Remove drops the staged bytes and re-persists the draft
    /// (text/toggles untouched); the on-disk write + description flattening happen
    /// only at submit, never here.
    @ViewBuilder
    private var imagePreview: some View {
        if let imageData, let nsImage = NSImage(data: imageData) {
            HStack(spacing: 12) {
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
                    self.imageData = nil
                    persistDraft()
                } label: {
                    Label("Remove", systemImage: "xmark.circle")
                }
                .help("Remove the staged image")

                Spacer()
            }
        }
    }

    // MARK: - Project snapshot (#036)

    /// Recomputes the local picker snapshot from the store's current projects.
    /// Called once in `.onAppear` and again only when the set of project paths
    /// changes, so the body never depends on `store.projects` live (which would
    /// invalidate the editor on every poll). The selected `projectPath` is left
    /// untouched: if the previously-selected project disappeared from the list the
    /// Picker simply shows no matching row (it tolerates a tag with no row) and a
    /// later user pick reselects a valid one.
    private func refreshProjectsSnapshot() {
        orderedProjectsSnapshot = orderedProjects
    }

    // MARK: - Draft persistence + actions

    /// Loads `projectPath`'s saved draft into the fields (or resets them when no
    /// draft exists). Wrapped in `isSwitchingProject` so the field `.onChange`
    /// handlers triggered by these assignments don't persist the transient state
    /// back over the just-loaded draft.
    private func loadDraft(for path: String) {
        isSwitchingProject = true
        if let draft = store.draft(for: path) {
            text = draft.text
            execute = draft.execute
            elaborate = draft.elaborate
            imageData = draft.imageData
        } else {
            text = ""
            execute = false
            elaborate = false
            imageData = nil
        }
        // Clear the guard on the next runloop tick, after the field `.onChange`
        // notifications from the assignments above have drained.
        DispatchQueue.main.async { isSwitchingProject = false }
    }

    /// Persists the current fields as `projectPath`'s draft, unless a project
    /// switch is mid-swap (in which case the change came from loading, not the
    /// user, and must not overwrite the new project's draft).
    private func persistDraft() {
        guard !isSwitchingProject else { return }
        store.setDraft(
            PlansStore.CaptureDraft(
                text: text,
                execute: execute,
                elaborate: elaborate,
                imageData: imageData
            ),
            for: projectPath
        )
    }

    /// Empties the form and drops the saved draft for the current project.
    private func clear() {
        text = ""
        execute = false
        elaborate = false
        imageData = nil
        store.clearDraft(for: projectPath)
    }

    /// Hands the trimmed description to `TaskRunner.capture` (the spawned process
    /// is the sole `.plans/` writer, §2), drops the saved draft, and dismisses.
    /// An empty/whitespace-only description is ignored (the submit button is also
    /// disabled in that case).
    private func submit() {
        let trimmed = trimmedText
        guard !trimmed.isEmpty else { return }
        modalLog.notice("modal Capture submitted: project=\(self.projectPath, privacy: .public) execute=\(self.execute) elaborate=\(self.elaborate)")

        // If an image is staged, persist its PNG bytes under Application Support
        // (NEVER `.plans/`, §2) and append a markdown reference to the description.
        // A save failure is logged and falls back to the plain trimmed
        // description — it must never crash or block the capture.
        var description = trimmed
        if let imageData {
            do {
                let imageURL = try CaptureImageStore().saveImage(imageData)
                description = CaptureImageStore.flattenDescription(trimmed, imageURL: imageURL)
            } catch {
                modalLog.error("modal Capture: failed to save staged image, capturing plain description: \(error.localizedDescription, privacy: .public)")
            }
        }

        runner.capture(
            projectPath: projectPath,
            description: description,
            execute: execute,
            elaborate: elaborate
        )
        // Reset the staged image after capture.
        imageData = nil
        store.clearDraft(for: projectPath)
        dismiss()
    }
}

// MARK: - PlanTextEditor

/// An `NSTextView`-backed editor that exposes a known `textContainerInset` and
/// font. SwiftUI's `TextEditor` hides the text view's intrinsic insets, which
/// makes a ZStack placeholder overlay drift away from the real caret as the font
/// changes. Driving the `NSTextView` directly lets the placeholder be positioned
/// against the exact same inset (see `NewPlanModal.editor`), so they always align.
private struct PlanTextEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    /// The text view's `textContainerInset`. The placeholder mirrors this value.
    let inset: CGSize
    /// Invoked with PNG bytes when the user pastes or drops an image into the
    /// editor (#048). The image is NOT inserted as text; the host view stages it
    /// (see `NewPlanModal.imageData`) and references it from the description at
    /// submit time. Plain-text paste is untouched.
    var onImagePasted: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Build a scroll view around our `PlanNSTextView` subclass rather than the
        // stock `NSTextView.scrollableTextView()`, so paste/drop image capture is
        // available while every other behaviour (insets, font, plain-text paste,
        // the `textDidChange` delegate) is unchanged.
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let contentSize = scrollView.contentSize
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = PlanNSTextView(frame: .zero, textContainer: textContainer)
        textView.onImagePasted = onImagePasted
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        textView.delegate = context.coordinator
        textView.font = font
        textView.textContainerInset = inset
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false      // the SwiftUI background shows through
        textView.backgroundColor = .clear
        textView.textColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PlanNSTextView else { return }
        textView.onImagePasted = onImagePasted
        if textView.string != text {
            textView.string = text
        }
        textView.font = font
        textView.textContainerInset = inset
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: PlanTextEditor

        init(_ parent: PlanTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

// MARK: - PlanNSTextView (image paste/drop capture)

/// An `NSTextView` subclass that intercepts pasted and dropped images (#048),
/// routing their PNG bytes to `onImagePasted` instead of letting raw image data
/// land in the text. Plain-text paste and every other text-view behaviour fall
/// through to `super` unchanged.
private final class PlanNSTextView: NSTextView {
    /// Set by `PlanTextEditor`; receives PNG bytes for a pasted/dropped image.
    var onImagePasted: ((Data) -> Void)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        registerForDraggedTypes([.png, .tiff, .fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Intercept ⌘V. If the general pasteboard carries image data, capture it and
    /// stop — otherwise defer to the standard plain-text paste.
    override func paste(_ sender: Any?) {
        if let data = Self.pngData(from: NSPasteboard.general) {
            onImagePasted?(data)
            return
        }
        super.paste(sender)
    }

    /// Belt-and-suspenders for services/`readSelection`-driven inserts: capture
    /// image data the same way, otherwise fall through to `super`.
    override func readSelection(from pasteboard: NSPasteboard) -> Bool {
        if let data = Self.pngData(from: pasteboard) {
            onImagePasted?(data)
            return true
        }
        return super.readSelection(from: pasteboard)
    }

    // MARK: Drag-and-drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.hasImage(on: sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.hasImage(on: sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let data = Self.pngData(from: sender.draggingPasteboard) {
            onImagePasted?(data)
            return true
        }
        return super.performDragOperation(sender)
    }

    // MARK: Pasteboard → PNG

    /// True if `pasteboard` carries image data we can extract as PNG.
    private static func hasImage(on pasteboard: NSPasteboard) -> Bool {
        pngData(from: pasteboard) != nil
    }

    /// Extracts PNG `Data` from `pasteboard`, or nil when no image is present.
    /// Prefers a direct `.png`; otherwise re-encodes `.tiff` bitmap data (and, as
    /// a fallback, an image file URL) into PNG via `NSBitmapImageRep`.
    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) {
            return png
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        // A dragged image file: read its bytes and re-encode to PNG.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first,
           let fileData = try? Data(contentsOf: url),
           let rep = NSBitmapImageRep(data: fileData) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }
}

