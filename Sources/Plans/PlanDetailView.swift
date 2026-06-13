import SwiftUI
import AppKit

/// A standalone renderer for a single plan's detail body (§011). This is the
/// reusable surface shown both inside the browser window's detail pane and in a
/// dedicated plan-detail window: the title, the owning project + status line,
/// and each `## ` section rendered as markdown (the `## How` section as a read-
/// only checklist, §2 — never interactive).
///
/// It resolves its row from the injected `PlansStore` by composite id via the
/// shared `BrowserViewModel.resolveRow(in:id:)`, so it stays live as the store
/// re-reads. It carries NO Close button — when hosted in its own window the
/// window's close control replaces it. When the id can't be resolved (the plan
/// completed, the project disappeared, or `rowID` is nil) it shows a muted
/// "Plan not found" placeholder. The view ONLY reads from the store — it never
/// writes, moves, or deletes any `.plans/` data (§2 read-only).
struct PlanDetailView: View {
    /// The composite row id (`projectPath + "/" + task.id`) to render, or `nil`
    /// when no plan is targeted (renders the placeholder).
    let rowID: TaskRow.ID?

    @Environment(PlansStore.self) private var store

    /// The shared task-run coordinator, injected by the scene. Resolves the
    /// `TaskRun` for this view's task — driving the Elaborate/Execute actions,
    /// the inline running state, and the progress sheet.
    @Environment(TaskRunner.self) private var runner

    /// Whether the progress sheet is presented. Raised when THIS task's run
    /// starts (see the `.onChange(of: runner.isRunning(taskID:))` below) and
    /// lowered by the sheet's Done button. Kept as real view state (rather than
    /// binding the sheet to the run's `isRunning`) so the user can close the
    /// sheet WITHOUT the close being swallowed and without stopping the run —
    /// dismissing the sheet is decoupled from the run's lifecycle.
    @State private var showProgress = false

    /// The resolved row for `rowID` across all projects' active rows, or `nil`
    /// when absent. Re-derived from the live store on each render.
    private var row: TaskRow? {
        guard let rowID else { return nil }
        return BrowserViewModel.resolveRow(in: store.projects, id: rowID)
    }

    var body: some View {
        Group {
            if let row {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        detailHeader(row)
                        ForEach(Array(row.task.sections.enumerated()), id: \.offset) { _, section in
                            sectionView(section)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .textSelection(.enabled)
            } else {
                VStack {
                    Text("Plan not found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // If this task is ALREADY running when the window opens (e.g. the user
        // clicked the card spinner to come here), pop the progress sheet right
        // away — `.onChange` only catches a fresh transition, not the standing
        // state, so this `.onAppear` covers the already-running case.
        .onAppear {
            if let id = row?.task.id, runner.isRunning(taskID: id) {
                showProgress = true
            }
        }
        // Raise the sheet when THIS task's run starts. Scoped to this row's task,
        // so a run launched for a different task never pops a sheet here. The
        // sheet stays up after the run ends so the user can read the summary,
        // then closes it themselves via Done.
        .onChange(of: runner.isRunning(taskID: row?.task.id ?? "")) { _, isRunning in
            if isRunning { showProgress = true }
        }
        // The modal progress sheet. Presented via real view state so the Done
        // button / auto-dismiss can actually close it; `onDisappear` reloads the
        // store so the task's new status is surfaced by the existing read path.
        // Closing the sheet does NOT stop the run — it keeps going in the
        // background (and stays visible on the card row's inline status).
        .sheet(isPresented: $showProgress) {
            RunProgressSheet(run: row.map { runner.run(for: $0.task.id) } ?? nil,
                             taskID: row?.task.id)
                .onDisappear {
                    if let id = row?.task.id { runner.dismiss(taskID: id) }
                    store.reload()
                }
        }
        // NOTE: closing the detail window deliberately does NOT stop the run.
        // Runs are independent of any window now (they can be launched straight
        // from a card), so a run survives closing the detail; stop it explicitly
        // via the sheet's Stop button or the card.
    }

    /// The detail header: the title as a prominent heading, the owning project's
    /// name (since there is no longer a selected sidebar project for context),
    /// plus a status line (the type badge and the status's `filterLabel`).
    private func detailHeader(_ row: TaskRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.projectName)
                .font(.body)
                .foregroundStyle(.secondary)

            Text(row.title ?? "(untitled)")
                .font(.title)
                .fontWeight(.semibold)

            HStack(spacing: 6) {
                // The status icon + color (blocked takes precedence), matching
                // the cards and the menu-bar glance via the same `symbolName`.
                let indicator = row.indicator
                Image(systemName: indicator.symbolName)
                    .imageScale(.medium)
                    .foregroundStyle(indicator.color)
                    .frame(width: 20, alignment: .center)
                if row.task.isBlocked {
                    Text("Blocked")
                        .foregroundStyle(TaskStatusIndicator.blockedColor)
                } else if let status = row.task.status {
                    Text(status.filterLabel)
                }
                if let type = row.type {
                    Text("·").foregroundStyle(.secondary)
                    Text("[\(type.label)]")
                }
            }
            .font(.body)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if runner.isRunning(taskID: row.task.id) {
                    // This task is being worked: show live status + a way back
                    // into the progress sheet (the run is independent of this
                    // window now). No action buttons while it runs.
                    ProgressView().controlSize(.small)
                    Button("Show progress") { showProgress = true }
                } else {
                    // "Elaborate" — hands a pending plan off to the bundled
                    // runner in autonomous `plan-elaborate` mode. Available only
                    // for a pending, non-blocked task.
                    if Self.canElaborate(status: row.task.status, isBlocked: row.task.isBlocked) {
                        Button {
                            runner.run(projectPath: row.projectPath,
                                       taskID: row.task.id, mode: .elaborate)
                        } label: {
                            Label("Elaborate", systemImage: "sparkles")
                        }
                    }

                    // "Execute" — hands the plan off to the bundled Agent-SDK
                    // runner in worktree-isolated `plan-execute` mode. Available
                    // only for an elaborated/in-progress, non-blocked task.
                    if Self.canWork(status: row.task.status, isBlocked: row.task.isBlocked) {
                        Button {
                            runner.run(projectPath: row.projectPath,
                                       taskID: row.task.id, mode: .execute)
                        } label: {
                            Label("Execute", systemImage: "play.fill")
                        }
                    }
                }

                // Read-only file actions, ALWAYS visible regardless of task
                // status or running state: reveal the plan's markdown file in
                // Finder, or open it in the default markdown app. Both no-op
                // safely when the file can't be resolved.
                Button {
                    if let url = Self.taskFileURL(
                        projectPath: row.projectPath,
                        taskID: row.task.id,
                        isCompletedDir: row.task.isCompletedDir
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }

                Button {
                    if let url = Self.taskFileURL(
                        projectPath: row.projectPath,
                        taskID: row.task.id,
                        isCompletedDir: row.task.isCompletedDir
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open in Markdown App", systemImage: "doc.text")
                }
            }
            .padding(.top, 4)
        }
    }

    /// Pure predicate for the "Execute" action's availability, so the gating rule
    /// is unit-testable independent of the view. Available only for an elaborated
    /// (not in-progress) task that is not blocked: once a task is in-progress it
    /// already has a run underway (or completed) and must not offer Execute again
    /// (#027). Whether a run is in flight is a separate, per-task concern (the row
    /// shows a spinner instead of the button) — runs are independent across tasks,
    /// so it does NOT gate availability.
    static func canWork(status: TaskStatus?, isBlocked: Bool) -> Bool {
        guard !isBlocked else { return false }
        return status == .elaborated
    }

    /// Pure predicate for the "Elaborate" action's availability. Available only
    /// for a `pending` task that is not blocked — elaboration is the step that
    /// produces the How checklist a subsequent Execute run needs.
    static func canElaborate(status: TaskStatus?, isBlocked: Bool) -> Bool {
        guard !isBlocked else { return false }
        return status == .pending
    }

    /// Resolves the on-disk markdown file for a task, so the read-only
    /// "Show in Finder" / "Open in Markdown App" actions have a URL to act on.
    /// The `Task` model does not store the filename slug, so the file is found
    /// by scanning `<projectPath>/.plans/<pending|completed>/` for the first
    /// `.md` whose name begins with `<taskID>-`. Returns `nil` on any error or
    /// when no matching file exists (the buttons then no-op).
    static func taskFileURL(
        projectPath: String,
        taskID: String,
        isCompletedDir: Bool
    ) -> URL? {
        let subdir = isCompletedDir ? "completed" : "pending"
        let dir = URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".plans")
            .appendingPathComponent(subdir)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        let prefix = taskID + "-"
        return contents.first { url in
            url.pathExtension == "md"
                && url.lastPathComponent.hasPrefix(prefix)
        }
    }

    /// Renders one `## ` section: its heading, then its body. The `## How`
    /// section is rendered specially as a read-only checklist; all others render
    /// their body as markdown paragraphs.
    @ViewBuilder
    private func sectionView(_ section: TaskSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.heading)
                .font(.headline)

            if section.heading == "How" {
                howChecklist(section.body)
            } else {
                markdownBlockView(section.body)
            }
        }
    }

    /// Renders a section body as block-level markdown: paragraphs, bullet /
    /// numbered lists, fenced code, blockquotes, and sub-headings, in document
    /// order. Block structure is recovered by the pure `MarkdownBlockRenderer`;
    /// inline markdown within each block's text is still applied via
    /// `markdownParagraph(_:)`. Purely presentational — performs no writes.
    @ViewBuilder
    private func markdownBlockView(_ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlockRenderer.parse(body).enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    /// Renders a single parsed `MarkdownBlock` with restrained, readable styling.
    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            markdownParagraph(text)

        case let .heading(level, text):
            Text(text)
                .font(headingFont(forLevel: level))
                .padding(.top, 2)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        markdownParagraph(item)
                    }
                    .padding(.leading, 4)
                }
            }

        case let .numberedList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).")
                            .monospacedDigit()
                        markdownParagraph(item)
                    }
                    .padding(.leading, 4)
                }
            }

        case let .codeBlock(code):
            Text(code)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))

        case let .blockquote(text):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(.secondary)
                    .frame(width: 3)
                markdownParagraph(text)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 2)
        }
    }

    /// The emphasized font for a sub-heading, scaling down with nesting depth:
    /// level 1/2 read as section-ish, level 3+ as a smaller bold subhead.
    private func headingFont(forLevel level: Int) -> Font {
        switch level {
        case 1: return .title3.bold()
        case 2: return .headline
        default: return .subheadline.bold()
        }
    }

    /// Renders a single paragraph as markdown, tolerating parse failures by
    /// falling back to plain text. Uses an options value that does not throw on
    /// the default markdown grammar; the whole parse is wrapped in `try?`.
    private func markdownParagraph(_ paragraph: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: paragraph, options: options) {
            return Text(attributed)
        }
        return Text(paragraph)
    }

    /// Renders the `## How` body as a READ-ONLY checklist. Lines matching
    /// `- [ ]` / `- [x]` / `- [X]` become a `Label` with `square` /
    /// `checkmark.square`; the checkbox prefix is stripped from the step text.
    /// These are never interactive (§2): no `Toggle`, no `Button`, no binding,
    /// no writes.
    @ViewBuilder
    private func howChecklist(_ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(BrowserViewModel.howSteps(body).enumerated()), id: \.offset) { _, step in
                Label(step.text, systemImage: step.done ? "checkmark.square" : "square")
            }
        }
    }
}

/// The modal progress dialog for a single task's run. Renders that run's live
/// NDJSON stream: a scrolling activity/text log, a cost/turns summary once the
/// run reports `done`, an error banner on a streamed/terminal error, and a Stop
/// button wired to the run's `stop()`. It dismisses via `@Environment(\.dismiss)`,
/// so it works whether presented as a `.sheet` (the detail view) or a `.popover`
/// (the card spinner) — the Done/Close button can close it either way; closing
/// does NOT stop the run (it keeps going in the background).
struct RunProgressSheet: View {
    /// The specific run to render, or `nil` if there is none (e.g. the run was
    /// dropped). When nil the sheet shows a minimal "no active run" state.
    let run: TaskRun?

    /// The task id being worked, for the header (e.g. "Working task #019").
    let taskID: String?

    @Environment(\.dismiss) private var dismiss

    /// The id of the line to scroll into view on first appearance: the last
    /// (newest) line, or `nil` when there are no lines yet. Pure so it's unit
    /// testable without constructing the view.
    static func scrollTarget(for lines: [LoggedEvent]) -> UUID? {
        lines.last?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let error = run?.error {
                errorBanner(error)
            }

            logList

            if let summary = run?.summary {
                summaryRow(summary)
            }

            footer
        }
        .padding(12)
        // Cap the height so a long run log can't grow the dialog unbounded.
        // This matters most when presented as a popover from the card spinner,
        // which has no enclosing window to bound it; the `logList` ScrollView
        // scrolls any overflow within the cap.
        .frame(minWidth: 480, minHeight: 360, maxHeight: 520)
    }

    /// The verb for this run's mode ("Executing" / "Elaborating" / "Capturing"
    /// / "Capturing & elaborating" / "Capturing & executing").
    private var modeVerb: String {
        switch run?.mode {
        case .elaborate: return "Elaborating"
        case .capture: return "Capturing"
        case .captureElaborate: return "Capturing & elaborating"
        case .executeYolo: return "Capturing & executing"
        case .execute, .none: return "Executing"
        }
    }

    /// The dialog title. Capture / captureElaborate / executeYolo runs have no
    /// real task id yet — they're keyed by a synthetic `"capture:<path>"`
    /// identity — so they show only the verb ("Capturing", "Capturing &
    /// elaborating", "Capturing & executing") rather than "Capturing task
    /// #capture:/…". Real runs keep the "verb task #NNN" form.
    private var title: String {
        switch run?.mode {
        case .capture, .captureElaborate, .executeYolo:
            return modeVerb
        default:
            return taskID.map { "\(modeVerb) task #\($0)" } ?? modeVerb
        }
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.headline)
            if run?.isRunning == true {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
        }
    }

    /// Auto-scrolling log of activity + text lines. Uses `ScrollViewReader` to
    /// scroll the newest line into view as lines append. Terminal `done`/`error`
    /// events are rendered out-of-band (summary row / error banner), so the list
    /// body shows only `.activity` and `.text`.
    private var logList: some View {
        let lines = run?.lines ?? []
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    // Immediate-feedback placeholder: until the first NDJSON line
                    // arrives, show a "Starting…" / "Waiting…" row so the sheet is
                    // never blank dead air while node resolves and the agent spins
                    // up (the first assistant message can take several seconds).
                    if lines.isEmpty, let phase = run?.phase {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(phase == .launching
                                 ? "Starting…"
                                 : "Waiting for the agent…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(lines) { logged in
                        lineView(logged.event)
                            .id(logged.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                // Stretch the log column to the full scroll width even while it
                // holds only the short "Starting…/Waiting…" placeholder, so the
                // inset `.textBackgroundColor` field is full-width from the first
                // frame instead of hugging the narrow placeholder until log lines
                // (which already carry `maxWidth: .infinity`) arrive.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: lines.count) {
                if let last = lines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            // On first appearance against a run that already has buffered
            // lines (e.g. opening the spinner of an in-progress task), jump
            // straight to the newest line — instantly, no animation — so the
            // view opens at the bottom instead of the top.
            .onAppear {
                if let target = RunProgressSheet.scrollTarget(for: lines) {
                    proxy.scrollTo(target, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func lineView(_ event: RunEvent) -> some View {
        switch event {
        case let .activity(tool, detail):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(tool)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case let .text(chunk):
            Text(chunk)
                .font(.callout)
        case .done, .error:
            // Rendered out-of-band as the summary row / error banner.
            EmptyView()
        }
    }

    private func summaryRow(_ summary: (costUsd: Double, turns: Int)) -> some View {
        Text(String(format: "$%.2f · %d turns", summary.costUsd, summary.turns))
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.red.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack {
            Spacer()
            if run?.isRunning == true {
                // While running: Stop ends the run; Close just backgrounds the
                // sheet (the run keeps going, reachable again via the card
                // spinner or the detail's "Show progress").
                Button(role: .destructive) {
                    run?.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)

                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                // Finished: Done dismisses (and drops the finished run).
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
