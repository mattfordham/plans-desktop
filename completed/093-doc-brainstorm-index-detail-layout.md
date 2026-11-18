# [Doc] Brainstorm & document better layouts for the index and detail screens

**ID:** 093
**Created:** 2026-11-06T20:24
**Type:** feature
**Status:** completed
**Completed:** 2026-11-07T11:46
**Branch:** feature/093-doc-brainstorm-index-detail-layout

## What
Document & brainstorm: consider layout of the index screen and the detail screen. I wonder if there isn't a better layout, perhaps a sidebar and listing layout with a pinned area perhaps? Consider how other similar apps work. For example, sometimes I might want to see all things that are in review across all projects.

## Why
The current browser (index) screen is a project-centric card grid with a modal-overlay detail pane. The authoritative spec (`desktop-app-spec.md` §1, Surface B) explicitly requires filtering by status *across all projects at once* ("Filtering is global, not scoped to one project") — but the shipped UI has no such cross-project status view, only per-card type filters and a project-level view mode. The user's own example ("see all things that are in review across all projects") is exactly this missing capability. A written brainstorm document captures the design thinking — current-state analysis, a sidebar + listing + pinned-area proposal, how comparable apps solve it, and a concrete recommendation — so a future implementation task can proceed from an agreed direction rather than a cold redesign.

## How Summary
Author a standalone markdown design/brainstorm document at the repo root (beside, not inside, the authoritative spec) that analyzes the current index/detail layout, names the cross-project-status gap, proposes a three-pane sidebar + listing + persistent-detail layout with a pinned smart-view area, surveys how similar apps (Things, OmniFocus, Linear, Xcode, Mail) handle the same problem, and ends with a recommendation plus incremental migration notes grounded in the existing code. No Swift is written — the deliverable is the document.

**Files of note:**
- `layout-redesign.md` — new design/brainstorm doc (the deliverable); created at repo root.
- `desktop-app-spec.md` — authoritative, layout-agnostic spec; referenced (§1 Surface B), never rewritten.
- `Sources/Plans/BrowserWindow.swift` — current index screen (card grid, `BrowserViewModel`, `TaskRow`); analyzed and cited for feasibility of cross-project views.
- `Sources/Plans/PlanDetailView.swift` — current detail pane (host-agnostic modal overlay); cited as drop-in for a persistent detail column.
- `Sources/Plans/ProjectCard.swift` / `PlansStore.swift` / `TaskStatus+Glance.swift` — card unit, cross-project aggregation pattern, and status glyph/label vocabulary cited in the proposal.

## How
- [x] Step 1: Read `desktop-app-spec.md` §1 (Surface B) and §2 (read-only constraint), plus `BrowserWindow.swift`, `PlanDetailView.swift`, `ProjectCard.swift`, `PlansStore.swift`, and `TaskStatus+Glance.swift`, to ground the document in the actual current implementation and constraints.
- [x] Step 2: Create `layout-redesign.md` at the repo root with a current-state analysis section: the project-centric card grid, the modal-overlay detail, the per-card type filter + project view mode, and a blunt statement of the gap — no cross-project status view despite spec §1 requiring one.
- [x] Step 3: Add a "Proposed layout" section describing a three-pane `NavigationSplitView`: a sidebar of pinned smart views (In Progress, In Review/Review, Blocked, Failed, Backlog) plus a Projects section; a middle listing of `TaskRow`s grouped/sortable by status/project/staleness; and a persistent detail pane replacing the modal overlay. Explicitly map the user's "pinned area" onto the sidebar's top smart-view section, and enumerate the three plausible readings of "pinned" (smart status views, user-pinned favourites, persistent summary header).
- [x] Step 4: Add a "Cross-project status views" section specifying how smart views enumerate tasks across projects (`store.projects.flatMap` of `BrowserViewModel.activeRows`, filtered by `task.status`), using the user's "all in review across all projects" example, and note the data consideration that tasks have `modified`/`Created` but no task-level `lastSeen`.
- [x] Step 5: Add a "How similar apps do it" section comparing Things, OmniFocus, Linear, Xcode, and Mail — drawing out the shared sidebar / list / detail three-pane precedent and the smart-view/perspective idea.
- [x] Step 6: Add a "Recommendation & migration notes" section: recommend the additive three-pane split with a smart-view sidebar (cards survive as a "by project" perspective, not a rewrite); cite that `PlanDetailView` is already host-agnostic, `BrowserViewModel` already has the row/resolve helpers, and new view state must persist to UserDefaults (never `.plans/`, per §2). Note that an actual implementation would be a separate follow-up task.
- [x] Step 7: Re-read the finished `layout-redesign.md` for coherence, correct file/section references against the codebase, and confirm it stays within native SwiftUI/AppKit primitives (no external-dependency proposals).

## Verification
- `layout-redesign.md` exists at the repo root and reads as a coherent brainstorm/design document.
- It contains the required sections: current-state analysis (naming the cross-project-status gap), the sidebar + listing + pinned-area proposal, cross-project status views, a similar-apps comparison, and a recommendation with migration notes.
- All file and spec references in the doc resolve correctly against the actual codebase.
- The doc proposes no external dependencies and does not rewrite `desktop-app-spec.md`.
- No Swift source files are modified (this is a document-only task).

## Impact Scope
_Single new file (`layout-redesign.md`); Impact Scope section not required (fewer than 3 files modified)._

## Assumptions

### Initial (from elaboration)
- [low] Deliverable is the design/brainstorm document only; a real UI implementation is left as a suggested follow-up task rather than auto-captured. **Why:** The task title is "[Doc] Brainstorm & document" and the What asks to "document & brainstorm" — scope is explicitly documentation, and the research flagged implementation-vs-doc as an open question.
- [low] The proposed sidebar+listing layout is recommended as *additive* (cards survive as a "by project" perspective) rather than a full replacement of the card grid. **Why:** Research warned the card dashboard carries substantial hard-won behavior (fit/masonry, focus mode, drag reorder, backlog, git footer); an additive proposal is lower-risk and still closes the actual spec gap.
- [low] The "pinned area" is interpreted primarily as smart status views at the top of the sidebar, with the two alternative readings (user-pinned favourites; persistent summary header) enumerated in the doc. **Why:** The user phrased it tentatively ("a pinned area perhaps"); enumerating interpretations is safer than committing to one.
- [low] The detail screen is proposed to move from the modal overlay to a persistent third pane. **Why:** The user's sidebar framing implies a three-pane model, and research confirmed `PlanDetailView` is already host-agnostic and drops into a `NavigationSplitView` detail column.
- [low] The document is created at the repo root as `layout-redesign.md`, beside `desktop-app-spec.md`, rather than in a `docs/` folder. **Why:** The repo has no `docs/` directory and keeps `desktop-app-spec.md` at root; matching the existing convention. The authoritative spec is referenced, never rewritten.
- [high] No `**Build:**` route is added. **Why:** The project has no `design-system/` directory (it is a native SwiftUI app) and the deliverable is a markdown document, so the des-build routing trigger does not apply.

### Discovered during execution
- [high] Cited the spec's own §1 wording "all in review across all projects" and §8 item 5 as confirming the gap, verified against the actual file (§1 Surface B at lines ~47-49, §8 item 5). **Why:** The prompt asked me to verify approximate line numbers; I confirmed the "Filtering is global, not scoped to one project" sentence and the acceptance-summary requirement both exist as described.
- [low] The "In Review / Review" smart view is described as possibly one row or split into two. **Why:** `review` and `in-review` are distinct statuses in the vocabulary (spec §5.4) and `TaskStatus.filterLabel` gives them separate labels, but the user's phrasing ("all things in review") reads as one conceptual bucket; left as a design choice rather than committing.
- [low] Noted a surface tension between the spec §5.5 step-8 documented app ordering (`in-review > review > in-progress …`) and the `ProjectTasks.activeTasks` doc comment in `TaskParser.swift` (`in-progress > in-review > review …`). **Why:** Not load-bearing for the layout doc (which cites the pure cross-project filter helpers, not the sort order), so I did not resolve it in the document; flagging it here in case a later segment or the implementation task needs the exact active-task ordering.
- [low] Left the "How similar apps do it" and "Recommendation & migration notes" headings as placeholder sections with a one-line italic note of their intended content. **Why:** The segment prompt said these are added in a later segment and gave me the choice of empty/placeholder headings; placeholders keep the file coherent and signpost the remaining work.
- [high] Described each comparator app's sidebar/list/detail model from well-known, stable behavior only. **Why:** Things 3's built-in smart lists (Inbox/Today/Upcoming/Anytime/Someday) over Areas/Projects, OmniFocus's built-in + Pro custom Perspectives, Linear's My Issues/Inbox + saved Views + team/project nav, Xcode's navigator/editor/inspector, and Mail's mailbox sidebar (incl. unified "All Inboxes") + message list + reading pane are all stable, documented, widely-known features; I avoided version-specific or invented details.
- [low] Called OmniFocus custom perspectives a "Pro"-version feature. **Why:** Custom/user-defined perspectives have long been gated to OmniFocus Pro; stated at a level of generality that holds across recent versions rather than pinning an edition boundary precisely, since the exact gating is not load-bearing for the Plans mapping.
- [high] Recommended the additive three-pane split with the card grid surviving as a "by project" perspective, and sketched a 3-step incremental migration (status sidebar+listing alongside cards → persistent detail pane → fold cards into a perspective), stating the UI implementation is a separate follow-up. **Why:** Directly from the segment's Step 6 instructions, grounded in the verified host-agnostic `PlanDetailView`, the existing `BrowserViewModel` helpers, the `detailRowID` → flat-selection swap (confirmed in `BrowserWindow.swift`), and the §2 UserDefaults/never-`.plans/` constraint.

## Changes

Created a new design/brainstorm document, `layout-redesign.md`, at the repo root (≈291+ lines, no Swift changed — document-only task).

**New file:**
- `layout-redesign.md` — standalone layout brainstorm doc, deliberately *not* folded into the authoritative `desktop-app-spec.md` (which is layout-agnostic and referenced, never rewritten). Section structure:
  1. **Intro** — frames the doc as a brainstorm, defers to the spec, restates the user's prompt.
  2. **Current state** — the project-centric card grid (`BrowserWindow.swift`: `ScrollView` + `LazyVGrid`/masonry of `ProjectCard`, `.scroll`/`.fit` layout modes, `projectViewMode`), the modal-overlay detail (`detailRowID` + scrim/Esc), supporting pieces (`TaskRow`, `BrowserViewModel` helpers, `PlansStore` aggregates, glance vocabulary), and **The gap** — no cross-project *status* view despite spec §1 (Surface B) requiring "filter by status across ALL projects at once" (also §8 item 5).
  3. **Proposed layout** — a three-pane `NavigationSplitView`: a smart-view sidebar (In Progress, In Review/Review, Blocked, Failed, Backlog) + a Projects section; a sortable/groupable `TaskRow` listing; a persistent detail pane replacing the modal. Maps the user's "pinned area" onto the sidebar's top smart-view section and enumerates three readings of "pinned" (smart status views / user-pinned favourites / persistent summary header).
  4. **Cross-project status views** — the feasibility mechanism `store.projects.flatMap { BrowserViewModel.activeRows($0) }.filter { $0.task.status == … }`, the user's "all in review across all projects" worked example, and a staleness data note (`Task.modified`/`created` exist; no task-level `lastSeen`).
  5. **How similar apps do it** — Things 3, OmniFocus, Linear, Xcode, Mail compared on sidebar/list/detail; distills the common three-pane + smart-view/perspective precedent and what applies to Plans.
  6. **Recommendation & migration notes** — recommends the *additive* three-pane split (cards survive as a "by project" perspective, not a rewrite); cites concrete levers (host-agnostic `PlanDetailView`, existing `BrowserViewModel` row/resolve/sort helpers, `detailRowID` → flat selection, new view state to UserDefaults per §2); gives a 3-step incremental, each-step-shippable migration order; states the UI implementation is a separate follow-up task.

**Verification performed (by the executor):** all file/type/helper references in the doc were confirmed against the actual codebase (`activeRows`, `backlogRows`, `resolveRow`, `sortByStaleness`, `applyManualOrder`, `visibleUnderViewMode`, `detailRowID`/`detailOverlay`, host-agnostic `PlanDetailView(rowID:)`); only native primitives (`NavigationSplitView`, `List`, `TaskRow`) are proposed — no external dependencies; `desktop-app-spec.md` was not modified.

**Follow-up noted (not actioned here):** a minor documentation tension between spec §5.5's documented app-ordering and the `ProjectTasks.activeTasks` doc comment in `TaskParser.swift` was flagged in the assumptions for a future task; it is not load-bearing for this layout doc.

## Notes
_Additional context_
