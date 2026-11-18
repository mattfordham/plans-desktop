# Project Detail As Modal Pane Instead Of Window

**ID:** 073
**Created:** 2026-08-27T18:59
**Type:** feature
**Status:** completed
**Branch:** feature/073-project-detail-as-modal-pane-instead-of-w
**Completed:** 2026-08-31T15:09

## What
Instead of opening new window for project detail, let's have a large modal pane open. Blur closes it.

## Why
Adds value by keeping plan detail in-context: today tapping a plan row spawns a
separate OS window (`WindowGroup "plan-detail"`), which scatters focus across
windows and leaves orphaned detail windows behind. A large modal pane that
overlays the browser window — dismissed by clicking away ("blur") — keeps the
user anchored in one window and makes "view a plan, then get back to the grid"
a single, self-closing gesture.

## How Summary
Replace the standalone per-plan detail window with an in-window modal overlay.
Drive it from a `TaskRow.ID?` presentation state in `BrowserWindow`; a plan-row
tap sets that state (via an `onOpenDetail` closure threaded down into
`ProjectCard`, mirroring the existing `onNewPlan` plumbing) instead of calling
`openWindow(id: "plan-detail", …)`. `BrowserWindow.body` gains an `.overlay`
containing a dimming scrim (tap-away = "blur closes it", the authoritative
dismiss) with the existing, Close-button-free `PlanDetailView` presented large
in a rounded card on top. The now-unused `WindowGroup("Plan", id:
"plan-detail")` scene and `ProjectCard`'s `@Environment(\.openWindow)` are
removed.

**Files of note:**
- `Sources/Plans/BrowserWindow.swift` — host window; add `@State detailRowID`, the `.overlay` scrim + pane, and pass `onOpenDetail` into each `ProjectCard` from `cardCell(for:)`.
- `Sources/Plans/ProjectCard.swift` — add an `onOpenDetail: (TaskRow.ID) -> Void` closure; change `OpenDetailOnTap` to call it instead of `openWindow`; drop the now-dead `@Environment(\.openWindow)`.
- `Sources/Plans/PlansApp.swift` — remove the standalone `WindowGroup("Plan", id: "plan-detail", …)` scene (lines 141–154) once nothing calls `openWindow(id: "plan-detail", …)`.
- `Sources/Plans/PlanDetailView.swift` — reused unchanged as the pane content; already Close-button-free and store-resolving (only its doc comment about the window's close control may need a note).

## How
- [x] Step 1: Add presentation state to `BrowserWindow`: `@State private var detailRowID: TaskRow.ID? = nil` (mirrors the `newPlanRequest` pattern at `BrowserWindow.swift:67`). UI-only, transient — do NOT persist it to UserDefaults.
- [x] Step 2: Thread an `onOpenDetail: (TaskRow.ID) -> Void` closure into `ProjectCard`. Declare it as a stored `let` alongside `onNewPlan` (`ProjectCard.swift:50`), passed through the memberwise init; in `cardCell(for:)` (`BrowserWindow.swift:621`) supply `{ id in detailRowID = id }`. Remove the now-unused `@Environment(\.openWindow)` from `ProjectCard` (`ProjectCard.swift:54`).
- [x] Step 3: Change `OpenDetailOnTap` (`ProjectCard.swift:992–1001`) to invoke the injected `onOpenDetail(row.id)` closure instead of `openWindow(id: "plan-detail", value: row.id)`. Update the four `.modifier(OpenDetailOnTap(...))` call sites (`ProjectCard.swift:607,613,641,659`) to pass the closure instead of `openWindow`.
- [x] Step 4: Add the modal overlay to `BrowserWindow.body` (near the existing `.sheet` at `BrowserWindow.swift:219`). When `detailRowID != nil`, render a dimming scrim `Color.black.opacity(~0.35).ignoresSafeArea()` with `.onTapGesture { detailRowID = nil }` (the "blur closes it" click-away), and above it `PlanDetailView(rowID: detailRowID)` in a large rounded card (reuse the ~900×600 intent from the removed scene, clamped to the window). Guard so scrim taps close but taps INSIDE the pane do not (put the tap-catcher only on the scrim, and give the pane its own background/`contentShape`). Animate open/close with a `.transition`/`withAnimation`.
- [x] Step 5: Add keyboard + affordance dismissal: an Esc-key handler (e.g. `.onExitCommand { detailRowID = nil }`) so the pane is keyboard-dismissible, and confirm the pane still reads cleanly without a Close button (or add a small explicit close control if the scrim alone feels undiscoverable — see Assumptions).
- [x] Step 6: Remove the standalone detail scene: delete the `WindowGroup("Plan", id: "plan-detail", for: TaskRow.ID.self)` and its `.defaultSize(...)` from `PlansApp.swift:141–154`. Grep the tree to confirm no remaining `openWindow(id: "plan-detail"...)` call sites; update the stale doc comments in `BrowserWindow.swift:210–211` and `ProjectCard.swift:22,52,572` that describe "a separate window".
- [x] 👁 Step 7: Build and run the app (`./build.sh`), tap a plan row, confirm the large modal pane opens over the grid, click outside it to confirm it closes, press Esc to confirm keyboard dismiss, and confirm no stray "Plan" window can still be opened.

## Verification
- Tapping a plan row content cell opens the plan detail as a large pane overlaid on the browser window (NOT a new OS window).
- Clicking anywhere outside the pane (on the dimming scrim) closes it; clicking inside the pane does not.
- Pressing Esc closes the pane.
- No standalone "Plan" window can be opened any more; there are no orphaned detail windows.
- `swift build` succeeds and `swift test` passes (no references to the removed `plan-detail` window remain; `ProjectCard` compiles without `@Environment(\.openWindow)`).
- Existing New Plan modal (`.sheet`), drag/drop reorder, focus mode, and run-progress popovers continue to work unchanged.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/BrowserWindow.swift` — add `detailRowID` state, the `.overlay` scrim + pane, Esc handling, and pass `onOpenDetail` into `ProjectCard` from `cardCell(for:)`.
- [x] `Sources/Plans/ProjectCard.swift` — add `onOpenDetail` closure, rewire `OpenDetailOnTap` and its four call sites, remove `@Environment(\.openWindow)`, update stale comments.
- [x] `Sources/Plans/PlansApp.swift` — remove the `WindowGroup("Plan", id: "plan-detail")` scene and its `.defaultSize`.

### Related Files (may need updates)
- `Sources/Plans/PlanDetailView.swift` — reused unchanged as pane content; only its doc comment referencing "its own window / the window's close control" may want a note, and a close affordance decision (see Assumptions).
- `Sources/Plans/PlansStore.swift` — only touched IF the tap trigger is routed through the store (`newPlanTrigger`-style) instead of a `BrowserWindow` `@State` + closure; the closure approach (chosen) needs no store change.

### UI Affected
- Plan-row tap in `ProjectCard` — now opens an in-window pane instead of a window.
- `BrowserWindow` — gains a dimming scrim + modal pane overlay.

## Assumptions

### Initial (from elaboration)
- [high] "Project detail" refers to the existing per-plan `PlanDetailView`, not a new project-level view. **Why:** research found no `projectDetail`/`ProjectDetail` concept anywhere in the codebase; the only detail surface is the per-plan window opened on a row tap, which is exactly what "opening new window for project detail" describes.
- [low] "Blur closes it" is implemented as click-away on a dimming scrim (plus Esc), NOT as the browser window losing key/focus to another app (`didResignActive`/`didResignKey`). **Why:** the source description is ambiguous; the scrim/click-away reading is the natural SwiftUI-overlay behavior, matches "large modal pane," and avoids introducing AppKit key-window tracking (an over-scoped complexity the research explicitly warned against). App-level focus-loss dismissal would surprise users who alt-tab away and expect the pane to persist.
- [low] The standalone `WindowGroup("Plan", id: "plan-detail")` scene is fully removed rather than kept as an alternative. **Why:** the task says "instead of opening new window," implying replacement; keeping both risks dead code and a stray reopenable window. The cost is losing side-by-side multi-plan viewing that separate windows technically allowed — judged acceptable for a "modal pane" UX.
- [low] Presentation is driven by a `BrowserWindow` `@State detailRowID` + an `onOpenDetail` closure threaded through `ProjectCard`, rather than store-based `newPlanTrigger`-style signaling. **Why:** the tap originates inside `BrowserWindow`'s own view tree (via `cardCell`), so local `@State` + closure is the lighter, established pattern (`onNewPlan` does exactly this); the store trigger is only needed to cross scene boundaries, which this does not.
- [low] Chose a custom `.overlay` + scrim over `.sheet`/`.popover`. **Why:** research confirmed neither `.sheet` nor `.popover` gives "large pane + dismiss-on-click-away"; a sheet needs explicit dismissal and a popover renders as a small anchored bubble. The overlay scrim is the only option matching both "large" and "blur/click-away closes."
- [low] A small explicit close affordance MAY be added if scrim-only dismissal feels undiscoverable, but the default is scrim + Esc only. **Why:** the description only specifies "blur closes it"; adding an always-visible close button is a judgement call left to the execution observation step (Step 7) rather than assumed up front.

### Discovered during execution
- [high] `PlanDetailView`'s init takes `rowID: TaskRow.ID?` (optional), matching the removed `WindowGroup` scene's `PlanDetailView(rowID: rowID)` usage. **Why:** confirmed by reading `PlanDetailView.swift` (`let rowID: TaskRow.ID?`) and `PlansApp.swift:147`; the overlay passes `detailRowID` (a `TaskRow.ID?`) directly, so no unwrap is needed.
- [low] The `onOpenDetail: (TaskRow.ID) -> Void` stored property is declared AFTER `onNewPlan` in `ProjectCard`. **Why:** the existing `cardCell` call site used a trailing closure for `onNewPlan`; adding a new last parameter would silently rebind that trailing closure to `onOpenDetail`. To avoid the ambiguity I rewrote the `cardCell` call site to pass BOTH `onNewPlan:` and `onOpenDetail:` explicitly (no trailing closure), which is unambiguous regardless of declaration order.
- [low] The overlay is attached as an `.overlay { if detailRowID != nil { detailOverlay } }` on `cardGrid` (beside the existing New Plan `.sheet`), with a `.scale+.opacity` transition on the pane, `.opacity` on the scrim, and a `body`-level `.animation(.easeInOut(duration: 0.18), value: detailRowID)` driving both. **Why:** `.overlay` floats over the grid without disturbing its layout; a single `value:`-keyed animation animates present/dismiss (including scrim click-away) symmetrically without wrapping every mutation in `withAnimation`.
- [low] Pane sized `.frame(maxWidth: 900, maxHeight: 600)` with `.padding(40)`, opaque `.background(.background, in: RoundedRectangle(cornerRadius: 16))`, a `.separator` stroke, and `.shadow(radius: 30)`. **Why:** matches the removed scene's 900×600 `.defaultSize` intent while clamping to the window and giving the pane a clearly-modal card look; the opaque background + `.contentShape(Rectangle())` ensures pane taps do not fall through to the dismissing scrim.
- [high] Removed `@Environment(\.openWindow)` from `ProjectCard` entirely. **Why:** after Step 3, `OpenDetailOnTap` no longer references `openWindow`, and a repo search confirmed no other `openWindow` use remained in `ProjectCard`; leaving the unused environment value would be dead code.
- Note: `PlansApp.swift`'s standalone `WindowGroup("Plan", id: "plan-detail")` scene removal is Step 6 (a later segment) and was intentionally left untouched in this segment. It is now unused-but-present; the build still passes.

### Segment 2 (steps 5-6)
- [low] Kept the DEFAULT close affordance: scrim click-away + Esc only, with NO always-visible Close button. **Why:** the task's Assumptions set this as the default and made an explicit control a judgement call. Reading the pane, the modal card sits inside 40pt of padding over a 35%-black scrim, so a large, obviously-clickable dimmed region frames it on all sides — the click-away target is visually self-evident, and Esc is the standard macOS modal dismissal. `PlanDetailView` also already documented itself as carrying no Close button. Adding one would be the first piece of pane chrome and would push scope into restyling the detail header.
- [high] Left `.onExitCommand { detailRowID = nil }` attached to `detailOverlay` (unguarded) rather than adding an `if detailRowID != nil` guard or moving it to `body`. **Why:** `detailOverlay` is only instantiated inside `body`'s `.overlay { if detailRowID != nil { ... } }`, so the handler exists ONLY while the pane is presented — it is structurally impossible for it to fire when the pane is down, making a guard redundant. Attaching it at `body` level instead would have been wrong: it would swallow Esc for the New Plan `.sheet` and the plain dashboard.
- [low] Chased stale "detail window" doc comments beyond the listed lines into `PlanDetailView.swift:133` ("closing the detail window ... does NOT stop the run" -> "dismissing the detail pane") and `ProjectCard.swift:711` ("opening the row's detail window" -> "detail overlay pane"). **Why:** both described the removed window in PRESENT tense as a live affordance, so they now misdescribe reality. I deliberately LEFT the several comments that frame the window as history ("replaces the former...", "was removed") — those are accurate and carry useful provenance.
- [low] Added one test (`testResolveRowReturnsNilWhenEveryProjectDisappears` in `BrowserWindowTests`) rather than testing the pane's presentation directly. **Why:** `detailRowID` is private `@State` and `onOpenDetail` is a closure on a `View` struct — neither is reachable without inventing a testing-only abstraction, and the suite's convention is to test pure static helpers, never SwiftUI rendering. The one real new invariant is that the pane feeds an OPTIONAL `detailRowID` straight into `PlanDetailView(rowID:)`, so resolution must stay total over stale ids while the pane is open (the store re-polls every 5s underneath it). Mutation-checked: inverting the assertion fails the test.

## Changes

### Segment 1 (steps 1-4)
- **BrowserWindow.swift** — added `@State private var detailRowID: TaskRow.ID? = nil` after `newPlanRequest`; added a `detailOverlay` computed view (dimming scrim `Color.black.opacity(0.35)` + rounded opaque `PlanDetailView(rowID:)` card, maxWidth 900 / maxHeight 600, padding 40, separator stroke, shadow, `.contentShape(Rectangle())` so pane taps don't fall through), attached via `.overlay` on `cardGrid` next to the New Plan `.sheet`; scrim-only click-away dismissal; `body`-level `.animation(value: detailRowID)` for open/close. `cardCell(for:)` now constructs `ProjectCard(onNewPlan:onOpenDetail:)` with `onOpenDetail: { id in detailRowID = id }`.
- **ProjectCard.swift** — added `let onOpenDetail: (TaskRow.ID) -> Void`; removed unused `@Environment(\.openWindow)`; `OpenDetailOnTap` now stores `onOpenDetail` and calls `onOpenDetail(row.id)` instead of `openWindow(id:value:)`; updated all four `.modifier(OpenDetailOnTap(...))` call sites and the `#Preview`; refreshed stale "separate window" doc comments.
- Build: `swift build` clean (pre-existing unrelated PlansStore Sendable warnings only).

### Segment 2 (steps 5-6)
- **Step 5 (verified, not rewritten)** — `.onExitCommand { detailRowID = nil }` was already present at `BrowserWindow.swift:372`, attached to `detailOverlay`. Confirmed correctly scoped: `detailOverlay` is only instantiated inside `body`'s `.overlay { if detailRowID != nil { ... } }`, so the handler exists only while the pane is up — no guard needed, and it cannot swallow Esc for the New Plan `.sheet` or the bare dashboard. Kept the default scrim + Esc dismissal with no Close button.
- **Step 6 (scene removal verified; doc comments completed)** — the `WindowGroup("Plan", id: "plan-detail", for: TaskRow.ID.self)` scene and its `.defaultSize(width: 900, height: 600)` are removed from `PlansApp.swift`, replaced by an explanatory comment. Grep confirms no remaining `openWindow(id: "plan-detail", ...)` code call sites anywhere in `Sources/` or `Tests/` (`MenuBarView.swift`'s `openWindow(id: "browser")` is unrelated and untouched).
- **Stale doc comments updated** — rewrote present-tense descriptions of the removed window in `BrowserWindow.swift` (header doc), `ProjectCard.swift:1001` and `:711`, `PlanDetailView.swift:24` and `:133`, and `PlansApp.swift`. Comments that frame the window as *history* ("replaces the former...", "was removed") were deliberately left as accurate provenance.
- **Tests** — `Tests/PlansTests/BrowserWindowTests.swift`: added `testResolveRowReturnsNilWhenEveryProjectDisappears`, covering the one real new invariant (the pane feeds an optional `detailRowID` into `PlanDetailView(rowID:)`, so row resolution must stay total over ids that go stale while the pane is open, since the store re-polls every 5s underneath it). Mutation-checked. No compilation breakage existed — tests never construct `ProjectCard`.
- Build: `swift build` complete, zero warnings. Targeted tests: `BrowserWindowTests` 85 passed, `ProjectCardTests` 23 passed, `PlanDetailViewTests` 9 passed. No full-suite run.

## Notes
_Additional context_
