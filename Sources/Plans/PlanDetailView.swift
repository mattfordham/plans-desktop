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

    /// The shared "Work this task" runner, injected by the plan-detail scene.
    /// Drives the "Work this task" button's enabled state and the progress sheet.
    @Environment(TaskRunner.self) private var runner

    /// The resolved row for `rowID` across all projects' active rows, or `nil`
    /// when absent. Re-derived from the live store on each render.
    private var row: TaskRow? {
        guard let rowID else { return nil }
        return BrowserViewModel.resolveRow(in: store.projects, id: rowID)
    }

    var body: some View {
        // `isRunning` is `private(set)` on the runner, so a custom read-only-ish
        // binding drives the sheet: it reads `isRunning` (the sheet auto-dismisses
        // when the run ends and the flag flips false) and ignores set-to-true.
        // Dismissing the sheet must NOT stop the run, so the setter is a no-op —
        // the run only ends via the runner itself (completion or the Stop button).
        let runPresented = Binding(
            get: { runner.isRunning },
            set: { _ in }
        )
        return Group {
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
        // The modal progress sheet, presented for the lifetime of a run. Bound
        // to `isRunning` so it auto-dismisses when the run finishes; `onDisappear`
        // reloads the store so the task's new `review` status is surfaced by the
        // existing read path.
        .sheet(isPresented: runPresented) {
            RunProgressSheet(taskID: row?.task.id)
                .onDisappear { store.reload() }
        }
        // Window-close cleanup: if this detail window closes while a run is in
        // flight, terminate the child process cleanly rather than orphaning it.
        // See the assumption note re: the shared-runner limitation.
        .onDisappear {
            if runner.isRunning { runner.stop() }
        }
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

            // "Work this task" — hands the plan off to the bundled Agent-SDK
            // runner. Enabled only for an elaborated/in-progress, non-blocked
            // task, and never while a run is already in flight.
            Button {
                runner.run(projectPath: row.projectPath, taskID: row.task.id)
            } label: {
                Label("Work this task", systemImage: "play.fill")
            }
            .disabled(!Self.canWork(status: row.task.status,
                                    isBlocked: row.task.isBlocked,
                                    isRunning: runner.isRunning))
            .padding(.top, 4)
        }
    }

    /// Pure predicate for the "Work this task" button's enabled state, so the
    /// gating rule is unit-testable independent of the view. The button is
    /// enabled only for an elaborated or in-progress task that is not blocked,
    /// and only while no run is already in flight.
    static func canWork(status: TaskStatus?, isBlocked: Bool, isRunning: Bool) -> Bool {
        guard !isRunning, !isBlocked else { return false }
        return status == .elaborated || status == .inProgress
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

/// The modal progress sheet shown for the lifetime of a "Work this task" run.
/// Renders the bundled runner's live NDJSON stream: a scrolling activity/text
/// log, a cost/turns summary once the run reports `done`, an error banner on a
/// streamed/terminal error, and a Stop button wired to `runner.stop()`. The
/// sheet itself is presented via `.sheet(isPresented: $runner.isRunning)`, so
/// it auto-dismisses when the run ends; a Done button is offered once it is no
/// longer running so the user can dismiss a finished run explicitly.
private struct RunProgressSheet: View {
    /// The task id being worked, for the header (e.g. "Working task #019").
    let taskID: String?

    @Environment(TaskRunner.self) private var runner
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let error = runner.error {
                errorBanner(error)
            }

            logList

            if let summary = runner.summary {
                summaryRow(summary)
            }

            footer
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 360)
    }

    private var header: some View {
        HStack {
            Text(taskID.map { "Working task #\($0)" } ?? "Working task")
                .font(.headline)
            if runner.isRunning {
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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(runner.lines) { logged in
                        lineView(logged.event)
                            .id(logged.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: runner.lines.count) {
                if let last = runner.lines.last {
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
            if runner.isRunning {
                Button(role: .destructive) {
                    runner.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
