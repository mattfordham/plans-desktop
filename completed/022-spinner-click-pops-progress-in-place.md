# Spinner click pops progress dialog in place

**ID:** 022
**Created:** 2026-06-06T00:00
**Type:** feature
**Status:** completed
**Branch:** feature/022-spinner-click-pops-progress-in-place
**Completed:** 2026-06-06T00:00

## What
When clicking the in-progress spinner in a card row, pop the progress dialog in place, just below the spinner. In other words, clicking the spinner does not open the detail view.

## Why
Adds value by letting the user glance at a running task's live log without leaving the dashboard. Today the card spinner (`ProjectCard.swift:230-235`) calls `openWindow(id: "plan-detail", value: row.id)`, which opens a whole separate detail window that then auto-pops the progress sheet. That is heavyweight for "I just want to peek at progress" — it spawns a window, shifts focus away from the card grid, and conflates "show progress" with "open the plan." Anchoring the progress dialog as a popover directly under the spinner keeps the interaction lightweight and in-context, and decouples it from navigating to the detail view.

## How
- [x] Step 1: Make `RunProgressSheet` reusable outside `PlanDetailView`. In `PlanDetailView.swift`, change `private struct RunProgressSheet` to internal (drop `private`) so `ProjectCard` can present it. It already uses `@Environment(\.dismiss)` (works inside `.popover`) and takes `run: TaskRun?` + `taskID: String?` — no signature change needed.
- [x] Step 2: Add per-card popover state to `ProjectCard` — `@State private var progressPopoverTaskID: String? = nil` — tracking which row's progress popover is open (one at a time). Add a helper that builds a per-task `Binding<Bool>` from it (get: `progressPopoverTaskID == taskID`; set: assign the id when true, `nil` when false), mirroring the binding pattern suggested by research.
- [x] Step 3: In `rowActions(_:)` (`ProjectCard.swift:227-235`), change the spinner's `.onTapGesture` so it no longer calls `openWindow(...)`; instead set `progressPopoverTaskID = row.task.id`. Update the stale comment ("Tapping the live spinner opens the plan's detail window…") to describe the in-place popover.
- [x] Step 4: Attach `.popover(isPresented: <per-task binding>, attachmentAnchor: .point(.bottom), arrowEdge: .top)` to the spinner `ProgressView` so the dialog anchors just below the spinner. Present `RunProgressSheet(run: runner.run(for: row.task.id), taskID: row.task.id)` inside, with an `.onDisappear` that calls `runner.dismiss(taskID: row.task.id)` and `store.reload()` — matching the detail view's sheet teardown (`PlanDetailView.swift:89-92`). Add `@Environment(PlansStore.self) private var store` to `ProjectCard` if not already present (currently it only injects `openWindow` and `runner`).
- [x] Step 5: Give the popover a sensible size for the card context. `RunProgressSheet` is pinned to `minWidth: 480, minHeight: 360` for a sheet; that is acceptable as a popover but verify it isn't clipped. If it feels oversized anchored to a small card, constrain the popover content with a `.frame(width:height:)` wrapper rather than editing `RunProgressSheet`'s own frame (keep the detail-window sheet unchanged).
- [x] 👁 Step 6: Build and run the app, start/elaborate a task on a card so the spinner appears, then click the spinner. Verify the progress dialog pops up anchored just below the spinner, shows the live log, and that NO separate detail window opens. Confirm Stop/Close behave (Close backgrounds the run; clicking the spinner again re-opens the popover) and that clicking elsewhere dismisses the popover.

## Verification
- Clicking the in-progress spinner in a card row shows the progress dialog as a popover anchored just below the spinner.
- Clicking the spinner does NOT open the plan detail window.
- The popover shows the run's live log, Stop/Close controls behave as in the detail sheet, and dismissing it reloads the store so the row's new status is reflected.
- Opening the detail window by other means (clicking a content cell) still works and still auto-pops its own progress sheet — that path is unchanged.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/ProjectCard.swift` — replace spinner tap-to-open-window with popover state + `.popover` presenting `RunProgressSheet`; add popover state and (if needed) `PlansStore` environment.
- [ ] `Sources/Plans/PlanDetailView.swift` — make `RunProgressSheet` internal so it can be presented from `ProjectCard`.

### Related Files (may need updates)
- `Sources/Plans/TaskRunner.swift` — read-only here (`runner.run(for:)`, `runner.dismiss(taskID:)`, `runner.isRunning(taskID:)`); no change expected.

### UI Affected
- Card row in-progress spinner — now opens an in-place progress popover instead of the detail window.

## Assumptions

### Initial (from elaboration)
- [high] Reuse `RunProgressSheet` for the popover content rather than building a new condensed view. **Why:** It is the exact dialog the spinner already reaches today (via the detail window), so reusing it keeps behavior/visuals identical and is the smallest change; it only needs to be made non-private.
- [low] Present the dialog as a SwiftUI `.popover` anchored `.point(.bottom)` / `arrowEdge: .top` (just below the spinner), one popover at a time via a single `progressPopoverTaskID`. **Why:** Matches the "pop in place, just below the spinner" wording and the research suggestion, but macOS `.popover` anchoring/auto-dismiss behavior is the kind of UX call the description didn't pin down — the observation step (Step 6) is the gate to confirm it looks right; `.overlay` with manual positioning is the fallback if `.popover` anchors unreliably.
- [low] On popover dismiss, replicate the detail sheet's teardown (`runner.dismiss(taskID:)` + `store.reload()`). **Why:** Keeps run-lifecycle and status-refresh semantics identical to the existing detail flow, but whether the card popover should "dismiss" the run on close vs. leave it (since the spinner can re-open it) is a semantics choice not specified in the task.
- [low] Keep `RunProgressSheet`'s existing `minWidth: 480 / minHeight: 360` frame; only wrap with an outer frame if it looks oversized as a popover. **Why:** Avoids touching the detail-window sheet sizing; the right popover dimensions are a visual judgement deferred to the observation step.

### Discovered during execution
- [high] Made `RunProgressSheet` internal (dropped `private`) and updated its doc comment to note it now dismisses via `@Environment(\.dismiss)` from either a `.sheet` or `.popover`. **Why:** Single plausible path per the plan; the existing `.dismiss` usage already makes it popover-safe, so no signature change was needed.
- [high] Passed `runner.run(for: row.task.id)` directly as `RunProgressSheet(run:)` rather than the detail view's `row.map { ... } ?? nil` form. **Why:** In `ProjectCard` the task id is always in hand (no nullable resolved row), so the direct call is the natural fit and `run(for:)` already returns `TaskRun?`.
- [low] Spinner-popover teardown mirrors the detail sheet exactly (`runner.dismiss(taskID:)` + `store.reload()` on `.onDisappear`). **Why:** Keeps status-refresh/run-lifecycle semantics identical to the existing detail flow; whether the card popover should drop the finished run vs. leave it for re-open is a semantics call the task left to the observation gate (Step 6).
- [low] Used the plain `.popover(...)` with `RunProgressSheet`'s existing `minWidth: 480 / minHeight: 360` and did NOT add an outer `.frame` — sizing review (Step 5) and the visual observation (Step 6) are outside this segment. **Why:** This segment is scoped to Steps 1-4; popover dimensions are deferred to the later sizing/observation steps.
- [high] Step 5 sizing decision: left the popover at `RunProgressSheet`'s `minWidth: 480 / minHeight: 360` with NO outer `.frame` wrapper in `ProjectCard`. **Why:** Those are minimums, not fixed sizes, and the log is inside a self-contained `ScrollView`, so the popover settles near 480×360 and the ScrollView absorbs long-log overflow — no clipping and no unbounded vertical growth. A fixed `.frame(width:height:)` wrapper would add risk (a height under the sheet's own `minHeight: 360` would fight it) for no benefit. 480×360 anchored to the small spinner is large but acceptable per the step guidance, so the conservative choice is no code change.
- [high] Issue 1 (arrow alignment): moved the `.popover` modifier onto the bare `ProgressView().controlSize(.small)` BEFORE the `.padding(.leading, 8)` / `.contentShape` / `.onTapGesture`, so the popover's attachment rect is the tightly-bounded spinner glyph rather than the padded hit cell. `.point(.bottom)` now centers the arrow on the spinner's true visual center instead of the wider padded cell's center. The padding/contentShape/tap still wrap the glyph, preserving the 22pt row height and hit target.
- [high] Issue 2 (stable width): added `.frame(width: 480)` to the `RunProgressSheet(...)` inside the card's popover content (NOT to `RunProgressSheet`'s own frame in `PlanDetailView`). 480 matches the sheet's existing `minWidth` so nothing fights; this fixes the width from first paint so the inset log field is full-width immediately. Height left flexible (driven by the sheet's `minHeight: 360`) since only the width inconsistency was reported.
- [low] Issue 3 (toggle): the spinner tap now does `progressPopoverTaskID = (progressPopoverTaskID == row.task.id) ? nil : row.task.id` so re-clicking the open spinner closes the popover; outside-click dismissal is unaffected.
- [low] Review revision (placement): changed the popover anchor from `.point(.bottom)` / fixed `arrowEdge: .top` to `attachmentAnchor: .rect(.bounds)` with no explicit `arrowEdge`. **Why:** The user is fine with macOS auto-flipping the popover above/below the spinner based on available space, but wanted the arrow tip offset just off the glyph rather than piercing its center. Anchoring to the glyph's bounds (not a single center point) lets macOS attach the arrow to whichever edge it flips to, sitting off the spinner. Auto-placement direction is macOS's call, which the user accepted.
- [low] Review revision (placeholder width): added `.frame(maxWidth: .infinity, alignment: .leading)` to `RunProgressSheet.logList`'s inner `VStack` (in `PlanDetailView.swift`). **Why:** The `.frame(width: 480)` on the popover content fixed the outer width, but the inset `.textBackgroundColor` log field still hugged the narrow "Waiting for the agent…" placeholder until full-width log lines arrived. Stretching the log column makes the inset field full-width from the first frame. This also affects the detail-window sheet, where a full-width empty log field is a strict improvement (it already went full-width once lines arrived).

## Changes
- `PlanDetailView.swift`: `RunProgressSheet` made internal (was `private`); doc comment updated to note it serves both the detail `.sheet` and the card `.popover`.
- `ProjectCard.swift`: added `@Environment(PlansStore.self) store`, `@State progressPopoverTaskID`, and a `progressPopover(for:)` per-task `Binding<Bool>` helper. The in-progress spinner's tap now sets `progressPopoverTaskID = row.task.id` instead of `openWindow(...)`, and carries `.popover(attachmentAnchor: .point(.bottom), arrowEdge: .top)` presenting `RunProgressSheet(run:taskID:)` with `.onDisappear` → `runner.dismiss(taskID:)` + `store.reload()`. Spinner no longer opens the detail window.
- `swift build`: Build complete (1 pre-existing unrelated warning).

## Notes
_Additional context_
