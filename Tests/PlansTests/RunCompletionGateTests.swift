import XCTest
@testable import Plans

/// Tests for `RunCompletionGate` — a run finishes only once the process has
/// exited AND its stdout has reached EOF, so the last stdout chunk (which can
/// arrive after the exit notification) is never dropped.
final class RunCompletionGateTests: XCTestCase {

    func testExitThenEOFCompletesOnEOFWithExitStatus() {
        var gate = RunCompletionGate()
        XCTAssertNil(gate.processExited(status: 3))
        XCTAssertEqual(gate.streamClosed(), 3)
    }

    func testEOFThenExitCompletesOnExit() {
        var gate = RunCompletionGate()
        XCTAssertNil(gate.streamClosed())
        XCTAssertEqual(gate.processExited(status: 0), 0)
    }

    func testCompletesExactlyOnce() {
        var gate = RunCompletionGate()
        _ = gate.processExited(status: 0)
        XCTAssertEqual(gate.streamClosed(), 0)
        XCTAssertNil(gate.streamClosed())
        XCTAssertNil(gate.processExited(status: 0))
        XCTAssertNil(gate.gracePeriodElapsed())
    }

    func testGracePeriodCompletesAfterExitWithoutEOF() {
        var gate = RunCompletionGate()
        _ = gate.processExited(status: 7)
        XCTAssertEqual(gate.gracePeriodElapsed(), 7)
        XCTAssertNil(gate.streamClosed(), "late EOF must not complete again")
    }

    func testGracePeriodIsNoOpBeforeExit() {
        var gate = RunCompletionGate()
        XCTAssertNil(gate.gracePeriodElapsed())
        _ = gate.streamClosed()
        XCTAssertNil(gate.gracePeriodElapsed())
    }

    func testIsCompleteTracksFiring() {
        var gate = RunCompletionGate()
        XCTAssertFalse(gate.isComplete)
        _ = gate.streamClosed()
        XCTAssertFalse(gate.isComplete)
        _ = gate.processExited(status: 0)
        XCTAssertTrue(gate.isComplete)
    }
}
