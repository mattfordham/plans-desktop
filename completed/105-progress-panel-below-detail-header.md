# Progress panel below detail header for in-progress plans

**ID:** 105
**Created:** 2026-11-07T20:32
**Type:** feature
**Status:** completed
**Branch:** feature/105-progress-panel-below-detail-header
**Completed:** 2026-11-07T22:10

## What
When showing a planned progress. Show it in a panel below the detail header and above the body. It should be full bleed, almost like a window pushing down.

## Why
Adds value by surfacing an in-progress plan's step completion at a glance in the detail surface. Today `Task.howProgress` (done/total How steps) is parsed and tested but never rendered anywhere in the browser detail — the only cue a plan is advancing is the per-step checklist deep in the body. A prominent, full-bleed progress panel directly under the header tells the reader how far along the work is without scrolling.

## How Summary
Add two pure, static helpers to `PlanDetailView` — `showsProgressPanel(status:howProgress:)` (true only for an `.inProgress` plan with `total > 0`) and `progressFraction(done:total:)` (guards `total == 0`) — unit-tested first. Then render a new full-bleed progress panel in `planScrollView(_:)`, inserted between the header's `Divider()` and the body sections, laid out edge-to-edge (outside the reading-width frame, like the existing full-bleed `Divider`) with a subtle amber-tinted `.bar` background, a `play.circle.fill` glyph, a "N of M steps" label and a `ProgressView(value:total:)` bar, followed by its own `Divider()` seam so it reads like a panel pushed down from the header.

**Files of note:**
- `Sources/Plans/PlanDetailView.swift` — `planScrollView(_:)` is where the panel is inserted; new static helpers + a `progressPanel(_:)` view method added here.
- `Sources/Plans/TaskParser.swift` — source of `Task.howProgress: (done, total)` and `TaskStatus.inProgress`; read-only, no change.
- `Sources/Plans/TaskStatus+Glance.swift` — `inProgress` amber `glanceColor` (`0xfabd2f`) + `play.circle.fill` `symbolName` reused for the panel's accent; read-only, no change.
- `Tests/PlansTests/PlanDetailViewTests.swift` — new failing tests for the two static helpers, mirroring the existing `TaskStatus.allCases + [nil]` sweep style.

## How
- [x] Step 1: Add failing XCTest cases in `Tests/PlansTests/PlanDetailViewTests.swift` for `PlanDetailView.showsProgressPanel(status:howProgress:)` (true only for `.inProgress` with `total > 0`; false for every other status incl. `nil`, and false for `(0,0)` even when in-progress) and `PlanDetailView.progressFraction(done:total:)` (returns `done/total`, and `0` when `total == 0`), using the existing `TaskStatus.allCases + [nil]` sweep convention.
- [x] Step 2: Implement the two pure `static` helpers on `PlanDetailView` so the new tests pass (`swift test --filter PlanDetailViewTests`).
- [x] Step 3: Add a `progressPanel(_ row:)` view method and insert it in `planScrollView(_:)` between the header `Divider()` and the body `VStack`, gated on `showsProgressPanel`. Render it full-bleed (no reading-width frame; `.frame(maxWidth: .infinity)`), with an amber-tinted `.bar` background, a `play.circle.fill` glyph in `TaskStatus.inProgress.glanceColor`, a "N of M steps" count, a `ProgressView(value:total:)` bar, and a trailing `Divider()` seam.
- [x] 👁 Step 4: Build and run the app (`./build.sh`), open an in-progress plan in the browser detail column, and confirm the full-bleed progress panel appears below the header and above the body, that it is edge-to-edge, and that it is absent for pending/elaborated/completed plans. _(Observation deferred to review — yolo/worktree mode. Prerequisites built and committed at f4c44e6; verify visually during `/plan-review 105`.)_

## Verification
- `swift test --filter PlanDetailViewTests` passes, including the new progress-panel helper tests.
- Opening an in-progress plan in the browser detail shows a full-bleed progress panel between the header and the body, with the correct "N of M steps" and bar fill.
- Pending, elaborated, review, and completed plans show no progress panel.
- The panel spans the full width of the detail column (not capped to the reading width), reading like a window pushed down beneath the header.

## Impact Scope
_Not applicable — fewer than 3 files modified (1 source file + 1 test file); the other two files are read-only references._

## Assumptions

### Initial (from elaboration)
- [low] The panel shows strictly when `task.status == .inProgress` (on-disk status), not whenever a live run is in flight. **Why:** the task scopes it to "in-progress plans," the literal status-driven reading; a run that hasn't flipped the file yet is out of scope.
- [low] When all steps are done (`done == total`) but the status is still `.inProgress`, the panel still shows with a full bar rather than collapsing. **Why:** the plan is still in-progress until its status advances; hiding at 100% would make the panel flicker away just before completion.
- [low] Panel content is a status glyph + "N of M steps" label + a `ProgressView` bar. **Why:** the task says "show that progress"; a bar plus count is the natural, minimal reading and matches the app's existing restrained vocabulary (no new color system).
- [low] Panel styling uses an amber-tinted `.bar` background keyed to the existing `TaskStatus.inProgress` glance color rather than a new palette entry. **Why:** keeps the panel consistent with how in-progress is signalled on cards and the menu bar; avoids introducing design tokens.
- [high] Progress counts are read from the existing `Task.howProgress` tuple rather than re-parsing the How section. **Why:** `howProgress` is already computed at parse time and covered by `TaskParserTests`; re-counting would duplicate tested logic.
- [high] The panel is laid out full-bleed by placing it outside the reading-width double-`.frame` trick (as the existing header `Divider()` already is). **Why:** that is the codebase's established full-bleed technique in `planScrollView`.
- [high] The progress bar uses SwiftUI's built-in `ProgressView(value:total:)` (or a fixed-height primitive), never a `GeometryReader`-measured size fed back into layout. **Why:** the project has a documented layout-loop-hang history (#096) from measured sizes; intrinsic/`.infinity` sizing is the safe pattern.

### Discovered during execution
_To be filled during execution_

## Changes
- `Sources/Plans/PlanDetailView.swift` — Added two pure static helpers: `showsProgressPanel(status:howProgress:)` (true only for `.inProgress` with `total > 0`) and `progressFraction(done:total:)` (guards `total == 0`). Added `progressPanel(_:)` view method and inserted it in `planScrollView(_:)` between the header's full-bleed `Divider()` and the body `VStack`, gated on `showsProgressPanel`. The panel is full-bleed (rendered outside the reading-width double-`.frame`), with a `play.circle.fill` glyph in the in-progress amber `glanceColor`, a "N of M steps" count, a built-in `ProgressView(value:total:)` bar tinted amber, a faint amber background (`glanceColor.opacity(0.12)`), and a trailing `Divider()` seam so it reads like a panel pushed down from the header.
- `Tests/PlansTests/PlanDetailViewTests.swift` — Added 5 tests covering `showsProgressPanel` (in-progress with steps incl. 100%, in-progress with `(0,0)`, every non-in-progress status + `nil`) and `progressFraction` (ratio + divide-by-zero guard), mirroring the existing `TaskStatus.allCases` sweep style.
- Tests: `swift test --filter PlanDetailViewTests` → 59 tests, 0 failures. `swift build` → complete.

## Notes
_Additional context_
