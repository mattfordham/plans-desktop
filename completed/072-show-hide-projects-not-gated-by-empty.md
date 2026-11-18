# Consolidate project visibility into one labelled view mode

**ID:** 072
**Created:** 2026-08-27T00:00
**Type:** feature
**Status:** completed
**Branch:** feature/072-show-hide-projects-not-gated-by-empty
**Completed:** 2026-08-31T14:52

## What
I want to be able to show/hide projects in a way that is not gated by empty projects.

**Scope evolved during review.** The original ask was a per-project hide decoupled
from the "Hide Empty" gate. Building it exposed the real problem: FOUR overlapping
visibility mechanisms had accreted (Hide Empty #021, Star #035, Hide #072, Focus
#067), and star was not even a filter — only an exception to Hide Empty, so it did
nothing while that gate was off. Unlabeled toolbar glyphs could not express the
difference, which the user flagged twice with screenshots.

What shipped instead: a single labelled `ProjectViewMode` control with three rules
the user stated directly — **All** is all, **Active** is anything with a positive
plan count, **Starred** is only starred regardless of count. Per-project hide was
then deleted entirely as a fourth concept fitting none of those rules. Curation is
starring plus the Starred mode.

## Why
Today the only way to make a project card disappear from the browser is the global
"Hide Empty" toggle (#021), which is gated entirely by emptiness. But the deeper
problem is that the dashboard's visibility rules had grown one task at a time with
no single mental model covering them, leaving a row of unlabeled glyphs whose
differences were unreadable at a glance. Consolidating them into one named control
makes the model legible: the toolbar states which projects it is showing, in words.

## How Summary
Add a per-project "hidden" preference to `PlansStore` — a persisted
`Set<String>` of project paths (`hiddenProjectPaths`) modelled exactly on the
existing starred-paths feature (#035) — and apply it as its OWN unconditional
filter step in `BrowserWindow.sortedProjects`, entirely outside the
`if store.hideEmptyProjects` block, so hiding is fully independent of emptiness.
Each `ProjectCard` gets an `eye.slash` hide toggle (mirroring the star/focus
glyphs), and a new "Show Hidden" toolbar toggle in `BrowserWindow` (mirroring the
"Hide Empty" toolbar button) provides the reveal path. Hide is a browser-only
(Surface B) concern; the menu-bar glance and its counts are left untouched.

**Files of note:**
- `Sources/Plans/PlansStore.swift` — new `hiddenProjectPaths` persisted preference, its key, `init` load, and a `toggleHidden` mutator + a transient `showHidden` reveal flag.
- `Sources/Plans/BrowserWindow.swift` — new pure `BrowserViewModel.visibleUnderHidden` predicate, its wiring into `sortedProjects`, and the "Show Hidden" toolbar toggle.
- `Sources/Plans/ProjectCard.swift` — new `hideToggle` view + `HideToggleGlyph` struct in the card footer.
- `Tests/PlansTests/PlansStoreTests.swift` — persistence round-trip test for `hiddenProjectPaths`.
- `Tests/PlansTests/BrowserWindowTests.swift` — pure-predicate tests for `visibleUnderHidden` and its independence from emptiness.

## How
- [x] Step 1: In `Tests/PlansTests/BrowserWindowTests.swift`, add failing pure-predicate tests for a new `BrowserViewModel.visibleUnderHidden(_:hiddenProjectPaths:)`: a project whose path is in the set is hidden (returns `false`), one whose path is absent is visible (returns `true`), and — the crux — a NON-empty project (has outstanding work) whose path is in the set is STILL hidden (proving independence from emptiness). Mirror the existing `testVisibleUnderHideEmpty…` cases.
- [x] Step 2: In `Tests/PlansTests/PlansStoreTests.swift`, add a failing persistence round-trip test for `hiddenProjectPaths` mirroring `testStarredProjectPathsPersistAcrossStoreInstances`: mutate the set on a store over an isolated `UserDefaults(suiteName:)`, build a fresh store over the same defaults, assert the value round-trips. Add a `toggleHidden` unit test (insert then remove).
- [x] Step 3: In `Sources/Plans/PlansStore.swift`, add `var hiddenProjectPaths: Set<String> = []` with a `didSet` persisting `Array(hiddenProjectPaths)` to a new `private static let hiddenProjectsKey = "hiddenProjects"`; place both next to the starred equivalents. Load eagerly in `init` via `_hiddenProjectPaths = Set(defaults.stringArray(forKey: Self.hiddenProjectsKey) ?? [])`. Add a `toggleHidden(_ path: String)` mutator mirroring the starred toggle. NEVER write to `.plans/` (§2 read-only).
- [x] Step 4: In `Sources/Plans/PlansStore.swift`, add a transient (non-persisted, in-memory) `var showHidden: Bool = false` — the "reveal hidden cards" flag driving the toolbar toggle. Deliberately NO `didSet`/`init` load (like `newPlanTrigger`), since reveal is a transient view action, not a saved preference.
- [x] Step 5: In `Sources/Plans/BrowserWindow.swift`, add the pure `static func visibleUnderHidden(_ project: ProjectTasks, hiddenProjectPaths: Set<String>) -> Bool { !hiddenProjectPaths.contains(project.projectPath) }` to `BrowserViewModel`, modelled on `visibleUnderFocus`. Confirm Step 1's tests pass.
- [x] Step 6: In `Sources/Plans/BrowserWindow.swift` `sortedProjects`, insert the hidden filter as its OWN step, applied only when `!store.showHidden`, and placed OUTSIDE the `if store.hideEmptyProjects` block (before the focus filter): `let hiddenResolved = store.showHidden ? hideEmptyResolved : hideEmptyResolved.filter { BrowserViewModel.visibleUnderHidden($0, hiddenProjectPaths: store.hiddenProjectPaths) }`, then run the focus filter over `hiddenResolved`. This decoupling from the empty-gate is the crux of the task.
- [x] Step 7: In `Sources/Plans/ProjectCard.swift`, add a `HideToggleGlyph` struct mirroring `FocusToggleGlyph` (`.plain` Button, `eye.slash` SF Symbol, opacity conveys state, hover background/cursor treatment) and a `hideToggle` computed view that reads `store.hiddenProjectPaths.contains(project.projectPath)` and calls `store.toggleHidden(project.projectPath)`. Add `hideToggle` to the card footer HStack alongside `focusToggle`/`starToggle`. Help text: "Hide project" / "Unhide project".
- [x] Step 8: In `Sources/Plans/BrowserWindow.swift` toolbar, add a "Show Hidden" toggle `Button` mirroring the "Hide Empty" chrome exactly (plain Button, accent-tinted when active): toggles `store.showHidden`; glyph `eye.slash` when revealing/`eye` otherwise; help "Reveal hidden projects". This is the reveal path so hidden cards can be un-hidden.
- [x] 👁 Step 9: ~~Build and run the app; verify a project can be hidden and reappears via "Show Hidden"...~~ **OBSOLETE** — every mechanism this step verifies (per-project hide, "Show Hidden", "Hide Empty") was deleted during this task. Superseded by manual verification of the replacement: the labelled All/Active/Starred view-mode control, confirmed by the user against the running build.
- [x] Step 10: Run `swift test` and confirm the full suite (including the new tests) passes.

## Verification
- `swift test` passes (404 tests). New: `visibleUnderViewMode` predicate tests for all three modes, incl. the crux that a starred-but-empty project is filtered by `.active`, and that `.starred` filters an unstarred project WITH work; plus `projectViewMode` persistence round-trip.
- Manual (Surface B): the toolbar shows ONE view-mode control rendering its current state as text (All / Active / Starred). Switching modes reflows the grid: All shows every project; Active shows only projects with a positive plan count; Starred shows only starred projects regardless of count. The selected mode survives an app restart.
- Manual (Surface B): the project card footer has exactly two glyphs — focus and star. No hide/eye glyph remains anywhere, and the toolbar has no reveal control.
- Manual (Surface A): the menu-bar glance and `iconSpaceCounts` are unchanged — view mode is browser-only and does not affect machine-wide counts.
- No writes to any `.plans/` directory occur (§2 read-only); `projectViewMode` and `starredProjectPaths` persist only to `UserDefaults`.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/PlansStore.swift` — add `hiddenProjectPaths` (persisted) + `hiddenProjectsKey` + `init` load + `toggleHidden`, and the transient `showHidden` flag.
- [x] `Sources/Plans/BrowserWindow.swift` — add `BrowserViewModel.visibleUnderHidden`, wire it into `sortedProjects` as its own unconditional filter, add the "Show Hidden" toolbar toggle.
- [x] `Sources/Plans/ProjectCard.swift` — add `HideToggleGlyph` + `hideToggle` view in the card footer.
- [x] `Tests/PlansTests/BrowserWindowTests.swift` — pure-predicate tests for `visibleUnderHidden`.
- [x] `Tests/PlansTests/PlansStoreTests.swift` — persistence round-trip + `toggleHidden` tests.

### Related Files (may need updates)
- `Sources/Plans/MenuBarView.swift` — reads `store.projects`/`iconSpaceCounts` directly; intentionally NOT changed (hide is browser-only). Listed so the "leave untouched" decision is explicit.

### Endpoints/UI Affected
- Browser window project card footer — new `eye.slash` hide toggle glyph per card.
- Browser window toolbar — new "Show Hidden" toggle beside "Hide Empty".

## Assumptions

### Initial (from elaboration)
- [low] Reveal mechanism is a "Show Hidden" toolbar toggle (transient `store.showHidden` flag) mirroring the existing "Hide Empty" toolbar button, rather than a context menu or a hidden-projects list/badge. **Why:** research flagged this as the main UX gap; the toolbar-toggle pattern already exists (#021/#033) and is the smallest consistent affordance.
- [low] Explicit hide takes precedence over both "Hide Empty" starred-exception and Focus mode — a hidden project is filtered out regardless of starred/empty state, and the hidden filter is applied before the focus filter. **Why:** an explicit user hide is the strongest signal of intent; research recommended explicit hide winning over the starred "keep visible" exception.
- [low] Hide is a browser-only (Surface B) concern: the menu-bar glance and `iconSpaceCounts` are left untouched, so hidden projects still contribute to machine-wide counts. **Why:** `MenuBarView` reads `store.projects` directly; scoping hide to the browser is the least-surprising, smallest-blast-radius choice and keeps the glance a complete cross-project count.
- [low] The per-card hide glyph uses `eye.slash` with opacity-conveyed state (mirroring `StarToggleGlyph`/`FocusToggleGlyph`), and the toolbar "Show Hidden" toggle uses `eye.slash`/`eye`. **Why:** consistent with existing glyph vocabulary; research warned the toolbar "Hide Empty" already uses `eye`/`eye.slash`, but the per-card context and distinct help text disambiguate.
- [low] `hiddenProjectPaths` is a `Set<String>` keyed by `ProjectTasks.projectPath`, persisted to `UserDefaults` only (never `.plans/`), modelled exactly on `starredProjectPaths` (#035). **Why:** research identified starred as a near-identical template and warned against a new per-project model field or `.plans/`-side persistence (§2 read-only).

### Discovered during execution
- [low] Placed `hideToggle` at the LEADING edge of the footer's trailing glyph cluster, giving hide -> focus -> star. **Why:** the task specified only "alongside `focusToggle`/`starToggle`", not an order. Appending after `starToggle` would have shifted the star off the card's trailing corner, where it has sat since #035; prepending leaves the established focus/star pair exactly where users expect it and adds the new affordance at the cluster's inner edge.
- [low] Reused the `eye.slash` SF Symbol for BOTH the card's hide glyph and the toolbar's "Show Hidden" active state. **Why:** the task named `eye.slash` for both. It does mean `eye.slash` denotes "this card is hidden" on a card and "hidden cards are being revealed" in the toolbar, but the toolbar pairing mirrors the adjacent "Hide Empty" control (which uses the same `eye`/`eye.slash` swap), so the toolbar convention is internally consistent even though the two surfaces read slightly differently.
- [low] Placed the "Show Hidden" toolbar item immediately AFTER "Hide Empty" and before the card-layout toggle. **Why:** the task said "beside it" without fixing a side. The two visibility filters now sit adjacent, keeping the layout toggle last as the odd one out.
- [high] Wrote `HideToggleGlyph` as a third near-verbatim copy of `StarToggleGlyph`/`FocusToggleGlyph` rather than extracting a shared generic glyph view. **Why:** the task explicitly asked to mirror `FocusToggleGlyph`, and the file's established pattern is one small self-contained struct per toggle. Extracting a common abstraction would be a refactor outside this task's scope and would touch #035/#067 code.

- [low] Chose a `Menu` over a click-to-cycle `Button` or a segmented `Picker` for the view-mode control. **Why:** the task gave latitude and asked to prioritize legibility of the current state. With THREE states a cycling button forces the user to step through modes they don't want, and never reveals what the other options are; a segmented `Picker` shows all three but eats far more toolbar width than the surrounding square glyph buttons. A `Menu` names all three on open, jumps straight to one, and its own label can render the current mode as text in roughly one button's width. The enum still ships `next` for a cycling affordance if the menu is ever revisited.
- [low] SF Symbols per mode: `.all` = `square.grid.2x2`, `.active` = `bolt.fill`, `.starred` = `star.fill`. **Why:** the task said "pick sensible distinct" symbols. These are three unrelated metaphors (a full grid of cards, energy/work in motion, the existing star), so they stay distinguishable at toolbar size — the failure mode this whole task exists to fix was near-identical glyphs. `star.fill` deliberately matches the card footer's starred glyph so the filter reads as "the things I starred". The label text carries the meaning regardless, so the symbols are decorative reinforcement rather than the sole signal.
- [low] `.all` is NOT accent-tinted; `.active` and `.starred` are. **Why:** the tint is reserved to signal "a filter is currently narrowing what you see". `.all` is the default and hides nothing, so tinting it would leave the control permanently lit and drain the tint of meaning. This matches the incumbent card-layout toggle, which tints only in the non-default `.fit` mode.
- [low] Cycle order `all -> active -> starred -> all` on `ProjectViewMode.next`. **Why:** the task named this order. It runs least-filtered to most-filtered before wrapping, which is the intuitive direction for a progressive narrowing. Currently unused by the `Menu`-based toolbar control but kept on the enum as the canonical ordering (and it matches `allCases` declaration order, which drives the menu's item order).
- [high] `.active` drops the old `|| isStarred` rescue clause outright, so a starred-but-empty project is now filtered out in `.active` where "Hide Empty" would have kept it. **Why:** the task called for exactly this and it is the point of the redesign. Star was previously only an EXCEPTION to a gate, so it did nothing whenever the gate was off; making `.starred` a real filter means curated projects have their own mode, and `.active` can then mean literally "has outstanding work" with no hidden carve-outs. Pinned by `testVisibleUnderViewModeActiveFiltersStarredButEmptyProject`.
- [high] Per-project hide stays a separate, unconditional filter step AFTER the view mode rather than being folded into `ProjectViewMode`. **Why:** an explicit per-project hide is a stronger, more specific signal than a global mode and must win in every mode, including `.all`. Folding it in would have made "hidden" a fourth mutually-exclusive mode, which is precisely the conflation this task set out to undo. Pinned by `testHiddenProjectIsFilteredEvenUnderAllViewMode`.

### Toolbar affordance rework (user-reported glyph collision)
- [low] Rendered the count as inline `Label` text via `Label("\(count)", systemImage:)` rather than a badge or overlay bubble. **Why:** the spec left the exact rendering open. `Label` is what every neighbouring toolbar button already uses, so the count inherits the identical square footprint, accent tint, and hover chrome for free; a custom badge would need hand-tuned geometry and would be the only bespoke toolbar control in the window.
- [low] The count sits AFTER the glyph (SF Symbol leading, number trailing), which is `Label`'s natural order. **Why:** the spec did not fix a side. Leading glyphs keep the toolbar's icon rhythm aligned with the four other glyph-first buttons, so the row still scans as a strip of icons with one carrying a numeric annotation.
- [low] Chose polarity `rectangle` = active/revealing (hidden cards currently shown), `rectangle.slash` = inactive (hidden cards suppressed). **Why:** the spec named this polarity, and it matches the incumbent "Hide Empty", where the SLASHED variant means "something is being withheld". The slash consistently denotes suppression across both controls even though they no longer share a metaphor.
- [low] Help text swaps on state rather than always naming the count: "Reveal N hidden project(s)" when inactive, "Hide revealed projects" when active. **Why:** once revealed, the cards are on screen and countable, so repeating N adds nothing; the actionable phrasing describes what the click will DO in each direction. Singular/plural is selected on `count == 1`.
- [high] Suppressed the whole `ToolbarItem` (a `if hiddenCount > 0` guard inside the `@ToolbarContentBuilder`) rather than disabling or dimming it at zero. **Why:** the spec asked for zero-cost absence in the common case. A disabled control would still occupy the toolbar and still pose the "what does this eye/rectangle do?" question this rework exists to eliminate.
- [high] `hiddenProjectCount` resolves the hidden set against LIVE `projects` instead of returning `hiddenProjectPaths.count`. **Why:** the persisted set retains paths for unregistered/deleted projects. Counting it raw would render a control advertising N hidden projects that reveals nothing when clicked — the same stale-state class of bug already defended against for `focusedProjectPath` in `sortedProjects`. A dedicated test (`testHiddenProjectCountIgnoresStalePathWithNoLiveProject`) pins this.

### Hide feature deletion (user decision)
- [high] Deleted per-project hide ENTIRELY rather than deprecating, gating, or reimplementing it. **Why:** the user decided hide is a leftover FOURTH visibility concept that fits none of the three stated `ProjectViewMode` rules (All is all; Active is a positive plan count; Starred is starred regardless of count). Because it applied across all three modes it needed its own card glyph AND its own toolbar control, which is what produced the glyph soup the redesign set out to fix. Accepted consequence, stated by the user: there is no longer any way to permanently banish a specific project — every registered project appears under All and Active, and curation is done by starring plus the Starred mode. This DIRECTLY REVERSES the earlier assumption on line 91 ("per-project hide stays a separate, unconditional filter step"), and its pinning test `testHiddenProjectIsFilteredEvenUnderAllViewMode` is deleted along with it.
- [high] Left the orphaned `"hiddenProjects"` UserDefaults key in place with no migration or cleanup code. **Why:** the task explicitly directed this. An existing user's defaults may still hold an array under that key, but nothing reads or writes it now, so it is inert, harmless, and self-evidently dead; migration code to delete it would be more machinery than the stale value costs.
- [low] Renamed the `hiddenResolved` binding in `sortedProjects` to reuse `modeResolved` directly, so the chain now reads sort -> view mode -> focus. **Why:** with the hidden filter step gone the intermediate binding was a pure pass-through. Keeping a name referencing a deleted concept would have been exactly the stale-comment problem the task warned against.
- [low] Left in place the surviving doc-comment references to the historical "Hide Empty" gate (#021) in `ProjectViewMode`, `PlansStore`, and `BrowserWindow`. **Why:** those describe a DIFFERENT, previously-removed feature that `ProjectViewMode` explains itself as having replaced; that prose is still accurate history and none of it references the per-project hide API deleted here. Rewriting it would have been out of scope.

## Changes
- Tests (RED): added `visibleUnderHidden` pure-predicate tests to `BrowserWindowTests.swift` (`testVisibleUnderHiddenFalseForHiddenProject`, `testVisibleUnderHiddenTrueForAbsentProject`, `testVisibleUnderHiddenFalseForNonEmptyProjectInSet` [crux: non-empty project in set still hidden — proves independence from emptiness], `testVisibleUnderHiddenTrueWhenOnlyAnotherProjectHidden`) and `hiddenProjectPaths` store tests to `PlansStoreTests.swift` (`testHiddenProjectPathsDefaultToEmpty`, `testHiddenProjectPathsPersistAcrossStoreInstances`, `testRemovingHiddenProjectPathPersistsAcrossStoreInstances`, `testToggleHiddenInsertsThenRemoves`).

- Store + filter (GREEN): `PlansStore.swift` gained persisted `hiddenProjectPaths` (+ `hiddenProjectsKey`, eager `init` load, `toggleHidden` mutator) and the transient non-persisted `showHidden` reveal flag. `BrowserWindow.swift` gained the pure `BrowserViewModel.visibleUnderHidden` predicate and wires it into `sortedProjects` as its OWN filter step OUTSIDE the `if store.hideEmptyProjects` block (the crux: hide is fully decoupled from emptiness), suppressed while `showHidden` is on.
- UI (Surface B): `ProjectCard.swift` gained `HideToggleGlyph` (verbatim mirror of `FocusToggleGlyph` — `.plain` Button, `eye.slash`, opacity-conveyed state, 22x22 frame, rounded hover backdrop) and a `hideToggle` footer view; footer glyph order is hide -> focus -> star, keeping the star on the card's trailing corner. `BrowserWindow.swift` toolbar gained a "Show Hidden" toggle immediately after "Hide Empty", mirroring its chrome (plain Button, accent tint when active, `eye.slash`/`eye`, help "Reveal hidden projects").
- `MenuBarView.swift` deliberately untouched — hide is browser-only, so hidden projects still contribute to machine-wide glance counts.

- Toolbar affordance rework (post-review feedback): the reveal control shipped mirroring the "Hide Empty" chrome, putting a second unlabeled `eye`/`eye.slash` pair directly beside the incumbent one — some toggle combinations rendered two IDENTICAL adjacent glyphs. Reworked in `BrowserWindow.swift`: the #072 control now owns `rectangle`/`rectangle.slash` (hiding a CARD, not an eyeball), leaving the eye pair to "Hide Empty"; the per-card footer glyph keeps `eye.slash`, unambiguous in local context. The control also now reports the hidden COUNT and is omitted entirely at zero — without a count a hidden project looks permanently gone, since its own hide glyph only renders while `showHidden` is on. Count comes from the new pure `BrowserViewModel.hiddenProjectCount(projects:hiddenProjectPaths:)`, resolved against live projects (mirroring the stale-`focusedProjectPath` defence) so stale persisted paths can't inflate it. 5 new tests, incl. the stale-path crux.

- Visibility model consolidation (user-directed, folded into this task): replaced the "Hide Empty" toggle (#021) with a single labelled `ProjectViewMode` control — All / Active / Starred — rendered as TEXT in a toolbar `Menu`. New `Sources/Plans/ProjectViewMode.swift`; `PlansStore.projectViewMode` (persisted by rawValue) replaces the deleted `hideEmptyProjects`; `BrowserViewModel.visibleUnderViewMode` replaces the deleted `visibleUnderHideEmpty`. Star is now a filter in its own right rather than an exception to another filter. **Behavior change:** a starred-but-empty project no longer survives `.active` (the old `hasOutstandingWork || isStarred` rescue clause is gone) — curated projects live under `.starred`. Per-project hide is deliberately NOT folded in: an explicit hide overrides every mode. Removed 4 obsolete `visibleUnderHideEmpty` tests; added 9.

- Hide deleted (user decision): removed `hiddenProjectPaths`, `showHidden`, `hiddenProjectsKey`, `toggleHidden`, `visibleUnderHidden`, `hiddenProjectCount`, `hideToggle`, `HideToggleGlyph`, the toolbar reveal control, and the hidden filter step — 380 deletions across 6 files, plus 14 now-obsolete tests. Filter chain is now sort -> view mode -> focus; card footer is focus + star. This REVERSES the earlier `[high]` assumption that hide would remain a separate unconditional filter step after the view mode. Accepted trade-off: no way to permanently banish a project — every registered project appears under All and Active. The orphaned `hiddenProjects` UserDefaults key is left unread rather than migrated (inert, self-evidently dead).

## Notes
Research corroborated by reading `PlansStore.swift` (starred/focused persistence pattern, `init` eager-load), `BrowserWindow.swift` (`sortedProjects` filter chain, `visibleUnderHideEmpty`/`visibleUnderFocus` predicates, "Hide Empty" toolbar button), and `ProjectCard.swift` (`FocusToggleGlyph`/`StarToggleGlyph` templates). The crux of the task — decoupling hide from emptiness — is satisfied by applying the new filter as a standalone step OUTSIDE the `if store.hideEmptyProjects` block.
