import SwiftUI

/// #110: a sheet hosting the WHOLE-PROJECT discussion — a read-only, multi-turn
/// conversation about everything in a project's `.plans/`, as opposed to the
/// per-plan discussion `PlanDetailView` hosts in the detail column. It mirrors
/// that view's discussion visuals (right-aligned question bubble, compact-markdown
/// reply, a live "Thinking…" row, "Cancelled" note, red error box, and a rounded
/// multi-line composer with a trailing return/stop glyph) but targets the
/// project thread the runner keys on an EMPTY task id (`askProject` /
/// `projectThread` / `cancelDiscussionTurn(..., taskID: "")`).
///
/// It is purely presentational: like `PlanDetailView`, it only READS the thread
/// off the runner and asks questions through it; the runner restricts the agent
/// to read tools, so no `.plans/` file is ever written. The conversation lives on
/// the runner's `DiscussionThread`, NOT on this view, so closing the sheet merely
/// dismisses it — an in-flight turn keeps running and the transcript is intact if
/// the sheet is reopened (it deliberately does NOT reset the thread). This mirrors
/// `PlanDetailView`'s "closing the detail doesn't stop the run" philosophy.
///
/// Like the detail column's transcript, nothing here measures its own size (#096):
/// the transcript uses a `ScrollViewReader` + `.frame(maxHeight: .infinity)` and
/// scrolls by id only. The sheet's fixed `.frame(minWidth:minHeight:)` is a
/// window size, not self-measurement.
struct ProjectDiscussionView: View {
    /// The project whose whole-project thread this sheet discusses. The thread is
    /// keyed on an empty task id for this path (`runner.projectThread`).
    let projectPath: String

    /// The project's display name, titling the conversation.
    let projectName: String

    /// Dismisses the sheet. Dismissal does NOT stop an in-flight turn or reset the
    /// thread — the conversation persists on the runner if reopened.
    @Environment(\.dismiss) private var dismiss

    /// The shared run coordinator, which owns the project `DiscussionThread` and
    /// drives `askProject` / `cancelDiscussionTurn`.
    @Environment(TaskRunner.self) private var runner

    /// The live text of the composer. Normalized by
    /// `PlanDetailView.discussSubmission(_:)` on send (empty / whitespace-only
    /// never fires) and cleared once the question is asked. Not persisted — the
    /// conversation itself lives on the runner's thread.
    @State private var text = ""

    var body: some View {
        let thread = runner.projectThread(projectPath: projectPath)
        let isBusy = thread?.isBusy ?? false
        VStack(spacing: 0) {
            header
            Divider()
            transcript(thread)
            Divider()
            composer(isBusy: isBusy)
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    /// The sheet header: the conversation title plus a Done button that dismisses
    /// the sheet. Closing does NOT stop an in-flight turn — the thread lives on the
    /// runner — so Done only dismisses (mirrors `PlanDetailView`'s "closing the
    /// detail doesn't stop the run" philosophy).
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Discuss \(projectName)")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The scrolling transcript. Before any question is asked the thread is `nil`
    /// (or empty), so a short muted empty state stands in for an empty list;
    /// otherwise each turn renders like `PlanDetailView`'s `discussionTurnView`.
    /// Scrolls by id to the newest turn as the conversation grows — nothing is
    /// measured (#096).
    @ViewBuilder
    private func transcript(_ thread: DiscussionThread?) -> some View {
        if let thread, PlanDetailView.showsConversationPanel(turnCount: thread.turns.count) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(thread.turns) { turn in
                            turnView(turn)
                                .id(turn.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .textSelection(.enabled)
                .frame(maxHeight: .infinity)
                .onAppear { scrollToLatest(thread, proxy: proxy) }
                .onChange(of: thread.turns.count) { scrollToLatest(thread, proxy: proxy) }
                .onChange(of: thread.turns.last?.reply) { scrollToLatest(thread, proxy: proxy) }
                .onChange(of: thread.turns.last?.isPending) { scrollToLatest(thread, proxy: proxy) }
            }
        } else {
            Text("Ask a question about this project's plans…")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One turn, mirroring `PlanDetailView.discussionTurnView`: a right-aligned
    /// neutral question bubble, the reply as compact markdown, a "Cancelled" note,
    /// a live "Thinking…" row with the latest tool activity, and a red error box.
    private func turnView(_ turn: DiscussionTurn) -> some View {
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
                // Compact-markdown reply. The detail column's block renderer is
                // private, so the reply uses SwiftUI's built-in markdown
                // (`Text(.init(_:))`) at the compact body size — the lightest
                // correct option the segment allows.
                Text(.init(reply))
                    .font(.system(size: MarkdownStyle.compact.bodySize))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    }

    /// The composer, styled like `PlanDetailView.discussFooter`: one rounded,
    /// filled, faint-bordered field holding a multi-line question (growing up to
    /// six lines via `lineLimit`, never measured — #096), disabled while a turn is
    /// pending, with a trailing return glyph that sends it — or, while a turn is
    /// pending, a stop glyph that cancels it. Return sends (`.onSubmit`).
    private func composer(isBusy: Bool) -> some View {
        let canSend = PlanDetailView.canSendDiscussion(text, isBusy: isBusy)
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this project's plans…", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(isBusy)
                .onSubmit { submit() }

            if PlanDetailView.composerShowsStop(isBusy: isBusy) {
                Button {
                    // The project thread is keyed on an empty task id, so cancel
                    // the pending turn with `taskID: ""`.
                    runner.cancelDiscussionTurn(projectPath: projectPath, taskID: "")
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button {
                    submit()
                } label: {
                    Image(systemName: "return")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
                .help("Send")
            }
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
    }

    /// Asks the composer's question in the project thread. Guards the send
    /// predicate (blank input or a pending turn never fires) and normalizes the
    /// text, then launches the project-scoped ask and clears the box. The turn
    /// renders inline in the transcript — discussion is read-only.
    private func submit() {
        let isBusy = runner.projectThread(projectPath: projectPath)?.isBusy ?? false
        guard PlanDetailView.canSendDiscussion(text, isBusy: isBusy),
              let question = PlanDetailView.discussSubmission(text) else { return }
        runner.askProject(projectPath: projectPath, question: question)
        text = ""
    }

    /// Scrolls the transcript so the newest turn's bottom edge is visible. Scrolls
    /// by id only — nothing is measured (#096).
    private func scrollToLatest(_ thread: DiscussionThread, proxy: ScrollViewProxy) {
        guard let target = PlanDetailView.discussionScrollTarget(for: thread.turns) else { return }
        withAnimation { proxy.scrollTo(target, anchor: .bottom) }
    }
}
