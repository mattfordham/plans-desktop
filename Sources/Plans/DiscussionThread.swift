import Foundation
import Observation

/// One question/answer exchange in a plan discussion.
struct DiscussionTurn: Identifiable, Equatable {
    let id: UUID
    /// The user's (trimmed) question.
    let question: String
    /// The agent's clean final answer (markdown), once it arrives.
    var reply: String?
    /// The latest tool activity, shown as a live status line while pending.
    var activity: String?
    /// A human-readable failure for this turn.
    var error: String?
    /// True from submission until the turn's run reports `done` or exits.
    var isPending: Bool
    /// True when this turn continued an earlier Agent SDK session.
    let isResumed: Bool
    /// True when the user stopped this turn before it answered.
    var isCancelled: Bool = false
}

/// A multi-turn, read-only conversation about one plan.
///
/// Owned by `TaskRunner` (keyed per project + task), not by the detail view, so
/// a turn's reply still lands when the user switches plans mid-turn. Each turn
/// is one `.discuss` `TaskRun`; continuity across turns comes from resuming the
/// Agent SDK session captured in `sessionID`.
@MainActor
@Observable
final class DiscussionThread {
    private(set) var turns: [DiscussionTurn] = []

    /// The session the next turn resumes, or `nil` to start a fresh one.
    private(set) var sessionID: String?

    /// The discuss process for the pending turn, held here rather than in
    /// `TaskRunner.runs` so it never reads as a task run (spinner, badge, quit
    /// alert).
    var activeRun: TaskRun?

    /// True while the last turn is waiting on the agent.
    var isBusy: Bool { turns.last?.isPending ?? false }

    /// Appends a pending turn for `question` and returns the session id that
    /// turn should resume (`nil` for a fresh conversation).
    @discardableResult
    func beginTurn(question: String) -> String? {
        let resume = sessionID
        turns.append(DiscussionTurn(id: UUID(), question: question, reply: nil,
                                    activity: nil, error: nil, isPending: true,
                                    isResumed: resume != nil))
        return resume
    }

    /// Folds one runner event into the last turn.
    func apply(_ event: RunEvent) {
        guard !turns.isEmpty else { return }
        let index = turns.count - 1
        switch event {
        case let .activity(tool, detail):
            if let detail, !detail.isEmpty {
                turns[index].activity = "\(tool) \(detail)"
            } else {
                turns[index].activity = tool
            }
        case let .session(id):
            sessionID = id
        case let .reply(text, id):
            turns[index].reply = text
            sessionID = id
        case let .error(message):
            setError(message, at: index)
        case let .done(_, _, stopReason):
            turns[index].isPending = false
            if turns[index].reply == nil,
               let stopReason,
               TaskRun.truncatingStopReasons.contains(stopReason) {
                setError("The agent hit its budget or turn cap before answering. Try a narrower question.",
                         at: index)
            }
        case .text, .denied, .captured, .question:
            // `.question` (#083) is a review-only event; a discussion never
            // produces one, so it is ignored here (present only to compile).
            break
        }
    }

    /// Finalizes the turn `id` when its process ends (any path). `error` is the
    /// run's own error, recorded only if the turn has neither an error nor a
    /// reply already — so a launch failure (no script / no node / crash) still
    /// surfaces, but a generic message never overrides a streamed one.
    func completeTurn(id: UUID, error: String?) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].isPending = false
        if let error, turns[index].error == nil, turns[index].reply == nil {
            setError(error, at: index)
        }
    }

    /// Stops waiting on the pending last turn and marks it cancelled, keeping
    /// earlier turns and the session so the next question still resumes. The
    /// caller terminates the process; dropping `activeRun` makes the runner's
    /// identity guard ignore its late events and finish.
    func cancelPendingTurn() {
        guard let index = turns.indices.last, turns[index].isPending else { return }
        turns[index].isPending = false
        turns[index].isCancelled = true
        turns[index].activity = nil
        activeRun = nil
    }

    /// Clears the conversation so the next question starts a fresh session.
    func reset() {
        turns = []
        sessionID = nil
        activeRun = nil
    }

    /// A failed resumed turn may mean the session is gone, so drop it and let
    /// the next ask start over rather than repeatedly resuming a dead session.
    private func setError(_ message: String, at index: Int) {
        turns[index].error = message
        if turns[index].isResumed {
            sessionID = nil
        }
    }
}
