# New Plan Form Modal & Tweaks

**ID:** 031
**Created:** 2026-06-06T19:58
**Type:** feature
**Status:** completed
**Branch:** feature/031-new-plan-form-modal-tweaks
**Completed:** 2026-06-06T20:30

## What
New Plans tweaks.

When I tab away from the "New plan" form, and come back, I've lost the pop-up. Clicking again… form is empty.

- Implement form memory if not "captured" when losing focus.
- Add cancel and clear buttons
- Add "elaborate" checkmark and optionally pass "+ elaborate" flag.
- Pop-up should grow as typing continues.

ACTUALLY… let's change to a modal over the entire screen. It would essentially look like a prompt window… ala Claude… but would be tied to a project. And just contain the form.

## Why
The per-card "+" capture popover (`ProjectCard.swift`) loses all unsaved text when
the window loses focus — macOS dismisses `.popover` on window deactivation, so
tabbing away and back drops the in-flight plan description. It also offers no way
to cancel, clear, or opt the new plan into elaboration, and its 96pt box neither
grows nor survives reopen. Promoting capture to a **sheet over the Browser window**
(the Claude-prompt-style modal the description settled on) gives the form a stable,
focus-resilient home tied to a project, restores unsaved drafts, and adds the
cancel/clear/elaborate affordances — all consistent with the app's existing
`.sheet` (PlanDetailView) and UserDefaults-state (PlansStore) patterns.

## How
- [x] Step 1: Add a `captureElaborate` case to `RunMode` (`TaskRunner.swift`) and
      wire its argument plumbing — capture/executeYolo/**captureElaborate** all
      carry a free-text `--description` (extend the `mode == .capture || mode ==
      .executeYolo` branch in `buildProcess(...)` to include the new case).
- [x] Step 2: Add a `captureElaborate` mode to the Node runner
      (`Tools/work-task/run-task.ts`): extend the `Mode` union, the `--mode`
      validation list, the description-required branch in `parseArgs`, and add a
      `buildCaptureElaboratePrompt(description)` that runs `/plan-capture
      "<description>"` then chains into `/plan-elaborate <new-id>` autonomously
      (capture, then elaborate, leave `elaborated`). Rebuild the bundled JS via
      the package's build step so `dist/run-task.js` / the app Resources copy
      update.
- [x] Step 3: Extend `TaskRunner.capture(...)` to take an `elaborate: Bool = false`
      parameter and select the mode: `executeYolo` when `execute`, else
      `captureElaborate` when `elaborate`, else `capture`. Keep the existing
      unique per-run key + finish/reload path unchanged.
- [x] Step 4: Add per-project capture-draft persistence to `PlansStore.swift`,
      following the existing `projectOrderOverride`/`hideEmptyProjects` UserDefaults
      pattern: a `Codable` `CaptureDraft { text; execute; elaborate }`, a
      `captureDrafts: [String: CaptureDraft]` dictionary persisted via a `didSet`
      JSON-encode to a new `captureDraftsKey`, loaded eagerly in `init`, plus
      `draft(for:)` / `setDraft(_:for:)` / `clearDraft(for:)` helpers.
- [x] Step 5: Create `NewPlanModal.swift` — the sheet content view. It holds a
      selected `projectPath`, a project `Picker` (over `store.projects`, sorted
      like the grid), an auto-growing `TextEditor` (min ~96pt, max ~280pt, scroll
      past max) with the "Describe the plan…" placeholder lifted from
      `capturePopover`, "Elaborate" + "Execute" checkboxes, and a bottom button row
      with **Clear** (empties field + resets toggles + clears the draft), **Cancel**
      (dismiss, draft retained), and the **Capture / Elaborate & Capture / Execute**
      submit button (⌘↩). On change of text/toggles/project it saves the draft via
      the store; on submit it calls `runner.capture(projectPath:description:execute:
      elaborate:)`, clears that project's draft, and dismisses.
- [x] Step 6: Present the modal from `BrowserWindow.swift` via
      `.sheet(isPresented:)`, driven by a `@State newPlanProjectPath: String?` (or
      a small `@State showNewPlan` + selected path). Add a global **New Plan**
      `ToolbarItem` button that opens the sheet with a default project selected.
- [x] Step 7: Repoint `ProjectCard.swift`'s `CaptureGlyph` "+" action to open the
      modal pre-selected to that card's project instead of toggling the local
      `.popover`. Surface the open request to `BrowserWindow` (e.g. a closure
      passed into `ProjectCard`, or a shared `@State` on the store) and remove the
      now-dead `capturePopover` / `capturePresented` / `captureText` /
      `captureExecute` popover state. Leave `captureRows` (in-flight capture
      progress rows) untouched.
- [x] Step 8: Add/extend XCTest coverage in `Tests/PlansTests/`: a test that
      `PlansStore` round-trips `captureDrafts` through an isolated
      `UserDefaults(suiteName:)` (set → reload a new store → draft restored; clear
      → gone), and a `TaskRunner`/mode test asserting `capture(..., elaborate:
      true)` selects `.captureElaborate` and that mode carries a `--description`.
- [x] Step 9: 👁 Build and run the app (`./build.sh`), open the Browser window, and
      confirm: the "+" and global button open the sheet; typing then closing the
      window and reopening restores the draft; Clear/Cancel behave as specified;
      the editor grows then scrolls; Elaborate and Execute each kick off the right
      run (verify a captured task lands `elaborated` for the Elaborate path).

## Verification
- `swift test` passes, including the new draft round-trip and mode-selection tests.
- Manual (Step 9): drafts survive focus loss / window reopen per project; Cancel
  retains the draft while Clear wipes it; the editor auto-grows up to its max then
  scrolls; the Elaborate checkbox produces an `elaborated` task and Execute runs
  the yolo pipeline; the per-card "+" and the global "New Plan" button both open
  the sheet with the correct project pre-selected.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/TaskRunner.swift` — add `captureElaborate` RunMode, thread the
      `elaborate` flag through `capture(...)`, extend the description-arg branch.
- [x] `Sources/Plans/PlansStore.swift` — `CaptureDraft` + `captureDrafts`
      UserDefaults persistence and accessor helpers.
- [x] `Sources/Plans/BrowserWindow.swift` — present the `.sheet`, add the global
      "New Plan" toolbar button and the open-request state.
- [x] `Sources/Plans/ProjectCard.swift` — repoint the "+" glyph to open the modal;
      remove the dead inline popover capture state (keep `captureRows`).
- [x] `Sources/Plans/NewPlanModal.swift` — NEW: the sheet form (picker, growing
      editor, Clear/Cancel/submit, draft binding).
- [x] `Tools/work-task/run-task.ts` — add the `captureElaborate` mode + prompt;
      rebuild bundled JS.

### Related Files (may need updates)
- `Tools/work-task/dist/run-task.js` / `Plans.app/Contents/Resources/work-task/run-task.js`
  — regenerated bundle output of the `.ts` change (produced by the build step).
- `Tests/PlansTests/` — new/updated tests (draft round-trip, mode selection).

### UI Affected
- Browser window toolbar — gains a "New Plan" button.
- Project card "+" — now opens the modal sheet instead of an inline popover.
- New full-form sheet over the Browser window with a project picker.

## Assumptions

### Initial (from elaboration)
- The "New plan" form referenced is the new-task capture form surfaced from the
  menu bar glance (Surface A); the request to make it "tied to a project"
  matches the per-project context this app already tracks.
- The final direction supersedes the earlier popup-specific tweaks: the
  end goal is a full-screen modal (Claude-prompt-style) scoped to a project
  that contains the capture form. The earlier bullets (form memory, cancel/clear
  buttons, elaborate checkmark, growing popup) are still desired behaviors that
  should carry over into the modal where they still make sense:
    - Form memory / draft persistence so unsaved input survives focus loss.
    - Cancel and Clear buttons.
    - An "elaborate" checkbox that, when ticked, appends a "+ elaborate" flag
      to the captured task (chaining into elaboration).
    - The input area grows with content (less relevant for a full-screen modal,
      but auto-growing text input should still be supported).
- "+ elaborate" flag maps to the existing plan-capture auto-elaborate trailing
  phrase convention (capture the task, then chain into elaboration).
- No backend/data-contract changes expected; this is a SwiftUI/AppKit UI change.

### Discovered during execution
- [high] Extended `PlanDetailView.swift` (outside this segment's listed impact scope) to handle the new `.captureElaborate` case in two `RunMode` switches: the `modeVerb` (added "Capturing & elaborating") and `title` (treated as a synthetic-id run alongside `.capture`/`.executeYolo`). **Why:** adding the enum case broke the exhaustive `modeVerb` switch (compile error) and the `title` switch's `default` branch would otherwise have rendered a synthetic `capture:/…` id; both are required for the segment to compile and behave correctly.
- [low] Worded `buildCaptureElaboratePrompt` to invoke `/plan-capture "<description>"` then `/plan-elaborate <new-id>` as two explicit sequential steps, modeled on `buildCapturePrompt`/`buildExecuteYoloPrompt`, ending in the `elaborated` state with no execution. **Why:** the segment specified capture-then-elaborate-then-stop but the exact prompt phrasing was a UX/wording call.
- [high] Added `elaborate: Bool = false` to `TaskRunner.capture(...)` with precedence `execute` > `elaborate` > default capture. **Why:** the step specified `.executeYolo` when `execute`, else `.captureElaborate` when `elaborate`, else `.capture`.
- [high] Since `Plans.app` is absent/gitignored in the worktree, only rebuilt `Tools/work-task/dist/run-task.js` (no Resources copy to update). **Why:** matches the segment's stated fallback; verified the new mode appears in the regenerated bundle.
- [high] Made `PlansStore.CaptureDraft` a nested type (`Codable, Equatable`) with an explicit memberwise init, and persisted the `[String: CaptureDraft]` map as JSON `Data` under `captureDrafts`, eager-loaded via `_captureDrafts` in `init`. **Why:** mirrors the existing eager-load-without-re-persist pattern; the segment specified a nested Codable struct and JSON-encoded dictionary persistence. `NewPlanModal` references it as `PlansStore.CaptureDraft` (nested-type scope).
- [low] Auto-grow editor measures a hidden, width-matched `Text(text)` copy in the editor's `.background` via a `GeometryReader` + `EditorContentHeightKey` preference, then clamps `measured + 16` (vertical padding allowance) between 96 and 280pt; past max the `TextEditor` scrolls internally. **Why:** the segment offered the hidden-Text measurement trick as an acceptable robust approach without an NSTextView bridge; the `+16` padding fudge and the 0.5pt change threshold are tuning calls.
- [low] Chose editor min 96pt / max 280pt. **Why:** min matches `ProjectCard.capturePopover`'s fixed 96pt box; max is a sheet-friendly ceiling guess (the segment suggested ~96/~280).
- [low] Project-switch draft swap uses an `isSwitchingProject` guard set true during `loadDraft` and cleared on the next `DispatchQueue.main.async` tick, so the field `.onChange(text/execute/elaborate)` handlers fired by loading don't persist the transient state over the newly-selected project's draft. **Why:** the segment flagged the switch-without-clobber subtlety as needing clean handling; a runloop-deferred guard is the simplest correct approach given SwiftUI's `.onChange` firing on programmatic assignment.
- [low] Sheet frame `.frame(minWidth: 460, minHeight: 320)` with 16pt padding, header "New Plan", and a Clear / Cancel / submit button row (Cancel carries `.cancelAction`, submit carries ⌘↩). **Why:** the segment suggested these exact frame numbers; Cancel's `.cancelAction` (Esc) is a conventional macOS sheet affordance added for parity, draft retained on cancel as specified.
- [high] Presented the modal via `.sheet(item:)` driven by a private `Identifiable` `NewPlanRequest { let id = UUID(); let projectPath: String }` (segment 6) rather than `.sheet(isPresented:)`. **Why:** the segment recommended this approach as cleanest; the fresh per-request `UUID` also means re-tapping the same project's "+" re-presents the sheet instead of being deduplicated by a stable id.
- [low] The global toolbar "New Plan" button uses `square.and.pencil`, sits BEFORE "Link Project…" in the toolbar, opens pre-selected to `BrowserViewModel.sortByStaleness(store.projects).first` (the top-of-grid project under the automatic recency sort), and is `.disabled(store.projects.isEmpty)`. **Why:** segment offered `square.and.pencil`/`plus.rectangle` and "first project / disable when empty"; chose the staleness sort's first (not the manual-order override) since the global button is a generic entry point and staleness is the modal picker's own order.
- [high] Repointed `ProjectCard`'s `CaptureGlyph` "+" to a new required `let onNewPlan: (String) -> Void`, removed the inline `capturePresented`/`captureText`/`captureExecute` state, the `capturePopover` view, the `submitCapture()` method, and the `.popover` modifier (segment 7). Kept `cardLog` (still used by the Elaborate/Execute row-action logging) and all capture-progress-row machinery (`captureRows`/`captureRow`/`progressPopover`/`RunProgressSheet`) untouched. **Why:** the segment specified this exact removal/repoint; `cardLog` and `runner` remain referenced so neither was removed.
- [high] Added a pure `nonisolated static func TaskRunner.captureMode(execute:elaborate:) -> RunMode` (called by `capture(...)`) and a pure `RunMode.usesDescription` flag (consumed by `TaskRun.spawn` in place of the inline `== .capture || ...` check), and unit-tested both for all combos (segment 8). **Why:** the segment preferred extracting the mode-selection as a testable static helper over spawning `node`; made `captureMode` `nonisolated` to match the existing `captureKey` and avoid main-actor isolation errors from the non-`@MainActor` test. `usesDescription` makes the `.captureElaborate` `--description` arg-shape contract unit-testable without a real process.

## Changes
- Steps 1-3 (segment 1): Added `RunMode.captureElaborate` and threaded a free-text
  `--description` for it through `TaskRun.spawn`. Added the matching
  `captureElaborate` mode to the Node runner (`run-task.ts`) with
  `buildCaptureElaboratePrompt` (capture → elaborate → leave `elaborated`); rebuilt
  `dist/run-task.js`. Added `elaborate: Bool = false` to `TaskRunner.capture(...)`
  with mode precedence executeYolo > captureElaborate > capture. Updated
  `PlanDetailView.swift` to handle the new case in its two `RunMode` switches.
- Steps 4-5 (segment 2): Added `PlansStore.CaptureDraft` (Codable) and a
  `captureDrafts: [String: CaptureDraft]` dictionary persisted to UserDefaults via
  `didSet` JSON-encoding, eager-loaded in `init`, with `draft(for:)` /
  `setDraft(_:for:)` / `clearDraft(for:)` helpers. Created `NewPlanModal.swift`: a
  project-scoped capture sheet with a staleness-sorted project Picker, an
  auto-growing TextEditor (96–280pt), Elaborate/Execute checkboxes, and a
  Clear/Cancel/submit row; it restores/persists per-project drafts (swapping drafts
  when the picked project changes) and submits via `runner.capture(execute:elaborate:)`.
- Steps 6-8 (segment 3): Wired `NewPlanModal` into `BrowserWindow` via
  `.sheet(item:)` (an Identifiable `NewPlanRequest`), added a global "New Plan"
  toolbar button (opens pre-selected to the top staleness-sorted project, disabled
  when no projects), and passed an `onNewPlan` closure into each `ProjectCard`.
  Repointed `ProjectCard`'s "+" `CaptureGlyph` to call `onNewPlan(projectPath)` and
  removed the dead inline-popover state (`capturePopover`, `submitCapture`,
  `capturePresented`/`captureText`/`captureExecute`); the in-flight capture progress
  rows (`captureRows`) are untouched. Added tests: a `captureDrafts` round-trip in
  `PlansStoreTests` and mode-selection coverage in `TaskRunnerTests` (extracted pure
  `TaskRunner.captureMode(execute:elaborate:)` + `RunMode.usesDescription` helpers
  for testability; `spawn` now consults `usesDescription`).
- Test status: `swift build` clean; `TaskRunnerTests` 22/22 pass; new draft
  round-trip passes. 4 PRE-EXISTING `PlansStoreTests` failures (lowercase vs
  titleized project names from #020) are unrelated to #031 and left as-is.

## Notes
Captured autonomously via /plan-capture. Capture-only — left in pending state;
not elaborated or executed. The description shifted mid-way from incremental
popup tweaks to a full-screen modal redesign; elaboration should reconcile
which of the earlier tweaks remain in scope for the modal.
