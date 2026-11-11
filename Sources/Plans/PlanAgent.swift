import Foundation
import Observation

/// The single per-plan agent (#117). Exactly ONE `PlanAgent` exists per
/// `runKey` (owned by the shared `TaskRunner`), and every action a plan can
/// drive — an execute/elaborate/review/complete run, a discuss turn, an applying
/// discuss turn — passes through its one exclusive gate. A plan therefore has at
/// most one thing working on it at a time, so (since #114) a write-capable
/// `--apply` discuss turn can never collide with a live execute/elaborate run.
///
/// The agent has three parts:
/// - **An exclusive gate** (`state`): `idle` accepts a launch; `working(mode)`
///   and `needsInput` refuse every launch. `canStart` / `busyReason` are pure so
///   the gate and its tooltip copy are unit-testable.
/// - **A unified transcript** of `AgentSegment`s: each run is a `.run(TaskRun)`
///   segment, each discuss turn a `.turn(DiscussionTurn)` segment, in arrival
///   order. A finished segment stays in the transcript (the agent returns to
///   `idle`), so one continuous history accumulates across a capture → elaborate
///   → execute → review → discuss sequence.
/// - **Session lineage** (`lastSession`): the last run/turn's resumable session
///   plus the directory it ran in, generalising `resumableReviewSession`. The
///   composer resumes that session when it would run in the SAME directory, else
///   it starts a fresh discuss turn carrying the prior segment's summary as
///   context.
///
/// Turn bookkeeping (begin/apply/complete/cancel, session carry-over, review
/// context framing) is DELEGATED to an owned `DiscussionThread` rather than
/// re-implemented here — the smallest diff that keeps the already-tested turn
/// reducer in one place. The agent mirrors the thread's turns into `.turn`
/// segments so the dock renders one list.
@MainActor
@Observable
final class PlanAgent {
    /// The exclusive gate. A new agent is `idle`.
    enum AgentState: Equatable {
        /// Nothing is working this plan; a launch is accepted and the composer
        /// is enabled.
        case idle
        /// A run or discuss turn of `RunMode` is in flight; every launch is
        /// refused. `RunMode.activityVerb` names the activity for tooltip copy.
        case working(RunMode)
        /// An interactive run (guided review / complete) is parked on an
        /// `AskUserQuestion`; every launch is refused until the user answers.
        case needsInput
    }

    /// The current gate state. Observable so the dock's status pill updates.
    private(set) var state: AgentState = .idle

    /// The unified transcript, in arrival order. Each run appends a `.run`
    /// segment, each discuss turn a `.turn` segment that mirrors the owned
    /// thread's live turn.
    private(set) var transcript: [AgentSegment] = []

    /// The owned conversation model. The agent delegates all turn bookkeeping
    /// here (begin/apply/complete/cancel, session carry-over, review-context
    /// framing) and mirrors its turns into `.turn` segments.
    let thread = DiscussionThread()

    /// The most recent NON-discuss run segment (execute/elaborate/review/
    /// complete/capture), live or finished-but-not-dismissed. This is what the
    /// `TaskRunner.runs`-style accessors (`run(for:in:)`, snapshots) resolve.
    /// A discuss turn's `TaskRun` is held on `thread.activeRun`, never here, so
    /// it never reads as a task run. `nil` until the first run segment begins.
    private(set) var currentRun: TaskRun?

    /// The last resumable session and the directory it ran in (lineage). `nil`
    /// until a run/turn reports a session. Generalises `resumableReviewSession`:
    /// the composer resumes when it would run in the same directory, else it
    /// starts fresh with `summary` as context.
    private(set) var lastSession: LastSession?

    /// A resumable session paired with the directory it ran in and the segment's
    /// clean summary, so a composer in a DIFFERENT directory can carry the
    /// summary as context instead of resuming a session the CLI can't find there.
    struct LastSession: Equatable {
        let id: String?
        let cwd: String
        let summary: String?
    }

    init() {}

    // MARK: - Pure gate

    /// Whether a launch is accepted in `state`: only when `idle`. Pure so the
    /// gate is unit-testable without a live agent.
    static func canStart(state: AgentState) -> Bool {
        state == .idle
    }

    /// The tooltip copy for a disabled launch in `state`, or `nil` when idle
    /// (nothing to explain). Built from `RunMode.activityVerb` while working so
    /// the reason names the activity ("Agent is Executing — Stop to interrupt").
    static func busyReason(state: AgentState) -> String? {
        switch state {
        case .idle:
            return nil
        case let .working(mode):
            return "Agent is \(mode.activityVerb) — Stop to interrupt"
        case .needsInput:
            return "Agent is waiting for your answer"
        }
    }

    /// Instance convenience over `canStart(state:)`.
    var canStartNow: Bool { Self.canStart(state: state) }

    /// Instance convenience over `busyReason(state:)`.
    var busyReason: String? { Self.busyReason(state: state) }

    /// True while the agent is doing anything (working or waiting on an answer),
    /// so callers (quit guard, snapshots, `hasRunningRun`) count the agent as
    /// busy for every mode including discuss.
    var isBusy: Bool { state != .idle }

    // MARK: - Run segments

    /// Appends `run` as a `.run` segment and enters `working(run.mode)`, unless
    /// the gate refuses (not idle). Returns whether it was accepted. The caller
    /// starts the process after a `true`.
    @discardableResult
    func beginRunSegment(_ run: TaskRun) -> Bool {
        guard canStartNow else { return false }
        transcript.append(.run(run))
        currentRun = run
        state = .working(run.mode)
        return true
    }

    /// Re-reads `run`'s live state to keep the gate in sync while it is in
    /// flight: an interactive run that parked on an `AskUserQuestion` moves the
    /// agent to `needsInput`; once answered it returns to `working(mode)`. No-op
    /// once the agent is idle (the run finished).
    func syncStateFromRun(_ run: TaskRun) {
        guard isBusy else { return }
        if run.pendingQuestion != nil {
            state = .needsInput
        } else {
            state = .working(run.mode)
        }
    }

    /// Finalises a run segment: records its session/summary into lineage and
    /// returns the agent to `idle`. The segment stays in the transcript.
    func completeRunSegment(_ run: TaskRun) {
        recordLineage(sessionID: run.sessionID,
                      cwd: run.runProjectPath ?? "",
                      summary: run.reply)
        state = .idle
    }

    // MARK: - Discuss turns (delegated to the owned thread)

    /// Begins a discuss turn for `question` through the gate: appends a pending
    /// turn to the owned thread, mirrors it as a `.turn` segment, and enters
    /// `working(.discuss)`. Returns the session id the turn should resume (`nil`
    /// for a fresh conversation), or `nil` when the gate REFUSES — callers must
    /// distinguish refusal from "fresh turn" via the gate, so they check
    /// `canStartNow` first or observe the unchanged state. `apply` is accepted by
    /// the gate identically to a read-only turn; it only affects the launched
    /// `TaskRun`.
    @discardableResult
    func beginDiscussTurn(question: String, apply: Bool) -> String? {
        guard canStartNow else { return nil }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let resume = thread.beginTurn(question: trimmed)
        mirrorLastTurn()
        state = .working(.discuss)
        return resume
    }

    /// Folds one runner event into the owned thread's pending turn and re-mirrors
    /// it into the transcript. No-op once idle.
    func applyDiscussEvent(_ event: RunEvent) {
        guard isBusy else { return }
        thread.apply(event)
        mirrorLastTurn()
    }

    /// Finalises the pending discuss turn (any path): completes it on the thread,
    /// re-mirrors it, records lineage from the thread's session, and returns to
    /// `idle`.
    func completeDiscussTurn(error: String?) {
        guard let turnID = thread.turns.last?.id else {
            state = .idle
            return
        }
        thread.completeTurn(id: turnID, error: error)
        mirrorLastTurn()
        recordLineage(sessionID: thread.sessionID,
                      cwd: lastSession?.cwd ?? "",
                      summary: thread.turns.last?.reply)
        state = .idle
    }

    /// Cancels the pending discuss turn, keeping history and the session, and
    /// returns to `idle`. Mirrors the updated turn.
    func cancelDiscussTurn() {
        thread.cancelPendingTurn()
        mirrorLastTurn()
        state = .idle
    }

    /// Clears the agent's discuss history ("New conversation" for a thread whose
    /// turn was just terminated): drops every `.turn` segment, forgets lineage,
    /// and returns the agent to `idle`. The owned thread is reset by the caller.
    /// Run segments (execute/review logs) are kept — only the conversation is
    /// cleared, mirroring the pre-#117 `resetDiscussion` contract.
    func transcriptReset() {
        transcript.removeAll {
            if case .turn = $0 { return true }
            return false
        }
        lastSession = nil
        state = .idle
    }

    /// Mirrors the thread's last turn into the matching `.turn` segment (or
    /// appends a new one), so the transcript reflects the live turn. Turns carry
    /// stable UUIDs, so an existing segment is updated in place.
    private func mirrorLastTurn() {
        guard let turn = thread.turns.last else { return }
        if let index = transcript.lastIndex(where: {
            if case let .turn(existing) = $0 { return existing.id == turn.id }
            return false
        }) {
            transcript[index] = .turn(turn)
        } else {
            transcript.append(.turn(turn))
        }
    }

    // MARK: - Lineage

    /// Records the last run/turn's session, the directory it ran in, and its
    /// clean summary for the composer's resume-or-reframe decision. An empty
    /// session id is treated as none.
    func recordLineage(sessionID: String?, cwd: String, summary: String?) {
        let id = (sessionID?.isEmpty ?? true) ? nil : sessionID
        lastSession = LastSession(id: id, cwd: cwd, summary: summary)
    }

    /// The session a composer running in `cwd` may resume: the lineage session
    /// when it ran in the SAME directory, else `nil`. Mirrors
    /// `resumableReviewSession`'s per-directory rule.
    func resumeSession(forCwd cwd: String) -> String? {
        guard let last = lastSession, last.cwd == cwd else { return nil }
        return last.id
    }

    /// The context a FRESH turn in `cwd` should carry when the lineage session
    /// can't be resumed there (different directory, or no session): the prior
    /// segment's summary. `nil` when the session resumes in `cwd` (no extra
    /// context needed) or there is no summary.
    func contextForFreshTurn(cwd: String) -> String? {
        guard let last = lastSession else { return nil }
        if last.id != nil, last.cwd == cwd { return nil }
        return last.summary
    }

    // MARK: - Reset ("New conversation")

    /// Clears the transcript and lineage so the next turn starts a fresh
    /// conversation. Allowed ONLY while idle; returns whether it ran.
    @discardableResult
    func reset() -> Bool {
        guard canStartNow else { return false }
        transcript = []
        thread.reset()
        currentRun = nil
        lastSession = nil
        return true
    }

    /// Drops the finished run segment (e.g. the user dismissed its log / an
    /// errored capture's placeholder). No-op while the run is still in flight.
    /// Removes it from the transcript too so the dock doesn't keep rendering it.
    func dismissCurrentRun() {
        guard let run = currentRun, !run.isRunning else { return }
        transcript.removeAll {
            if case let .run(existing) = $0 { return existing === run }
            return false
        }
        currentRun = nil
    }

    /// The live discuss turn's run, if any (held on the owned thread). Exposed so
    /// the runner's stop/cancel paths can reach it uniformly through the agent.
    var activeDiscussRun: TaskRun? { thread.activeRun }

    #if DEBUG
    /// Test seam: forces the gate into `working(mode)` without launching a
    /// process, so the gate matrix is testable. DEBUG-only.
    func enterWorkingForTesting(_ mode: RunMode) {
        state = .working(mode)
    }

    /// Test seam: forces the gate into `needsInput` without a live run.
    /// DEBUG-only.
    func enterNeedsInputForTesting() {
        state = .needsInput
    }

    /// Test seam: adopts a pre-built `TaskRun` as this agent's current run
    /// segment WITHOUT going through the gate (mirrors the old
    /// `TaskRunner.ingestRunForTesting`, which inserted straight into `runs`).
    /// The gate reflects the run's live state: `working(mode)` while running,
    /// else `idle`. DEBUG-only.
    func adoptRunForTesting(_ run: TaskRun) {
        transcript.append(.run(run))
        currentRun = run
        state = run.isRunning ? .working(run.mode) : .idle
    }
    #endif
}

/// One entry in a `PlanAgent`'s unified transcript: either a `TaskRun`
/// (execute/elaborate/review/complete/capture) rendered as a collapsible run
/// log, or a `DiscussionTurn` rendered inline. Identifiable so the dock's list
/// has stable identity: a run segment keys on the run's object identity, a turn
/// segment on the turn's UUID.
enum AgentSegment: Identifiable {
    case run(TaskRun)
    case turn(DiscussionTurn)

    var id: String {
        switch self {
        case let .run(run):
            return "run:" + ObjectIdentifier(run).debugDescription
        case let .turn(turn):
            return "turn:" + turn.id.uuidString
        }
    }
}
