import XCTest
@testable import Plans

/// Tests for `PlanAgent` — the single per-plan agent (#117). It owns one
/// exclusive gate (idle | working | needsInput), one unified transcript of
/// segments (runs and discuss turns), and session lineage. The turn logic is
/// delegated to an owned `DiscussionThread`, so the first third of this file
/// ports `DiscussionThreadTests`' turn-model/event-folding cases to prove the
/// absorbed behaviour stays covered through the agent's surface.
@MainActor
final class PlanAgentTests: XCTestCase {

    // MARK: - Gate: pure canStart / busyReason

    func testCanStartWhenIdle() {
        XCTAssertTrue(PlanAgent.canStart(state: .idle))
    }

    func testCannotStartWhileWorking() {
        XCTAssertFalse(PlanAgent.canStart(state: .working(.execute)))
        XCTAssertFalse(PlanAgent.canStart(state: .working(.discuss)))
    }

    func testCannotStartWhileNeedsInput() {
        XCTAssertFalse(PlanAgent.canStart(state: .needsInput))
    }

    func testBusyReasonIsNilWhenIdle() {
        XCTAssertNil(PlanAgent.busyReason(state: .idle))
    }

    func testBusyReasonUsesActivityVerbWhileWorking() {
        let reason = PlanAgent.busyReason(state: .working(.execute))
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains(RunMode.execute.activityVerb))
    }

    func testBusyReasonForDiscussUsesActivityVerb() {
        let reason = PlanAgent.busyReason(state: .working(.discuss))
        XCTAssertTrue(reason!.contains(RunMode.discuss.activityVerb))
    }

    func testBusyReasonWhenNeedsInputNamesAnswer() {
        let reason = PlanAgent.busyReason(state: .needsInput)
        XCTAssertNotNil(reason)
    }

    // MARK: - Gate matrix on a live agent

    func testNewAgentIsIdleAndEmpty() {
        let agent = PlanAgent()
        XCTAssertEqual(agent.state, .idle)
        XCTAssertTrue(agent.transcript.isEmpty)
        XCTAssertTrue(agent.canStartNow)
    }

    /// Execute refuses discuss/apply and any second run while working.
    func testWorkingExecuteRefusesEverything() {
        let agent = PlanAgent()
        agent.enterWorkingForTesting(.execute)
        XCTAssertFalse(agent.canStartNow)
        XCTAssertFalse(agent.beginRunSegment(TaskRun(taskID: "7", mode: .elaborate)))
        XCTAssertFalse(agent.beginDiscussTurn(question: "why?", apply: false) != nil)
        XCTAssertFalse(agent.beginDiscussTurn(question: "fix it", apply: true) != nil)
    }

    /// A discuss/apply turn refuses a run (and a second discuss) while working.
    /// A fresh discuss turn returns `nil` (no session to resume) on SUCCESS, so
    /// acceptance is read from the gate state, not the return value.
    func testWorkingDiscussRefusesRuns() {
        let agent = PlanAgent()
        _ = agent.beginDiscussTurn(question: "why?", apply: false)
        XCTAssertEqual(agent.state, .working(.discuss))
        XCTAssertFalse(agent.beginRunSegment(TaskRun(taskID: "7", mode: .execute)))
        XCTAssertFalse(agent.canStartNow)
        XCTAssertEqual(agent.transcript.count, 1, "a refused second turn is not appended")
    }

    /// review/complete `needsInput` refuses everything.
    func testNeedsInputRefusesEverything() {
        let agent = PlanAgent()
        agent.enterNeedsInputForTesting()
        XCTAssertFalse(agent.canStartNow)
        XCTAssertFalse(agent.beginRunSegment(TaskRun(taskID: "7", mode: .execute)))
        XCTAssertNil(agent.beginDiscussTurn(question: "q", apply: false))
    }

    func testBeginRunSegmentAppendsSegmentAndWorks() {
        let agent = PlanAgent()
        let run = TaskRun(taskID: "7", mode: .execute)
        XCTAssertTrue(agent.beginRunSegment(run))
        XCTAssertEqual(agent.state, .working(.execute))
        XCTAssertEqual(agent.transcript.count, 1)
        if case let .run(segmentRun) = agent.transcript[0] {
            XCTAssertTrue(segmentRun === run)
        } else {
            XCTFail("expected a run segment")
        }
    }

    /// A run that finishes returns the agent to idle and leaves its segment in
    /// the transcript.
    func testFinishedRunReturnsToIdleAndKeepsSegment() {
        let agent = PlanAgent()
        let run = TaskRun(taskID: "7", mode: .execute)
        _ = agent.beginRunSegment(run)
        agent.completeRunSegment(run)
        XCTAssertEqual(agent.state, .idle)
        XCTAssertEqual(agent.transcript.count, 1)
        XCTAssertTrue(agent.canStartNow)
    }

    // MARK: - Discuss turns via the owned thread (segment ported from DiscussionThreadTests)

    func testBeginDiscussTurnAppendsPendingTurnAndWorks() {
        let agent = PlanAgent()
        let resume = agent.beginDiscussTurn(question: "Why this approach?", apply: false)
        XCTAssertNil(resume)
        XCTAssertEqual(agent.state, .working(.discuss))
        XCTAssertEqual(agent.transcript.count, 1)
        guard case let .turn(turn) = agent.transcript[0] else {
            return XCTFail("expected a turn segment")
        }
        XCTAssertEqual(turn.question, "Why this approach?")
        XCTAssertTrue(turn.isPending)
    }

    func testDiscussTurnFoldsEventsAndReturnsToIdle() {
        let agent = PlanAgent()
        _ = agent.beginDiscussTurn(question: "q", apply: false)
        agent.applyDiscussEvent(.activity(tool: "Read", detail: "plan.md"))
        agent.applyDiscussEvent(.session(id: "s1"))
        agent.applyDiscussEvent(.reply(text: "Because **reasons**.", sessionID: "s2"))
        agent.applyDiscussEvent(.done(costUsd: 0.1, turns: 1, stopReason: "end_turn"))
        guard case let .turn(turn) = agent.transcript.last else {
            return XCTFail("expected a turn segment")
        }
        XCTAssertEqual(turn.reply, "Because **reasons**.")
        XCTAssertFalse(turn.isPending)
        agent.completeDiscussTurn(error: nil)
        XCTAssertEqual(agent.state, .idle)
    }

    func testDiscussSecondTurnResumesSession() {
        let agent = PlanAgent()
        _ = agent.beginDiscussTurn(question: "q1", apply: false)
        agent.applyDiscussEvent(.reply(text: "a", sessionID: "sess-1"))
        agent.applyDiscussEvent(.done(costUsd: 0, turns: 1, stopReason: "end_turn"))
        agent.completeDiscussTurn(error: nil)
        let resume = agent.beginDiscussTurn(question: "q2", apply: false)
        XCTAssertEqual(resume, "sess-1")
    }

    func testCompleteDiscussTurnRecordsRunErrorOnlyWhenTurnHasNone() {
        let agent = PlanAgent()
        _ = agent.beginDiscussTurn(question: "q", apply: false)
        agent.completeDiscussTurn(error: "Bundled work-task script (run-task.js) not found.")
        guard case let .turn(turn) = agent.transcript.last else {
            return XCTFail("expected a turn segment")
        }
        XCTAssertEqual(turn.error, "Bundled work-task script (run-task.js) not found.")
        XCTAssertFalse(turn.isPending)
    }

    func testCancelDiscussTurnKeepsHistoryAndSessionAndIdles() {
        let agent = PlanAgent()
        _ = agent.beginDiscussTurn(question: "q1", apply: false)
        agent.applyDiscussEvent(.reply(text: "a1", sessionID: "s1"))
        agent.applyDiscussEvent(.done(costUsd: 0.1, turns: 1, stopReason: "end_turn"))
        agent.completeDiscussTurn(error: nil)
        _ = agent.beginDiscussTurn(question: "q2", apply: false)
        agent.cancelDiscussTurn()
        XCTAssertEqual(agent.state, .idle)
        XCTAssertEqual(agent.transcript.count, 2)
        guard case let .turn(turn) = agent.transcript.last else {
            return XCTFail("expected a turn segment")
        }
        XCTAssertTrue(turn.isCancelled)
        XCTAssertEqual(agent.beginDiscussTurn(question: "q3", apply: false), "s1")
    }

    // MARK: - Lineage

    /// After a run in `cwd`, a composer in the SAME cwd resumes that run's
    /// session; a different cwd starts fresh and carries the prior reply as
    /// context.
    func testLineageResumesWhenSameCwd() {
        let agent = PlanAgent()
        agent.recordLineage(sessionID: "run-sess", cwd: "/proj", summary: "did the thing")
        XCTAssertEqual(agent.resumeSession(forCwd: "/proj"), "run-sess")
        XCTAssertNil(agent.contextForFreshTurn(cwd: "/proj"))
    }

    func testLineageStartsFreshWithContextWhenDifferentCwd() {
        let agent = PlanAgent()
        agent.recordLineage(sessionID: "run-sess", cwd: "/worktree", summary: "did the thing")
        XCTAssertNil(agent.resumeSession(forCwd: "/proj"))
        XCTAssertEqual(agent.contextForFreshTurn(cwd: "/proj"), "did the thing")
    }

    func testLineageNoSessionCarriesContext() {
        let agent = PlanAgent()
        agent.recordLineage(sessionID: nil, cwd: "/proj", summary: "summary")
        XCTAssertNil(agent.resumeSession(forCwd: "/proj"))
        XCTAssertEqual(agent.contextForFreshTurn(cwd: "/proj"), "summary")
    }

    // MARK: - Reset ("New conversation")

    func testResetClearsTranscriptAndLineageWhenIdle() {
        let agent = PlanAgent()
        _ = agent.beginDiscussTurn(question: "q", apply: false)
        agent.applyDiscussEvent(.reply(text: "a", sessionID: "s1"))
        agent.applyDiscussEvent(.done(costUsd: 0, turns: 1, stopReason: "end_turn"))
        agent.completeDiscussTurn(error: nil)
        agent.recordLineage(sessionID: "s1", cwd: "/proj", summary: "x")
        XCTAssertTrue(agent.reset())
        XCTAssertTrue(agent.transcript.isEmpty)
        XCTAssertNil(agent.resumeSession(forCwd: "/proj"))
        XCTAssertEqual(agent.state, .idle)
    }

    func testResetRefusedWhileWorking() {
        let agent = PlanAgent()
        _ = agent.beginRunSegment(TaskRun(taskID: "7", mode: .execute))
        XCTAssertFalse(agent.reset())
        XCTAssertEqual(agent.transcript.count, 1)
    }

    // MARK: - needsInput wiring from a run segment's pending question

    func testRunSegmentWithPendingQuestionEntersNeedsInput() {
        let agent = PlanAgent()
        let run = TaskRun(taskID: "7", mode: .review)
        _ = agent.beginRunSegment(run)
        run.ingestForTesting(#"{"kind":"question","toolUseId":"t1","questions":[{"question":"Approve?","header":"h","options":[{"label":"Yes"}]}]}"# + "\n")
        agent.syncStateFromRun(run)
        XCTAssertEqual(agent.state, .needsInput)
        run.ingestForTesting(#"{"kind":"reply","text":"done","sessionId":"s"}"# + "\n")
        agent.completeRunSegment(run)
        XCTAssertEqual(agent.state, .idle)
    }
}
