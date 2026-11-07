# Layout Redesign — Brainstorm & Design Notes

> A design/brainstorm document for the **Plans** desktop app's index (browser)
> and detail screens. It is **not** a spec. The authoritative, deliberately
> layout-agnostic contract is `desktop-app-spec.md`; this document references it
> (never rewrites it) and proposes an implementation direction a future task can
> pick up. No Swift is changed by writing this.

The prompt behind this document: *"Consider the layout of the index screen and
the detail screen. I wonder if there isn't a better layout — perhaps a sidebar
and listing layout with a pinned area? Consider how other similar apps work. For
example, sometimes I want to see all things that are in review across all
projects."*

That last sentence is the load-bearing one. It names a capability the shipped UI
does not have, and one the spec actually requires. The rest of this document
works out from there.

---

## Current state

### The index is a project-centric card grid

The browser window (`Sources/Plans/BrowserWindow.swift`, the `BrowserWindow`
view) is a **card dashboard**, not a list. Its `body` renders a single
`cardGrid`: a `ScrollView` wrapping a responsive grid of `ProjectCard`s, **one
card per registered project**. There is no sidebar, no persistent selection, and
no `HSplitView` / `NavigationSplitView` anywhere in the file.

Projects are ordered by recency — `BrowserViewModel.sortByStaleness`, which
sorts on the registry `lastSeen` timestamp (most-recently-seen first) — unless
the user has dragged cards into a manual order, in which case
`BrowserViewModel.applyManualOrder` wins (both resolved in the `sortedProjects`
computed property). The grid has two layout modes, `store.cardLayoutMode`
(`CardLayoutMode`): `.scroll` is a variable-height masonry
(`variableCardGrid` + `columnAssignments`), `.fit` divides the viewport into
even-height rows (`fitCardGrid` + `evenRowHeights`). Focus mode (`#067`) can
collapse the grid to a single full-viewport card.

Each `ProjectCard` (`Sources/Plans/ProjectCard.swift`) is a self-contained view
of one project:

- a **header** with the project name and a per-status count summary (iterating
  `TaskStatus.glanceOrder`), plus a per-card **task-type filter**
  (`typeFilter`, a `TaskType?`, fed through
  `BrowserViewModel.activeRows(_:matchingType:)`);
- a **body** of tappable plan rows, one per `BrowserViewModel.activeRows(project)`;
- an optional **backlog** section (shown only while `store.showBacklog` is on,
  from `BrowserViewModel.backlogRows(project)`);
- a **footer** with git branch / dirty state, the branch-mode sync glyph, and
  the star / focus controls.

Filtering, today, is only ever one of two things:

- **per-card task-type** filtering (`typeFilter` inside a single `ProjectCard`),
  scoped to that one project's card; or
- **project-level** view mode (`store.projectViewMode`, a `ProjectViewMode` of
  `.all` / `.active` / `.starred`), which hides or shows whole project *cards*
  via `BrowserViewModel.visibleUnderViewMode`.

### The detail screen is a modal overlay

Tapping a plan row does **not** navigate. The card's `onOpenDetail` closure sets
`BrowserWindow`'s `detailRowID` (a `TaskRow.ID?`), and `body`'s `.overlay`
presents `PlanDetailView` as a dimmed in-window **modal overlay pane**
(`detailOverlay`): a `Color.black.opacity(0.35)` scrim behind a rounded card
clamped to `maxWidth: 900, maxHeight: 600`. It dismisses by clicking the scrim
or pressing Esc (`.onExitCommand`). `detailRowID` is the sole presentation state
and is deliberately *not* persisted. This replaced a former standalone per-plan
detail *window*.

`PlanDetailView` (`Sources/Plans/PlanDetailView.swift`) is **host-agnostic**: it
renders only its own body (title, project + status line, each `## ` section as
markdown, the `## How` section as a read-only checklist) and owns no window/pane
chrome. It resolves its row from the live store by composite id via
`BrowserViewModel.resolveRow(in:id:)`. Its own documentation notes it "needed no
changes when the former standalone detail window was replaced by the in-window
pane" — i.e. it is already decoupled from how it is hosted.

### Supporting pieces already in place

- `TaskRow` (defined in `BrowserWindow.swift`) is a flat, `Identifiable`,
  cross-project row model: it carries `projectPath`, `projectName`, and the
  underlying `Task`, with a composite id `projectPath + "/" + task.id`. It
  already exists precisely so a task can be addressed independent of which
  project card it came from.
- `BrowserViewModel` is a pure, SwiftUI-free namespace of helpers:
  `activeRows(_:)`, `backlogRows(_:)`, `resolveRow(in:id:)`, `sortByStaleness`,
  `applyManualOrder`, `reorder`, `visibleUnderViewMode`, `visibleUnderFocus`.
  None of them touch the filesystem or SwiftUI.
- `PlansStore` (`Sources/Plans/PlansStore.swift`) exposes `projects:
  [ProjectTasks]` plus view-mode / layout / backlog / star / focus / order
  preferences — **all UserDefaults-backed, never written to `.plans/`** — and
  cross-project aggregates `iconSpaceCounts` and `failedCount` (both built with
  `projects.reduce` / `flatMap`), which the menu bar consumes but the browser
  does not.
- `TaskStatus+Glance.swift` centralizes the status vocabulary: `glanceColor`,
  `symbolName`, `glanceGlyph`, and `glanceOrder`. `TaskStatus.filterLabel`
  (in `TaskType+Glyph.swift`) gives human labels ("Review", "In progress", …).
  A sidebar row of `icon + label` per status comes essentially for free from
  these.

### The gap

The spec (`desktop-app-spec.md`, §1, Surface B, "Filter by status across ALL
projects at once", roughly lines 47–49) is explicit:

> Filter by status across ALL projects at once — e.g. "show me everything that
> is `in-progress` everywhere", regardless of which project it lives in.
> **Filtering is global, not scoped to one project.**

The shipped UI has **no such view**. Everything in the browser is organized
around the *project* as the unit: the grid is one card per project, the
type filter is per-card, and the project view mode filters whole projects, not
tasks. There is no screen on which "every task in `review`, across all projects"
can be seen as a single list. The acceptance summary (§8, item 5) lists
"filters by status across all projects at once" as a requirement for a correct
build — so **the current index is non-compliant with its own spec on exactly the
user's stated use case.** That is the gap this redesign is meant to close.

---

## Proposed layout

A three-pane **`NavigationSplitView`**: a **sidebar** of views, a **middle
listing** of tasks, and a **persistent detail pane** replacing the modal
overlay. This is the native SwiftUI primitive for exactly this shape and keeps
us within the "pure SwiftUI/AppKit, no external dependencies" constraint.

```
┌────────────┬─────────────────────┬──────────────────────┐
│  SIDEBAR   │   LISTING            │   DETAIL             │
│            │                      │                      │
│ Smart      │  TaskRows for the    │  PlanDetailView for  │
│  views     │  selected sidebar    │  the selected row    │
│  ·In Prog. │  view, grouped /     │  (persistent, not a  │
│  ·Review   │  sortable by status  │  modal overlay)      │
│  ·Blocked  │  / project /         │                      │
│  ·Failed   │  staleness           │                      │
│  ·Backlog  │                      │                      │
│            │                      │                      │
│ Projects   │                      │                      │
│  ·app-a    │                      │                      │
│  ·app-b    │                      │                      │
└────────────┴─────────────────────┴──────────────────────┘
```

### Sidebar — pinned smart views + a Projects section

The sidebar has two sections:

1. **Smart views** (the "pinned" area — see below). A fixed, always-present set
   of cross-project views, each selecting every matching task regardless of
   project:
   - **In Progress** — `status == .inProgress`
   - **In Review / Review** — `status == .inReview || status == .review`
     (the user's "all in review across all projects"; possibly split into two
     rows, since the two statuses are distinct in the vocabulary)
   - **Blocked** — `task.isBlocked`
   - **Failed** — `task.failure != nil` (mirrors the menu bar's `failedCount`)
   - **Backlog** — the deferred tasks from `backlogRows`
   Each row is an `icon + label` built directly from the existing vocabulary
   (`TaskStatus.symbolName` / `glanceColor` and `TaskStatus.filterLabel`), so
   the sidebar inherits the glance's visual language with no new design work.

2. **Projects**. The familiar per-project entries, recency-sorted
   (`sortByStaleness`) or in the user's manual order (`applyManualOrder`).
   Selecting a project scopes the listing to that one project — which is the
   *current* behavior, preserved as one view among many rather than the only
   view.

### Listing — a flat, sortable list of TaskRows

The middle column renders `TaskRow`s for whatever the sidebar selected. Because
`TaskRow` already carries its owning project identity (`projectName` /
`projectPath`), a cross-project listing can show the project as a column / label
on each row without any model change. The listing should be **groupable and
sortable** — by status, by project, or by staleness (`modified` / `Created`,
see the data note below). A smart-view selection yields a cross-project list; a
project selection yields that project's own list; both are the same `TaskRow`
list view, differing only in what populates it.

### Detail — persistent third pane

The detail column hosts `PlanDetailView` keyed by the selected `TaskRow.ID`,
exactly as `detailOverlay` keys it today — but **persistent** rather than a
dismiss-on-blur modal. Since `PlanDetailView` is already host-agnostic and
already resolves its row from the store by composite id, it drops into the
`NavigationSplitView` detail column essentially as-is; the scrim, the Esc
handler, and the `maxWidth/maxHeight` clamp from `detailOverlay` simply fall
away. "No selection" shows the existing "Plan not found" / empty placeholder the
view already renders for a `nil` id.

### What "pinned" means — three readings

The user said "a pinned area **perhaps**" — tentative, so rather than commit to
one interpretation this document enumerates the three plausible readings and
recommends the first:

1. **Smart status views** (recommended). The pinned area is the top section of
   the sidebar: a fixed set of cross-project, status-driven views (the list
   above). "Pinned" = always present, always at the top, not user-curated. This
   is the reading that directly closes the spec gap, so it is mapped onto the
   proposal's sidebar smart-view section.
2. **User-pinned favourites.** The pinned area is a user-curated set of
   shortcuts — favourite projects, or even specific saved filters — that the
   user explicitly pins. This overlaps the existing **star** feature
   (`store.starredProjectPaths`, surfaced today only through the `.starred`
   project view mode); a pinned-favourites area could simply be where starred
   projects (and perhaps starred tasks, if task-level starring were added) live.
3. **Persistent summary header.** The pinned area is not navigation at all but a
   always-visible summary strip — counts of in-progress / review / failed across
   all projects — analogous to `store.iconSpaceCounts` / `failedCount` already
   driving the menu bar. It would sit above the listing (or at the top of the
   sidebar) as an at-a-glance banner rather than a set of selectable views.

Reading 1 is the one the "all in review across all projects" example demands, so
it anchors the proposal. Readings 2 and 3 are complementary, not exclusive — a
final design could combine a smart-view section (1) with the existing stars as
pinned favourites (2) and/or a summary header (3).

---

## Cross-project status views

This is the concrete mechanism behind the smart views, and the piece that is
genuinely missing today.

A smart view is a filter over **every project's tasks at once**. The data is
already assembled: `store.projects` is `[ProjectTasks]`, and
`BrowserViewModel.activeRows(_:)` turns one project's `activeTasks` into
`TaskRow`s carrying their owning project identity. Flattening across projects
and filtering by status is a one-liner in the same pure-helper style the view
model already uses:

```swift
// e.g. "all in review across all projects"
store.projects
    .flatMap { BrowserViewModel.activeRows($0) }
    .filter { $0.task.status == .review || $0.task.status == .inReview }
```

The same shape serves every smart view — `.inProgress` for In Progress,
`$0.task.isBlocked` for Blocked, `$0.task.failure != nil` for Failed — and the
Backlog view flat-maps `backlogRows` instead of `activeRows`. This mirrors
exactly how `PlansStore.iconSpaceCounts` and `failedCount` already aggregate
across `projects` with `reduce` / `flatMap`, and how
`BrowserViewModel.resolveRow` already scans *every* project's rows. The natural
home for these is a new pure helper on `BrowserViewModel` (e.g.
`rows(in:matchingStatus:)`) so it stays unit-testable as plain values, like its
siblings. It reads only; it never writes `.plans/` (spec §2).

The user's example — "see all things that are in review across all projects" —
is then just the In Review smart view: select it in the sidebar, and the listing
is the flat-mapped, status-filtered `TaskRow` list above, each row labelled with
its project. Selecting a row opens its `PlanDetailView` in the persistent detail
pane.

**Data consideration — staleness has no task-level `lastSeen`.** The spec's
"sort by staleness" (§1) uses the registry `lastSeen` as the *project*-level
signal — which is exactly what `sortByStaleness` consumes
(`ProjectTasks.lastSeen`). But a cross-project **task** list wants a per-*task*
staleness key, and there is no task-level `lastSeen`. The parsed `Task` model
(`TaskParser.swift`) exposes `modified` (the task file's mtime) and `created`
(the `**Created:**` field), and the spec (§1, §4.3) explicitly sanctions both as
finer-grained task-staleness signals: "for finer-grained task staleness you may
use the task file's modification time and/or the `**Created:**` field." So a
cross-project listing sorted by staleness should sort on `Task.modified` (with
`created` as a fallback), not on the project's `lastSeen`. This is a small but
real difference from the current project-grid staleness sort, and worth deciding
deliberately when the listing's sort is built.

---

## How similar apps do it

The three-pane shape proposed above is not a novel invention — it is the
dominant idiom for task, mail, and code-browsing apps on the Mac. Five
well-known apps are worth looking at, because each contributes one piece of the
pattern Plans needs.

- **Things 3.** Its sidebar is the heart of the design. A top block of
  *built-in smart lists* — **Inbox**, **Today**, **Upcoming**, **Anytime**,
  **Someday** — sits above a user-organized block of **Areas** and **Projects**.
  The smart lists are not folders; they are saved queries that pull matching
  to-dos from *everywhere* (Today shows everything due today regardless of which
  project it lives in). Selecting a sidebar entry drives the middle list of
  to-dos; a to-do expands in place to reveal its notes and checklist. This is
  almost exactly the division Plans wants: **Today / Upcoming / Anytime ≈ the
  cross-project smart status views, and Areas / Projects ≈ the Projects
  section.** The key borrowed idea is that *built-in cross-cutting views and
  per-project views coexist in one sidebar*, the former pinned at the top.

- **OmniFocus.** Its sidebar is a list of **Perspectives** — some built in
  (Inbox, Projects, Tags, Forecast, Flagged, Review), and, in the Pro version,
  *custom perspectives* the user defines as reusable filter rules (e.g. "all
  flagged items tagged @errand that are available"). A perspective is a saved,
  named filter over the whole task database; selecting one populates the main
  outline/list. This is the generalization of Things' fixed smart lists:
  **user-definable cross-project filters.** For Plans it maps to a future where
  the fixed smart status views could become user-saved filters — the
  "all in review across all projects" query is just a perspective, and so is
  "everything blocked" or "everything failed."

- **Linear.** A desktop/web issue tracker with a left sidebar that mixes
  personal cross-cutting views (**My Issues**, **Inbox**) with per-team and
  per-project navigation, plus saved **Views** / filtered lists by status and
  other attributes. The center is a list (or board) of issues that can be
  grouped and sorted by status, assignee, priority, etc.; selecting an issue
  opens a detail/reading pane (or full view) on the right. Linear is the closest
  analogue to Plans' actual domain — status-driven work items across multiple
  projects — and it demonstrates the exact combination Plans is missing today:
  **status-grouped, cross-project lists reached from a sidebar, with a
  selectable detail view.**

- **Xcode.** The canonical Mac three-pane developer layout: a left **navigator**
  (file/symbol/issue/test navigators — different *lenses* on the same workspace),
  a central **editor**, and a right **inspector**. The relevant precedent is
  structural rather than task-management: Xcode normalizes the
  *navigator + content + inspector* shape as the native, expected layout for a
  Mac productivity tool, and shows that the leftmost pane can switch between
  several *modes* over the same underlying data — directly analogous to a Plans
  sidebar that toggles between smart-status lenses and a per-project lens.

- **Mail.** The simplest and most universally familiar instance: a **mailbox
  sidebar** (including smart/unified mailboxes that aggregate across accounts —
  e.g. "All Inboxes"), a **message list** in the middle, and a **reading pane**
  on the right. The unified-mailbox idea is the cleanest parallel to the user's
  request: *"All Inboxes" is to accounts what an "In Review" smart view is to
  projects* — one list that merges the same category across every source.

**The common pattern.** Every one of these apps converges on the same skeleton:
a **sidebar of named views** (some cross-cutting and global, some scoped to one
container) → a **middle list** of items for the selected view, groupable and
sortable → a **persistent detail / reading pane** for the selected item. The
cross-cutting views (Today, a Perspective, My Issues, All Inboxes) are always
*pinned above* the container-scoped ones (Projects, Areas, teams, individual
mailboxes).

**What applies to Plans.** This is precisely the layout proposed above, and the
mapping is tight: Things/OmniFocus/Mail justify the **smart-view sidebar section**
that finally delivers "all in review across all projects"; Things' Areas and
Mail's per-mailbox entries justify keeping a **Projects section** for the
existing per-project view; Linear validates **status-grouped, cross-project
lists** as the center pane for exactly this kind of status-driven work; and
Xcode confirms the **navigator / content / inspector** three-pane shape as the
native, idiomatic choice on macOS — which `NavigationSplitView` provides
directly, no external dependencies. OmniFocus's perspectives point at the natural
*future* extension (user-definable saved filters) once the fixed smart views
exist.

---

## Recommendation & migration notes

**Recommendation: adopt the three-pane `NavigationSplitView` with a smart-view
sidebar — additively.** The goal is not a rewrite. The card grid carries a lot
of hard-won, well-liked behavior (`.fit` / masonry layouts, focus mode, drag
reorder, zebra rows, the backlog section, the git footer, capture) and it should
*survive* — reframed as a **"by project" perspective**, one lens in the new
sidebar rather than the only screen. The redesign's job is to add the
cross-project status views the spec requires (closing the gap in **Current
state**) and to promote detail out of the modal overlay, not to discard what
already works.

The migration is cheap precisely because the groundwork is already in place.
Concrete levers:

- **`PlanDetailView` is already host-agnostic.** It renders only its own body and
  resolves its row from the live store by composite id
  (`BrowserViewModel.resolveRow(in:id:)`); it needed no changes when the former
  standalone detail *window* became the in-window overlay. It drops into a
  `NavigationSplitView` detail column as-is — the scrim, Esc handler, and
  `maxWidth/maxHeight` clamp from `detailOverlay` simply fall away.
- **`BrowserViewModel` already has the row / resolve / sort helpers.**
  `activeRows(_:)`, `backlogRows(_:)`, `resolveRow(in:id:)`, `sortByStaleness`,
  `applyManualOrder`, and `visibleUnderViewMode` are pure, SwiftUI-free, and
  unit-testable. The cross-project smart views need only one more sibling in the
  same style (e.g. `rows(in:matchingStatus:)`, per **Cross-project status
  views** above).
- **A flat selection model replaces `detailRowID`.** Today `detailRowID`
  (`TaskRow.ID?` in `BrowserWindow`) is the sole, deliberately-unpersisted
  presentation state for the overlay. In the split view this becomes the
  listing's selection — still a `TaskRow.ID?`, still keying `PlanDetailView` the
  same way, but now binding a persistent pane instead of toggling an overlay.
- **New view state persists to UserDefaults via `PlansStore`, never `.plans/`.**
  The selected perspective (which sidebar view is active) and split
  visibility / column widths are view preferences, and must follow the existing
  pattern — `PlansStore` already backs `cardLayoutMode`, `projectViewMode`,
  star / focus / order entirely in UserDefaults. The spec's §2 read-only
  constraint on `.plans/` is absolute: nothing here writes task data.

**Incremental migration order.** Each step is shippable on its own and leaves the
app working:

1. **Add the cross-project status sidebar + listing *alongside* the existing
   cards.** Introduce the `BrowserViewModel` smart-view helper and a sidebar +
   flat `TaskRow` listing, reachable without touching the card grid. This alone
   closes the spec gap ("all in review across all projects") — the highest-value,
   lowest-risk step.
2. **Promote detail out of the modal overlay into a persistent pane.** Replace
   the `detailOverlay` presentation with the `NavigationSplitView` detail column
   driven by the listing selection. `PlanDetailView` is unchanged; only its host
   changes.
3. **Fold the cards into a "by project" perspective.** Make the existing card
   grid one selectable view in the sidebar (the Projects section / a "by project"
   entry), so project-scoped and status-scoped browsing live in one window. The
   card behaviors are preserved, just reached through the new navigation.

**The actual UI implementation is a separate follow-up task — it is explicitly
not done here.** This document is the brainstorm and design direction; no Swift
is changed by writing it. A subsequent task can pick up the migration order
above, writing failing tests first per the project's TDD convention.
