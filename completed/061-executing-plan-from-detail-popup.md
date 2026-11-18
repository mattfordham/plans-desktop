# Executing A Plan From The Detail Pop-Up Should Not Immediately Open The Progress Window

**ID:** 061
**Created:** 2026-08-14T00:00
**Type:** bug
**Status:** completed
**Last updated:** 2026-08-17
**Completed:** 2026-08-17T12:33
**Branch:** fix/061-executing-plan-from-detail-popup

## What
Executing a plan from the detail pop-up should not immediately open the progress window. It should work more like the index dashboard where executing just starts the spinner.

## Why
Improves consistency and reduces surprise: executing from a project-card row on the index dashboard only starts the spinner and leaves it to the user to open the progress popover (by tapping the spinner). The detail pop-up (`PlanDetailView`) instead auto-raises the progress sheet the instant a run starts, which is jarring and inconsistent with the dashboard's tap-to-open model. Aligning the two makes "Execute" behave the same everywhere.

## How Summary
The process-start and progress-window-open are already fully decoupled at the runner layer (`TaskRunner.run(...)` has no window side effect). The unwanted auto-open lives entirely in `PlanDetailView` view state: an `.onChange(of: runner.isRunning(taskID:))` modifier flips `showProgress = true` the moment THIS task's run starts. Removing that fresh-start auto-raise (while keeping the `.onAppear` already-running case for the #022 spinner-click path, and the header's manual "Show progress" button) makes the detail Execute behave exactly like the dashboard. To make the behavior testable, the auto-open decision is extracted into a pure static helper on `PlanDetailView` and covered by unit tests before wiring the view to it.

**Files of note:**
- `Sources/Plans/PlanDetailView.swift` — holds `showProgress` state, the `.onChange`/`.onAppear` auto-open hooks (lines ~94-105), the `.sheet`, and the header "Show progress" button; the single file to change.
- `Sources/Plans/ProjectCard.swift` — reference behavior: dashboard Execute (`runner.run(...)`) with no progress auto-open; spinner tap opens the popover.
- `Sources/Plans/TaskRunner.swift` — `run(projectPath:taskID:mode:)` starts the process with no window side effect (no change needed).
- `Tests/PlansTests/PlanDetailViewTests.swift` — where the new pure-helper tests live.

## How
- [x] Step 1: Add a failing unit test in `Tests/PlansTests/PlanDetailViewTests.swift` for a new pure helper `PlanDetailView.shouldAutoOpenProgress(onAppearRunning:)` (or equivalently named), asserting it returns `true` when the task is already running as the window appears and `false` otherwise — encoding "don't auto-open on a fresh run-start, only when already running on appear".
- [x] Step 2: Extract the auto-open decision into that pure static helper on `PlanDetailView` and make the tests pass (GREEN). The helper captures the kept behavior (open when already-running on appear) so it is unit-testable.
- [x] Step 3: Remove the fresh-start auto-raise: delete the `.onChange(of: runner.isRunning(taskID:))` block (lines ~99-105) that sets `showProgress = true` when the run starts. Keep the `.onAppear` already-running case (route it through the new helper), the `.sheet(isPresented: $showProgress)`, and the header's "Show progress" button so manual re-entry still works.
- [x] Step 4: Run the targeted test file (`swift test --filter PlanDetailViewTests`) and confirm it builds and passes; verify no other `showProgress = true` write remains that would auto-open on execute.

## Verification
- Executing a plan from the detail pop-up starts the spinner (header shows the ProgressView + "Show progress" button) but does NOT auto-open the progress sheet — matching the dashboard's Execute behavior.
- The "Show progress" button (and opening the detail window for an already-running task, the #022 path) still opens the progress sheet.
- `swift test --filter PlanDetailViewTests` passes, including the new auto-open decision test.

## Impact Scope
_Fewer than 3 files affected — Impact Scope omitted._

## Assumptions

### Initial (from elaboration)
- [low] Keep the `.onAppear` already-running auto-open (the #022 spinner-click → open-detail-for-running-task path). **Why:** the task text compares against the dashboard's *Execute* action (fresh run start), not window-open behavior; the research recommended preserving this and it serves a distinct, intentional case.
- [low] Introduce a pure static helper (`shouldAutoOpenProgress`) and TDD it, rather than deleting the `.onChange` block with no test. **Why:** CLAUDE.md mandates TDD where a suite exists; SwiftUI view modifiers aren't unit-testable directly, and the existing test file already tests pure static helpers on `PlanDetailView` (`taskFileURL`, `RunProgressSheet.scrollTarget`), so this matches the established seam pattern.

### Discovered during execution
- [high] Chose the signature `shouldAutoOpenProgress(onAppearRunning: Bool) -> Bool` (single Bool, returns it unchanged). **Why:** the segment prompt offered a single-Bool signature as acceptable; it captures the whole decision (auto-open iff already-running-on-appear) as a pure testable seam without needing the runner or row, matching the existing static-helper pattern in the file.
- [high] Placed the helper immediately above `taskFileURL(...)` alongside the other pure static helpers (`canReElaborate`, `taskFileURL`). **Why:** keeps all testable static seams grouped, consistent with the file's existing organization.

## Changes
- `Sources/Plans/PlanDetailView.swift`:
  - Removed the `.onChange(of: runner.isRunning(taskID:))` block that raised `showProgress = true` on a fresh run start — the sole cause of the detail pop-up auto-opening the progress sheet on Execute.
  - Added pure static helper `shouldAutoOpenProgress(onAppearRunning:) -> Bool` (grouped with the other static helpers) that encodes the auto-open rule: open only when the task is already running as the window appears.
  - Routed the kept `.onAppear` already-running case (#022 spinner-click) through the helper; kept `.sheet(isPresented: $showProgress)` and the header's "Show progress" button as the deliberate manual re-entry path.
  - Updated the `showProgress` @State doc comment to reflect that a fresh run from this view no longer raises it.
- `Tests/PlansTests/PlanDetailViewTests.swift`: added `testAutoOpensProgressWhenAlreadyRunningOnAppear` and `testDoesNotAutoOpenProgressWhenNotRunningOnAppear` under a new `// MARK: - PlanDetailView.shouldAutoOpenProgress` section (TDD: written failing first, then made green).
- Tests: `swift test --filter PlanDetailViewTests` → 8 tests, 0 failures.
- Net effect: Executing from the detail pop-up now just starts the spinner (header shows ProgressView + "Show progress"), matching the index dashboard; the progress sheet no longer auto-opens on Execute.

## Notes
_Additional context_
