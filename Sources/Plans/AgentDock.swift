import SwiftUI
import AppKit

/// The persistent per-plan agent dock (#117): an always-present bottom panel in
/// the plan-detail column that REPLACES the former top progress drawer, the
/// review / finished-review panels, and the stand-alone Discuss composer with
/// ONE surface driven by the plan's single `PlanAgent`.
///
/// Three bands, top to bottom:
/// - **Header** — a status pill (Idle / `activityVerb`… / Needs your answer) plus
///   Stop (while the agent is working) and New conversation (while idle).
/// - **Transcript** — the agent's unified `[AgentSegment]` list in arrival order:
///   a run segment as a collapsible `RunLogContents` (edge-to-edge), a discuss
///   turn via the shared `AgentTurnView`, and a finished guided review's
///   follow-up actions (Discuss with Reviewer / Complete…) on its own segment.
/// - **Footer** — chosen by the pure `dockFooterMode(state:canDiscuss:)`: the
///   composer when idle, a disabled "Agent is <verb> — Stop to interrupt" band
///   while working, and the `ParkedQuestionForm` when the agent needs an answer.
///
/// No measured sizes (#096): the dock reuses the `maxHeight: .infinity` split and
/// the `ViewThatFits` question-card layout — nothing here measures its own size.
struct AgentDock: View {
    /// The row whose agent this dock surfaces, or `nil` for a synthetic capture
    /// placeholder (no backing plan yet).
    let row: TaskRow?

    /// The capture run backing a "Capturing…" placeholder dock, when `row` is
    /// `nil` — so the placeholder can host its log and a Dismiss for an errored
    /// capture. `nil` for a real plan.
    var captureRun: TaskRun? = nil

    @Environment(PlansStore.self) private var store
    @Environment(TaskRunner.self) private var runner

    /// The live text of the discussion composer. Cleared once a turn is asked.
    @State private var discussText = ""

    /// Which transcript run segments are collapsed, by segment id. A run segment
    /// is expanded by default; the user can collapse it. Keyed by the stable
    /// `AgentSegment.id` so collapse state survives re-renders.
    @State private var collapsedRuns: Set<String> = []

    // MARK: - Footer mode (pure)

    /// The three footer presentations of the dock.
    enum DockFooterMode: Equatable {
        /// The idle composer (ask / apply).
        case composer
        /// The disabled "Agent is <verb> — Stop to interrupt" band while working.
        case disabled
        /// The `ParkedQuestionForm` for a needs-input interactive run.
        case question
        /// Nothing (an idle plan that can't be discussed — blocked / backlogged).
        case none
    }

    /// The footer the dock shows for the agent `state` and whether the plan can
    /// be discussed. Pure so the swap is unit-testable without the view:
    /// - `working(_)` → `.disabled` (Stop interrupts), regardless of `canDiscuss`;
    /// - `needsInput` → `.question` (answer the parked question);
    /// - `idle` → `.composer` when the plan can be discussed, else `.none`.
    static func dockFooterMode(state: PlanAgent.AgentState, canDiscuss: Bool) -> DockFooterMode {
        switch state {
        case .working:
            return .disabled
        case .needsInput:
            return .question
        case .idle:
            return canDiscuss ? .composer : .none
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            footer
        }
        .frame(maxHeight: .infinity)
        .background(.bar)
    }

    /// The agent backing this dock: a real plan's agent, or the capture's agent
    /// for a placeholder. `nil` only transiently before either exists.
    private var agent: PlanAgent? {
        if let row {
            return runner.agent(for: row.task.id, in: row.projectPath)
        }
        if let captureRun {
            return runner.agent(for: captureRun.taskID, in: captureRun.runProjectPath ?? "")
        }
        return nil
    }

    private var agentState: PlanAgent.AgentState {
        agent?.state ?? .idle
    }

    private var canDiscuss: Bool {
        guard let row else { return false }
        return PlanDetailView.canDiscuss(status: row.task.status,
                                         isBlocked: row.task.isBlocked,
                                         isBacklogged: row.task.isBacklogged)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            statusPill
            Spacer(minLength: 8)
            switch agentState {
            case .working, .needsInput:
                Button(role: .destructive) {
                    stopAgent()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .controlSize(.small)
            case .idle:
                Button {
                    runner.resetDiscussion(projectPath: rowProjectPath, taskID: rowTaskID)
                } label: {
                    Label("New conversation", systemImage: "square.and.pencil")
                }
                .controlSize(.small)
                .disabled(row == nil)
                .help("Clear the conversation with this plan's agent")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Idle / `activityVerb`… / Needs your answer, tinted by state.
    private var statusPill: some View {
        let (label, color, spinner): (String, Color, Bool) = {
            switch agentState {
            case .idle:
                return ("Idle", .secondary, false)
            case let .working(mode):
                return ("\(mode.activityVerb)…", TaskStatus.inProgress.glanceColor, true)
            case .needsInput:
                return ("Needs your answer", .orange, false)
            }
        }()
        return HStack(spacing: 6) {
            if spinner {
                ProgressView().controlSize(.small)
            }
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(color)
        }
    }

    private var rowProjectPath: String { row?.projectPath ?? captureRun?.runProjectPath ?? "" }
    private var rowTaskID: String { row?.task.id ?? captureRun?.taskID ?? "" }

    /// Stops whatever the agent is doing: the live run segment, or a live discuss
    /// turn, whichever is in flight.
    private func stopAgent() {
        if let run = runner.run(for: rowTaskID, in: rowProjectPath), run.isRunning {
            run.stop()
        } else {
            runner.cancelDiscussionTurn(projectPath: rowProjectPath, taskID: rowTaskID)
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        let segments = agent?.transcript ?? []
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(segments) { segment in
                        segmentView(segment)
                            .id(segment.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            }
            .textSelection(.enabled)
            .onChange(of: segments.count) {
                if let last = segments.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: AgentSegment) -> some View {
        switch segment {
        case let .run(run):
            runSegment(segment.id, run: run)
        case let .turn(turn):
            AgentTurnView(turn: turn)
                .padding(.horizontal, 16)
        }
    }

    /// A run segment: a tappable disclosure header (mode-aware title + spinner)
    /// over the edge-to-edge `RunLogContents`, plus — once a guided review has
    /// finished cleanly — its follow-up actions.
    @ViewBuilder
    private func runSegment(_ id: String, run: TaskRun) -> some View {
        let collapsed = collapsedRuns.contains(id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if collapsed { collapsedRuns.remove(id) } else { collapsedRuns.insert(id) }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(PlanDetailView.progressDrawerTitle(mode: run.mode, taskID: runTaskID(run)))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    if run.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed {
                RunLogContents(run: run, edgeToEdge: true,
                               horizontalPadding: 16, topPadding: 8)
                    .frame(maxWidth: .infinity, maxHeight: 360)
            }

            if let row, PlanDetailView.finishedReviewRun(run) != nil {
                finishedReviewActions(row, run: run)
            }
        }
    }

    /// A run segment's task id for the title, suppressing the synthetic capture
    /// identity (so a capture shows just its verb).
    private func runTaskID(_ run: TaskRun) -> String? {
        TaskRunner.isSyntheticCaptureID(run.taskID) ? nil : run.taskID
    }

    /// The follow-up actions on a finished guided review (#083, now in the dock):
    /// Discuss with Reviewer and Complete… (behind the explicit confirmation).
    @ViewBuilder
    private func finishedReviewActions(_ row: TaskRow, run: TaskRun) -> some View {
        let canCompleteNow = PlanDetailView.canComplete(status: row.task.status,
                                                        branch: row.task.branch,
                                                        isBlocked: row.task.isBlocked,
                                                        isBacklogged: row.task.isBacklogged,
                                                        hasLiveRun: run.isRunning)
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if canDiscuss {
                Button {
                    runner.continueReviewInDiscussion(projectPath: row.projectPath,
                                                      taskID: row.task.id)
                } label: {
                    Label("Discuss with Reviewer", systemImage: "bubble.left.and.bubble.right")
                }
                .help("Continue the conversation with the reviewing agent")
            }
            if canCompleteNow, let branch = row.task.branch {
                Button {
                    if PlanDetailView.confirmComplete(taskID: row.task.id, title: row.title,
                                                      branch: branch) {
                        runner.complete(projectPath: row.projectPath, taskID: row.task.id)
                    }
                } label: {
                    Label("Complete…", systemImage: "checkmark.seal")
                }
                .buttonStyle(.borderedProminent)
                .help("Merge the branch and archive this plan")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        let mode = Self.dockFooterMode(state: agentState, canDiscuss: canDiscuss)
        switch mode {
        case .composer:
            Divider()
            composer
        case .disabled:
            Divider()
            disabledFooter
        case .question:
            if let run = runner.run(for: rowTaskID, in: rowProjectPath),
               let pending = run.pendingQuestion {
                Divider()
                ViewThatFits(in: .vertical) {
                    questionForm(run: run, pending: pending)
                    ScrollView {
                        questionForm(run: run, pending: pending)
                    }
                }
                .layoutPriority(1)
            } else if captureRun != nil {
                // A placeholder capture that errored: offer Dismiss.
                Divider()
                captureDismissFooter
            }
        case .none:
            if captureRun != nil {
                Divider()
                captureDismissFooter
            }
        }
    }

    private func questionForm(run: TaskRun, pending: TaskRun.PendingReviewQuestion) -> some View {
        ParkedQuestionForm(pending: pending) { answers in
            run.answer(toolUseId: pending.toolUseId, answers: answers)
        }
        .id(pending.toolUseId)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The disabled band shown while the agent works: "Agent is <verb> — Stop to
    /// interrupt" copy from the agent's pure `busyReason`.
    private var disabledFooter: some View {
        HStack(spacing: 8) {
            Text(agent?.busyReason ?? "Agent is working — Stop to interrupt")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Dismiss for an errored capture placeholder dock.
    private var captureDismissFooter: some View {
        HStack(spacing: 8) {
            if let captureRun, !captureRun.isRunning, captureRun.error != nil {
                Text(captureRun.error ?? "Capture failed")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Dismiss") {
                if let captureRun {
                    runner.dismiss(taskID: captureRun.taskID,
                                   in: captureRun.runProjectPath ?? "")
                    store.reload()
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Composer (ask / apply)

    private var composer: some View {
        guard let row else { return AnyView(EmptyView()) }
        let isBusy = !(agent?.canStartNow ?? true)
        let canSend = PlanDetailView.canSendDiscussion(discussText, isBusy: isBusy)
        let canApply = PlanDetailView.canApplyViaDiscussion(status: row.task.status,
                                                           isBlocked: row.task.isBlocked,
                                                           isBacklogged: row.task.isBacklogged)
        return AnyView(
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about this plan…", text: $discussText, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(isBusy)
                    .onSubmit { submit(row) }

                if canApply {
                    Button {
                        submitApply(row)
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.4)
                    .help("Apply changes to this plan")
                }

                Button {
                    submit(row)
                } label: {
                    Image(systemName: "return")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
                .help("Send")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        )
    }

    private func submit(_ row: TaskRow) {
        guard PlanDetailView.canDiscuss(status: row.task.status,
                                        isBlocked: row.task.isBlocked,
                                        isBacklogged: row.task.isBacklogged) else { return }
        let isBusy = !(agent?.canStartNow ?? true)
        guard PlanDetailView.canSendDiscussion(discussText, isBusy: isBusy),
              let text = PlanDetailView.discussSubmission(discussText) else { return }
        runner.ask(projectPath: row.projectPath, taskID: row.task.id, question: text)
        discussText = ""
    }

    private func submitApply(_ row: TaskRow) {
        guard PlanDetailView.canApplyViaDiscussion(status: row.task.status,
                                                   isBlocked: row.task.isBlocked,
                                                   isBacklogged: row.task.isBacklogged) else { return }
        let isBusy = !(agent?.canStartNow ?? true)
        guard PlanDetailView.canSendDiscussion(discussText, isBusy: isBusy),
              let text = PlanDetailView.discussSubmission(discussText) else { return }
        runner.ask(projectPath: row.projectPath, taskID: row.task.id, question: text,
                   apply: true, onApplied: { [store] in store.reload() })
        discussText = ""
    }
}

/// One discuss turn rendered in the dock transcript: the question as a
/// right-aligned bubble, the reply as compact markdown, a "Thinking…" row while
/// pending, a "Cancelled" note, and any error. Extracted from the former
/// `PlanDetailView.discussionTurnView` so the dock and detail share one layout.
struct AgentTurnView: View {
    let turn: DiscussionTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 60)
                Text(turn.question)
                    .font(.system(size: MarkdownStyle.compact.bodySize))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.12))
                    )
            }

            if let reply = turn.reply {
                MarkdownBlockView(body: reply, style: .compact)
            }

            if turn.isCancelled {
                Text("Cancelled")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if turn.isPending {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…")
                        .foregroundStyle(.secondary)
                    if let activity = turn.activity {
                        Text(activity)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.callout)
            }

            if let error = turn.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.red.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
