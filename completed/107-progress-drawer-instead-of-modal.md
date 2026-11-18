# Progress as an inline expand/collapse drawer instead of a modal pop-up

**ID:** 107
**Created:** 2026-11-07T22:30
**Type:** feature
**Status:** completed
**Completed:** 2026-11-08T08:27
**Branch:** feature/107-progress-drawer-instead-of-modal

## What
Instead of putting run progress in a modal pop-up (`.sheet`), surface it as an
inline panel in the Plan Detail view — a drawer that expands and collapses below
the progress bar. The reference screenshot shows the Plan Detail view with a
"Show progress" button and a floating "Capturing & executing" modal overlaying
the plan content; that modal should become an in-place drawer instead.

## Why
The modal `RunProgressSheet` overlays and hides the plan content while a run
streams, forcing the user to choose between watching progress and reading the
plan. An inline drawer below the existing #105 step-count progress bar keeps the
plan visible, lets the run log live in the same scrolling column as everything
else about the task, and matches the app's established pattern of surfacing
state inline (the discussion panel, the #105 progress panel) rather than in
pop-ups. Expand/collapse gives the user control over how much vertical space the
log takes without a separate window.

## How Summary
Replace the `.sheet(isPresented: $showProgress)` presentation of
`RunProgressSheet` with an inline, full-bleed drawer rendered inside
`planScrollView` immediately after the #105 `progressPanel`. The drawer shows a
header row (title + spinner + a chevron disclosure + Stop) that toggles an
expanded body containing the live run log, summary, denial note, and error
banner — reusing the existing `RunProgressSheet` sub-views. The "Show progress"
header button and the `.onAppear` auto-open both drive the drawer's
expanded/collapsed state instead of a sheet. A new pure static predicate gates
whether the drawer is present at all (there is a live/finished run to show),
unit-tested in the same style as #105's helpers.

## How
- [x] Add a pure static predicate `showsProgressDrawer(hasRun:)` (and/or
      `showsProgressDrawer(run:)` taking the optional run) to `PlanDetailView`
      that returns `true` only when there is a `TaskRun` to display for this
      task (running OR finished-but-not-yet-dismissed). Keep it pure/static and
      follow #105's helper doc-comment style. Write the failing test first in
      `Tests/PlansTests/PlanDetailViewTests.swift` (sweep: run present/absent;
      if it also considers running vs finished, cover both).
- [x] Add a pure static predicate `progressDrawerStartsExpanded(onAppearRunning:mode:)`
      that encodes the auto-open-on-appear rule the sheet used
      (`shouldAutoOpenProgress`) but named for the drawer's initial expanded
      state. It may simply delegate to / share logic with `shouldAutoOpenProgress`
      (a `.discuss` run never auto-expands). Write its failing test first,
      mirroring the existing `shouldAutoOpenProgress` tests.
- [x] Repurpose the `@State private var showProgress` flag on `PlanDetailView`
      as the drawer's expanded/collapsed state (keep the name or rename to
      `progressDrawerExpanded`; update the doc comment to describe a drawer, not
      a sheet). The `.onAppear` block sets it from
      `progressDrawerStartsExpanded(...)`; the header "Show progress" button
      toggles it.
- [x] Build the inline drawer view method `progressDrawer(_ row:)` on
      `PlanDetailView`. It renders a full-bleed band (same double-`.frame`
      full-bleed convention as `progressPanel`: inner content width-capped only
      where appropriate, outer `.frame(maxWidth: .infinity)`), with a trailing
      `Divider()` seam. Structure:
        - A tappable header row: the run title (`modeVerb`/mode-aware, reuse the
          `RunProgressSheet.title`/`modeVerb` logic), an inline `ProgressView`
          spinner while `run.isRunning`, a chevron (`chevron.down` /
          `chevron.right`) disclosure reflecting expanded state, and a Stop
          button while running (calls `run.stop()`).
        - When expanded: the reusable run-log body — the `logList` (auto-scroll
          via `scrollTarget` + `.onChange(of: lines.count)`), the `errorBanner`
          (gated by `shouldShowFailureBanner`), the `deniedSummary`, and the
          `summaryRow` — ported from `RunProgressSheet`. Height must be bounded
          intrinsically / with `.infinity` within a capped band; NEVER measure a
          size and feed it back into layout (#096).
      Factor the shared sub-views so they are not duplicated: either lift the
      log/summary/banner rendering into shared private helpers both the drawer
      and (if kept) the sheet call, or move them onto a small shared view. Do
      NOT leave two divergent copies of the log rendering.
- [x] Remove the `.sheet(isPresented: $showProgress)` modifier that presented
      `RunProgressSheet` (lines ~237-244). Move its `.onDisappear` side effects
      (`runner.dismiss(taskID:in:)` + `store.reload()`) to fire when the drawer
      is dismissed/collapses for a FINISHED run — e.g. a "Done"/close affordance
      on the drawer that calls `runner.dismiss(...)` + `store.reload()`, matching
      the sheet's finished-run Done behavior. A running run must NOT be dismissed
      by collapsing (collapsing only hides the body; Stop ends the run).
- [x] Render the drawer inside `planScrollView`'s outer `VStack` directly after
      the `if Self.showsProgressPanel(...) { progressPanel(row) }` block (~line
      737) and before the body `VStack` (~line 738), gated by
      `showsProgressDrawer(...)`. This places it "below the progress bar" as the
      task asks, in the same full-bleed region.
- [x] Decide the fate of `RunProgressSheet`: if no other call site presents it
      (grep confirms PlanDetailView was the only `.sheet` for it), either delete
      the now-unused struct or reduce it to the shared sub-views the drawer uses.
      Keep the two pure statics (`scrollTarget`, `shouldShowFailureBanner`) and
      their tests — relocate them onto `PlanDetailView` or a retained type so the
      existing tests still compile. Update any references.
- [x] 👁 Build and run the app (`./build.sh` or `swift build` + launch), start or
      open an in-progress/capturing task in the detail view, and visually confirm:
      the progress now appears as an inline drawer below the step-count bar (no
      floating modal), the chevron expands/collapses it, Stop works while
      running, and the plan content remains visible beside/under the drawer.

## Verification
- `swift build` succeeds with no warnings introduced by the change.
- `swift test --filter PlanDetailViewTests` passes, including the new
  `showsProgressDrawer` / `progressDrawerStartsExpanded` tests and the retained
  `scrollTarget` / `shouldShowFailureBanner` tests.
- In the running app, opening a detail view for an in-progress or capturing task
  shows an inline expand/collapse progress drawer below the progress bar — NOT a
  modal sheet — and the plan content stays visible.
- The chevron toggles the drawer; Stop ends a running run; a finished run's
  drawer can be dismissed and the store reloads to surface the new status.

## Impact Scope
- `Sources/Plans/PlanDetailView.swift` — remove the progress `.sheet`, repurpose
  `showProgress` state, add `progressDrawer(_:)` view method + the two new pure
  static predicates, re-slot rendering in `planScrollView`, and resolve
  `RunProgressSheet` (delete or reduce to shared sub-views).
- `Tests/PlansTests/PlanDetailViewTests.swift` — add tests for the new pure
  predicates; keep `scrollTarget` / `shouldShowFailureBanner` tests compiling
  against wherever those statics now live.

## Assumptions

### Initial (from elaboration)
- [low] "Below the progress bar" means directly below the #105 step-count
  `progressPanel` (the amber "N of M steps" bar), inside `planScrollView`, in the
  same full-bleed band. **Why:** the detail view has two progress-ish surfaces —
  the #105 step bar and the modal run log. The run log is the thing being
  de-modalized, and the #105 bar is the only literal "progress bar" in the view,
  so the drawer slots right under it as a cohesive progress region. Recorded
  because the screenshot predates certainty about exact placement.
- [low] The "Show progress" header button becomes the drawer's expand/collapse
  toggle (rather than being removed). **Why:** it is the existing deliberate
  re-entry affordance; repurposing it as the toggle preserves the user's mental
  model and the `shouldAutoOpenProgress` auto-open semantics map cleanly to
  "auto-expand."
- [high] The run-log rendering (`logList`, `summaryRow`, `deniedSummary`,
  `errorBanner`, `lineView`) and the two pure statics are reused rather than
  rewritten. **Why:** they already encode the #081 liveness-gated banner and the
  auto-scroll behavior; duplicating them would risk divergence. Clear
  pattern-match to the existing code.
- [low] Collapsing the drawer for a RUNNING run only hides the body (the run
  keeps going, reachable via the chevron again); only a FINISHED run's explicit
  dismissal triggers `runner.dismiss(...)` + `store.reload()`. **Why:** mirrors
  the sheet's decoupling of dismissal from the run lifecycle (closing never
  stopped the run) and `dismiss(taskID:in:)` already no-ops for a live run.

### Discovered during execution
- [high] `showsProgressDrawer(hasRun: Bool)` takes a plain `Bool` (caller passes
  `runner.run(for:in:) != nil`). **Why:** the task offered the `hasRun:` shape as
  the simplest pure/view-free signature, and it matches #105's statics (plain
  scalars, no `TaskRun`), keeping it testable without constructing a run.
- [high] `progressDrawerStartsExpanded(onAppearRunning:mode:)` delegates straight
  to `shouldAutoOpenProgress`. **Why:** the task explicitly says it may delegate /
  share logic; the `.discuss`-never-expands rule already lives in
  `shouldAutoOpenProgress`, so re-encoding it would risk divergence.
- [high] Kept the state var name `showProgress` (repurposed as the drawer's
  expanded flag) rather than renaming to `progressDrawerExpanded`. **Why:** keeps
  the diff minimal and leaves the `.sheet` reference (removed in segment 2)
  compiling; the doc comment now describes a drawer.
- [high] Factored the shared run-log body into a new `RunLogContents` view struct
  (error banner + logList + lineView + deniedSummary + summaryRow) that BOTH
  `RunProgressSheet` and `progressDrawer` render — single source of truth. **Why:**
  the task mandates no divergent copies; a small shared view is the cleanest
  factoring and lets `RunProgressSheet` keep only its title/header/footer chrome.
- [high] Kept the two pure statics `scrollTarget` / `shouldShowFailureBanner` on
  `RunProgressSheet`; `RunLogContents` calls `RunProgressSheet.scrollTarget` /
  `.shouldShowFailureBanner`. **Why:** their existing tests reference
  `RunProgressSheet.*`; leaving them there keeps those tests compiling (segment 2
  decides the struct's final fate).
- [low] The drawer's expanded log body is capped with a fixed `.frame(maxHeight:
  320)`, mirroring `RunProgressSheet`'s `maxHeight: 520` cap. **Why:** a fixed cap
  bounds a long log so it scrolls within the band without measuring a size and
  feeding it back (#096). 320 is a drawer-appropriate guess, not a value the task
  specified — a candidate for the visual-verification step to tune.
- [low] The drawer band uses a fainter `inProgress.glanceColor.opacity(0.06)`
  background vs `progressPanel`'s `0.12`, so the two stacked amber bands read as
  distinct. **Why:** a UX call the task did not specify; stacking two identical
  amber bands would blur the seam. Candidate for visual tuning.
- [high] The mode-aware title is lifted into a pure static
  `progressDrawerTitle(mode:taskID:)` on `PlanDetailView`, recomputing the
  `RunProgressSheet.title`/`modeVerb` logic. **Why:** the task allowed recomputing
  or lifting; a pure static keeps the wording unit-testable and reusable by the
  drawer without touching the sheet's private `title`.
- [high] (segment 2, step 5) Finished-run dismissal is a "Done" button in the
  drawer header, shown only when `run != nil && !run.isRunning`, that calls
  `runner.dismiss(...)` + `store.reload()` then collapses the drawer
  (`showProgress = false`). It re-checks `!run.isRunning` from the live runner
  before dismissing. **Why:** faithfully relocates the old sheet's `onDisappear`
  side effects (drop finished run + reload). A LIVE run is never dropped by drawer
  interaction — Stop ends it, collapsing (chevron) only hides the body. Placed as
  its own nested button (mirroring the existing Stop button) so its tap does not
  toggle expansion.
- [high] (segment 2, step 7) KEPT `RunProgressSheet` intact — did NOT delete it.
  **Why:** grep showed it is STILL presented as a `.popover` in TWO other call
  sites — `CaptureProgressRows.swift:93` (capture-progress row) and
  `PlanRowActions.swift:128` (card spinner). The research's "modal only presented
  from PlanDetailView" was incomplete: only the PlanDetailView `.sheet` was
  removed. Deleting the struct would break those popovers, so option (b) is forced.
  No dead code results — the struct and its two statics (`scrollTarget`,
  `shouldShowFailureBanner`) stay actively used by the popovers, `RunLogContents`,
  and the existing tests, which all still compile and pass unchanged.

## Changes

### Segment 1 (steps 1–4)
- `Sources/Plans/PlanDetailView.swift`:
  - Added pure static `showsProgressDrawer(hasRun: Bool)` — gates the drawer's
    presence on a run existing (caller passes `runner.run(for:in:) != nil`).
  - Added pure static `progressDrawerStartsExpanded(onAppearRunning:mode:)`,
    delegating to `shouldAutoOpenProgress` (a `.discuss` run never auto-expands).
  - Added pure static `progressDrawerTitle(mode:taskID:)` for the mode-aware
    drawer header title.
  - Repurposed `@State private var showProgress` as the drawer's
    expanded/collapsed flag (doc comment updated); `.onAppear` now sets it from
    `progressDrawerStartsExpanded(...)` and the header "Show progress" button
    toggles it. (The `.sheet` is still present — removed in segment 2.)
  - Built `progressDrawer(_ row:)` — a full-bleed amber band (double-`.frame`
    convention + trailing `Divider()`), with a tappable chevron header
    (title, running spinner, Stop) and an expanded run-log body.
  - Extracted a shared `RunLogContents` view (error banner + log list +
    `lineView` + denial summary + summary row) rendered by BOTH `RunProgressSheet`
    and `progressDrawer` — single source of truth, no duplicated log rendering.
    The expanded log body is capped at `maxHeight: 320` (fixed cap, never a
    measured size — #096).
- `Tests/PlansTests/PlanDetailViewTests.swift`: 6 new tests for
  `showsProgressDrawer` and `progressDrawerStartsExpanded` (TDD, RED→GREEN).
- Tests: `swift build` clean; `swift test --filter PlanDetailViewTests` → 65
  tests, 0 failures.

### Segment 2 (steps 5–8)
- `Sources/Plans/PlanDetailView.swift`:
  - Removed the `.sheet(isPresented: $showProgress)` that presented
    `RunProgressSheet` in the detail view (replaced with an explanatory comment).
  - Relocated the sheet's finished-run side effects (`runner.dismiss(...)` +
    `store.reload()`) into a "Done" button in the `progressDrawer` header, shown
    only when `run != nil && !run.isRunning`. It re-checks liveness, dismisses,
    reloads, and collapses the drawer. A live run is never dismissed by drawer
    interaction; collapsing a live run only hides the body, Stop ends it.
  - Wired `progressDrawer(row)` into `planScrollView` directly after the
    `progressPanel` block, gated by
    `showsProgressDrawer(hasRun: runner.run(for:in:) != nil)` — full-bleed, same
    seam'd region as the step bar ("below the progress bar").
  - **`RunProgressSheet` kept intact** (decision): grep found it is STILL
    presented as a `.popover` from `CaptureProgressRows.swift` and
    `PlanRowActions.swift` (the card-spinner re-entry). The detail-view `.sheet`
    was NOT its only presentation, so the struct + its statics
    (`scrollTarget`, `shouldShowFailureBanner`) remain live — no dead code.
    This task de-modalizes the DETAIL-VIEW progress specifically, as asked.
- Tests: `swift build` clean (only a pre-existing unrelated warning);
  `swift test --filter PlanDetailViewTests` → 65 tests, 0 failures
  (independently re-run and confirmed by the orchestrator).
- Observation (step 8, 👁): deferred to review per yolo/worktree mode. Build
  compiles with the drawer wired in; the app was NOT launched (would block).
  Visual confirmation (drawer below the step bar, chevron expand/collapse, Stop,
  plan stays visible, no modal) is for `/plan-review`.

### Review follow-up (drawer restyle)
- Dropped the amber band tint and the inset rounded log field in the drawer.
  `RunLogContents` gained an `edgeToEdge` mode (with `horizontalPadding` /
  `topPadding`): the log runs full-bleed on one 28pt gutter, and banners/summary
  move to a footer below the log. The popovers keep the default inset style.
- When expanded, the drawer header (title, spinner, Stop/Done) floats over the
  top of the log as a `.bar` material strip; the log scrolls under it via a fixed
  52pt top inset (constant, not measured — #096). Chevron rotates with a snappy
  animation. Full suite: 772 tests, 0 failures.

### Note on scope
This task replaced the modal **sheet** that showed run progress **in the Plan
Detail view** with an inline drawer. The same `RunProgressSheet` content still
appears as a popover from the card-row spinner and capture rows — those are a
different surface and out of this task's scope ("the detail view"). The shared
`RunLogContents` means the drawer and those popovers render identical log bodies.

## Notes
Directly related to #105 (completed), which added the static step-count
`progressPanel` between the header `Divider()` and the body in `planScrollView`.
This task stacks the run-log drawer beneath that panel. Respect the project's
#096 layout-loop-hang discipline: never measure a view's own size and feed it
back into layout — use intrinsic / `.infinity` sizing only. This is a pure-helper
test project (`PlanDetailViewTests.swift` exercises static predicates, no SwiftUI
view instantiation); keep new logic in pure statics so it stays testable.
