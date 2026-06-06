import SwiftUI

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
            }
            .padding(.top, 4)
        }
    }

    /// Pure predicate for the "Execute" action's availability, so the gating rule
    /// is unit-testable independent of the view. Available only for an elaborated
    /// or in-progress task that is not blocked. Whether a run is in flight is a
    /// separate, per-task concern (the row shows a spinner instead of the button)
    /// — runs are independent across tasks, so it does NOT gate availability.
    static func canWork(status: TaskStatus?, isBlocked: Bool) -> Bool {
        guard !isBlocked else { return false }
        return status == .elaborated || status == .inProgress
    }

    /// Pure predicate for the "Elaborate" action's availability. Available only
    /// for a `pending` task that is not blocked — elaboration is the step that
    /// produces the How checklist a subsequent Execute run needs.
    static func canElaborate(status: TaskStatus?, isBlocked: Bool) -> Bool {
        guard !isBlocked else { return false }
        return status == .pending
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
                markdownBody(section.body)
            }
        }
    }

    /// Renders a section body as markdown, one paragraph at a time. The body is
    /// split on blank lines; each paragraph is parsed with
    /// `AttributedString(markdown:)`, falling back to plain `Text` when parsing
    /// fails or yields nil. Performs no writes — purely presentational.
    @ViewBuilder
    private func markdownBody(_ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(BrowserViewModel.paragraphs(body).enumerated()), id: \.offset) { _, paragraph in
                markdownParagraph(paragraph)
            }
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
        .padding(20)
        .frame(minWidth: 480, minHeight: 360)
    }

    /// The verb for this run's mode ("Executing" / "Elaborating").
    private var modeVerb: String {
        switch run?.mode {
        case .elaborate: return "Elaborating"
        case .execute, .none: return "Executing"
        }
    }

    private var header: some View {
        HStack {
            Text(taskID.map { "\(modeVerb) task #\($0)" } ?? modeVerb)
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
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: lines.count) {
                if let last = lines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
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
