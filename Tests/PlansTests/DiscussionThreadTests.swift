import XCTest
@testable import Plans

/// Tests for `DiscussionThread` — the per-plan conversation model — and the
/// `TaskRunner` bookkeeping that owns it. The reducer is pure; the runner tests
/// replace process launching with a capturing seam so no `node` is spawned.
@MainActor
final class DiscussionThreadTests: XCTestCase {

    // MARK: - Turn bookkeeping

    func testNewThreadIsEmptyAndIdle() {
        let thread = DiscussionThread()
        XCTAssertTrue(thread.turns.isEmpty)
        XCTAssertNil(thread.sessionID)
        XCTAssertFalse(thread.isBusy)
    }

    func testBeginTurnAppendsPendingTurnAndMarksBusy() {
        let thread = DiscussionThread()
        thread.beginTurn(question: "Why this approach?")
        XCTAssertEqual(thread.turns.count, 1)
        let turn = thread.turns[0]
        XCTAssertEqual(turn.question, "Why this approach?")
        XCTAssertNil(turn.reply)
        XCTAssertNil(turn.activity)
        XCTAssertNil(turn.error)
        XCTAssertTrue(turn.isPending)
        XCTAssertTrue(thread.isBusy)
    }

    func testBeginTurnReturnsCurrentSessionAsResume() {
        let thread = DiscussionThread()
        XCTAssertNil(thread.beginTurn(question: "first"))
        thread.apply(.session(id: "abc"))
        thread.apply(.done(costUsd: 0.1, turns: 1, stopReason: "end_turn"))
        XCTAssertEqual(thread.beginTurn(question: "second"), "abc")
    }

    // MARK: - Reducer

    func testActivityUpdatesLiveStatusLineOfLastTurn() {
        let thread = DiscussionThread()
        thread.beginTurn(question: "q")
        thread.apply(.activity(tool: "Read", detail: "plan.md"))
        XCTAssertEqual(thread.turns.last?.activity, "Read plan.md")
        thread.apply(.activity(tool: "Grep", detail: nil))
        XCTAssertEqual(thread.turns.last?.activity, "Grep")
    }

    func testSessionEventSetsSessionID() {
        let thread = DiscussionThread()
        thread.beginTurn(question: "q")
        thread.apply(.session(id: "s1"))
        XCTAssertEqual(thread.sessionID, "s1")
    }

    func testReplySetsReplyAndSessionID() {
        let thread = DiscussionThread()
        thread.beginTurn(question: "q")
        thread.apply(.session(id: "s1"))
        thread.apply(.reply(text: "Because **reasons**.", sessionID: "s2"))
        XCTAssertEqual(thread.turns.last?.reply, "Because **reasons**.")
        XCTAssertEqual(thread.sessionID, "s2")
        XCTAssertNil(thread.turns.last?.error)
    }

    func testTextChunksAreNotTreatedAsTheReply() {
        let thread = DiscussionThread()
        thread.beginTurn(question: "q")
        thread.apply(.text(chunk: "Let me look at the plan…"))
        XCTAssertNil(thread.turns.last?.reply)
    }

    func testDoneClearsPending() {
        let thread = DiscussionThread()
        thread.beginTurn(question: "q")
        thread.apply(.reply(text: "a", sessionID: "s"))
        thread.apply(.done(costUsd: 0.2, turns: 2, stopReason: "end_turn"))
        XCTAssertEqual(thread.turns.last?.isPending, false)
        XCTAssertFalse(thread.isBusy)
    }

    func testErrorOnFirstTurnSetsErrorAndKeepsSession() {
        let thread = DiscussionThread()
        thread.beginTurn(question: "q")
        thread.apply(.session(id: "s1"))
        thread.apply(.error(message: "boom"))
        XCTAssertEqual(thread.turns.last?.error, "boom")
        XCTAssertEqual(thread.sessionID, "s1")
    }

    func testErrorOnResumedTurnClearsSessionSoNextAskStartsFresh() {
        let thread = DiscussionThread()
        thread.beginTurn(question: "q1")
        thread.apply(.session(id: "s1"))
        thread.apply(.done(costUsd: 0, turns: 1, stopReason: "end_turn"))
        thread.beginTurn(question: "q2")
        thread.apply(.error(message: "No conversation found with session ID s1"))
        XCTAssertEqual(thread.turns.last?.error, "No conversation found with session ID s1")
        XCTAssertNil(thread.sessionID)
        XCTAssertNil(thread.beginTurn(question: "q3"))
    }

    func testTruncatedDoneWithoutReplySurfacesTurnError() {
        let thread = DiscussionThread()
        thread.beginTurn(question: "q")
        thread.apply(.done(costUsd: 5, turns: 40, stopReason: "error_max_budget_usd"))
        XCTAssertNotNil(thread.turns.last?.error)
        XCTAssertEqual(thread.turns.last?.isPending, false)
    }

    func testEventsWithNoTurnAreIgnored() {
        let thread = DiscussionThread()
        thread.apply(.reply(text: "stray", sessionID: "s"))
        XCTAssertTrue(thread.turns.isEmpty)
    }

    func testCompleteTurnRecordsRunErrorOnlyWhenTurnHasNone() {
        let thread = DiscussionThread()
        thread.beginTurn(question: "q")
        let id = thread.turns[0].id
        thread.completeTurn(id: id, error: "Bundled work-task script (run-task.js) not found.")
        XCTAssertEqual(thread.turns[0].error, "Bundled work-task script (run-task.js) not found.")
        XCTAssertFalse(thread.turns[0].isPending)

        thread.beginTurn(question: "q2")
        let id2 = thread.turns[1].id
        thread.apply(.error(message: "streamed"))
        thread.completeTurn(id: id2, error: "generic")
        XCTAssertEqual(thread.turns[1].error, "streamed")
    }

    func testCompleteTurnWithReplyIgnoresRunError() {
        let thread = DiscussionThread()
        thread.beginTurn(question: "q")
        let id = thread.turns[0].id
        thread.apply(.reply(text: "answer", sessionID: "s"))
        thread.completeTurn(id: id, error: "Run cut short")
        XCTAssertNil(thread.turns[0].error)
    }

    func testResetClearsTurnsAndSession() {
        let thread = DiscussionThread()
        thread.beginTurn(question: "q")
        thread.apply(.session(id: "s1"))
        thread.reset()
        XCTAssertTrue(thread.turns.isEmpty)
        XCTAssertNil(thread.sessionID)
        XCTAssertFalse(thread.isBusy)
    }

    func testCancelPendingTurnMarksTurnCancelledAndKeepsSession() {
        let thread = DiscussionThread()
        thread.beginTurn(question: "q1")
        thread.apply(.reply(text: "a1", sessionID: "s1"))
        thread.apply(.done(costUsd: 0.1, turns: 1, stopReason: "end_turn"))
        thread.beginTurn(question: "q2")
        thread.apply(.activity(tool: "Read", detail: "x"))
        thread.cancelPendingTurn()
        XCTAssertFalse(thread.isBusy)
        XCTAssertEqual(thread.turns.count, 2)
        XCTAssertEqual(thread.turns[0].reply, "a1")
        XCTAssertFalse(thread.turns[0].isCancelled)
        let last = thread.turns[1]
        XCTAssertTrue(last.isCancelled)
        XCTAssertFalse(last.isPending)
        XCTAssertNil(last.error)
        XCTAssertNil(thread.activeRun)
        XCTAssertEqual(thread.sessionID, "s1")
    }

    func testCancelPendingTurnIsNoOpWhenIdle() {
        let thread = DiscussionThread()
        thread.cancelPendingTurn()
        XCTAssertTrue(thread.turns.isEmpty)
        thread.beginTurn(question: "q")
        thread.apply(.reply(text: "a", sessionID: "s1"))
        thread.apply(.done(costUsd: 0.1, turns: 1, stopReason: "end_turn"))
        thread.cancelPendingTurn()
        XCTAssertFalse(thread.turns[0].isCancelled)
    }

    func testNewTurnIsNotCancelled() {
        let thread = DiscussionThread()
        thread.beginTurn(question: "q")
        XCTAssertFalse(thread.turns[0].isCancelled)
    }

    // MARK: - TaskRunner ownership

    private final class LaunchRecorder {
        var runs: [TaskRun] = []
        var paths: [String] = []
        var finishers: [() -> Void] = []
    }

    private func makeRunner() -> (TaskRunner, LaunchRecorder) {
        let runner = TaskRunner()
        let recorder = LaunchRecorder()
        runner.discussLauncherForTesting = { run, path, onFinish in
            recorder.runs.append(run)
            recorder.paths.append(path)
            recorder.finishers.append(onFinish)
        }
        return (runner, recorder)
    }

    func testThreadIsStablePerProjectAndTask() {
        let runner = TaskRunner()
        let a = runner.thread(projectPath: "/p", taskID: "1")
        XCTAssertTrue(a === runner.thread(projectPath: "/p", taskID: "1"))
        XCTAssertFalse(a === runner.thread(projectPath: "/p", taskID: "10"))
        XCTAssertFalse(a === runner.thread(projectPath: "/q", taskID: "1"))
    }

    func testDiscussionLookupDoesNotCreateThread() {
        let runner = TaskRunner()
        XCTAssertNil(runner.discussion(projectPath: "/p", taskID: "1"))
        XCTAssertTrue(runner.discussions.isEmpty)
        let created = runner.thread(projectPath: "/p", taskID: "1")
        XCTAssertTrue(runner.discussion(projectPath: "/p", taskID: "1") === created)
    }

    func testAskAppendsPendingTurnAndLaunchesDiscussRunOutsideRuns() {
        let (runner, recorder) = makeRunner()
        runner.ask(projectPath: "/p", taskID: "7", question: "  What does step 3 mean?  ")
        let thread = runner.thread(projectPath: "/p", taskID: "7")
        XCTAssertEqual(thread.turns.map(\.question), ["What does step 3 mean?"])
        XCTAssertTrue(thread.isBusy)
        XCTAssertEqual(recorder.runs.count, 1)
        let run = recorder.runs[0]
        XCTAssertEqual(run.mode, .discuss)
        XCTAssertEqual(run.taskID, "7")
        XCTAssertEqual(run.description, "What does step 3 mean?")
        XCTAssertNil(run.resume)
        XCTAssertEqual(recorder.paths, ["/p"])
        XCTAssertTrue(runner.runs.isEmpty)
        XCTAssertNil(runner.run(for: "7", in: "/p"))
    }

    func testAskIgnoresBlankQuestionAndBusyThread() {
        let (runner, recorder) = makeRunner()
        runner.ask(projectPath: "/p", taskID: "7", question: "   ")
        XCTAssertTrue(runner.thread(projectPath: "/p", taskID: "7").turns.isEmpty)
        runner.ask(projectPath: "/p", taskID: "7", question: "one")
        runner.ask(projectPath: "/p", taskID: "7", question: "two")
        XCTAssertEqual(runner.thread(projectPath: "/p", taskID: "7").turns.count, 1)
        XCTAssertEqual(recorder.runs.count, 1)
    }

    func testRunEventsAreForwardedIntoTheThread() {
        let (runner, recorder) = makeRunner()
        runner.ask(projectPath: "/p", taskID: "7", question: "q")
        let run = recorder.runs[0]
        run.ingestForTesting(#"{"kind":"session","sessionId":"s1"}"# + "\n"
            + #"{"kind":"reply","text":"answer","sessionId":"s1"}"# + "\n"
            + #"{"kind":"done","costUsd":0.1,"turns":1,"stopReason":"end_turn"}"# + "\n")
        let thread = runner.thread(projectPath: "/p", taskID: "7")
        XCTAssertEqual(thread.turns.last?.reply, "answer")
        XCTAssertEqual(thread.sessionID, "s1")
        XCTAssertFalse(thread.isBusy)
    }

    func testSessionIDIsCarriedToNextTurnsResume() {
        let (runner, recorder) = makeRunner()
        runner.ask(projectPath: "/p", taskID: "7", question: "q1")
        recorder.runs[0].ingestForTesting(#"{"kind":"reply","text":"a","sessionId":"sess-1"}"# + "\n"
            + #"{"kind":"done","costUsd":0.1,"turns":1,"stopReason":"end_turn"}"# + "\n")
        recorder.finishers[0]()
        runner.ask(projectPath: "/p", taskID: "7", question: "q2")
        XCTAssertEqual(recorder.runs.count, 2)
        XCTAssertEqual(recorder.runs[1].resume, "sess-1")
    }

    func testDiscussFinishDoesNotTriggerOnAnyRunFinished() {
        let (runner, recorder) = makeRunner()
        var finished: [String] = []
        runner.onAnyRunFinished = { finished.append($0) }
        runner.ask(projectPath: "/p", taskID: "7", question: "q")
        recorder.finishers[0]()
        XCTAssertTrue(finished.isEmpty)
        XCTAssertFalse(runner.thread(projectPath: "/p", taskID: "7").isBusy)
    }

    func testFinishWithRunErrorMarksTurnErrored() {
        let (runner, recorder) = makeRunner()
        runner.ask(projectPath: "/p", taskID: "7", question: "q")
        recorder.runs[0].finishForTesting(projectPath: "/p", error: "Could not locate `node`.")
        recorder.finishers[0]()
        let turn = runner.thread(projectPath: "/p", taskID: "7").turns[0]
        XCTAssertEqual(turn.error, "Could not locate `node`.")
        XCTAssertFalse(turn.isPending)
    }

    func testLiveDiscussTurnIsExcludedFromRunningCounts() {
        let (runner, recorder) = makeRunner()
        runner.ask(projectPath: "/p", taskID: "7", question: "q")
        recorder.runs[0].markRunningForTesting(projectPath: "/p")
        XCTAssertEqual(runner.runningRunCount, 0)
        XCTAssertTrue(runner.runningSnapshots.isEmpty)
        XCTAssertFalse(runner.hasRunningRun(inProject: "/p"))
        XCTAssertFalse(runner.isRunning(taskID: "7", in: "/p"))
    }

    func testStopAllRunningTerminatesDiscussRuns() {
        let (runner, recorder) = makeRunner()
        runner.ask(projectPath: "/p", taskID: "7", question: "q")
        recorder.runs[0].markRunningForTesting(projectPath: "/p")
        runner.stopAllRunning()
        XCTAssertFalse(recorder.runs[0].isRunning)
    }

    func testResetDiscussionClearsThreadAndStopsInFlightRun() {
        let (runner, recorder) = makeRunner()
        runner.ask(projectPath: "/p", taskID: "7", question: "q")
        let run = recorder.runs[0]
        run.markRunningForTesting(projectPath: "/p")
        runner.resetDiscussion(projectPath: "/p", taskID: "7")
        XCTAssertFalse(run.isRunning)
        let thread = runner.thread(projectPath: "/p", taskID: "7")
        XCTAssertTrue(thread.turns.isEmpty)
        XCTAssertFalse(thread.isBusy)
        // A late event from the stopped run must not resurrect the thread.
        run.ingestForTesting(#"{"kind":"reply","text":"late","sessionId":"x"}"# + "\n")
        recorder.finishers[0]()
        XCTAssertTrue(thread.turns.isEmpty)
        XCTAssertNil(thread.sessionID)
    }

    func testCancelDiscussionTurnStopsRunKeepsHistoryAndResumesNextAsk() {
        let (runner, recorder) = makeRunner()
        runner.ask(projectPath: "/p", taskID: "7", question: "q1")
        recorder.runs[0].ingestForTesting(#"{"kind":"reply","text":"a","sessionId":"sess-1"}"# + "\n"
            + #"{"kind":"done","costUsd":0.1,"turns":1,"stopReason":"end_turn"}"# + "\n")
        recorder.finishers[0]()
        runner.ask(projectPath: "/p", taskID: "7", question: "q2")
        let run = recorder.runs[1]
        run.markRunningForTesting(projectPath: "/p")
        runner.cancelDiscussionTurn(projectPath: "/p", taskID: "7")
        XCTAssertFalse(run.isRunning)
        let thread = runner.thread(projectPath: "/p", taskID: "7")
        XCTAssertFalse(thread.isBusy)
        XCTAssertEqual(thread.turns.count, 2)
        XCTAssertTrue(thread.turns[1].isCancelled)
        // Late events and the finish of the stopped run are ignored.
        run.ingestForTesting(#"{"kind":"reply","text":"late","sessionId":"other"}"# + "\n"
            + #"{"kind":"error","message":"terminated"}"# + "\n")
        run.finishForTesting(projectPath: "/p", error: "Process terminated.")
        recorder.finishers[1]()
        XCTAssertNil(thread.turns[1].reply)
        XCTAssertNil(thread.turns[1].error)
        XCTAssertEqual(thread.sessionID, "sess-1")
        runner.ask(projectPath: "/p", taskID: "7", question: "q3")
        XCTAssertEqual(recorder.runs.count, 3)
        XCTAssertEqual(recorder.runs[2].resume, "sess-1")
    }

    func testCancelDiscussionTurnWithoutThreadIsNoOp() {
        let runner = TaskRunner()
        runner.cancelDiscussionTurn(projectPath: "/p", taskID: "7")
        XCTAssertNil(runner.discussion(projectPath: "/p", taskID: "7"))
    }
}
