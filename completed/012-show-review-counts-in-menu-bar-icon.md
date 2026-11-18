# Show Ready/In-Review/In-Progress Plan Counts In Menu Bar Icon Space

**ID:** 012
**Created:** 2026-06-05T00:00
**Type:** feature
**Status:** completed
**Branch:** feature/012-show-review-counts-in-menu-bar-icon
**Completed:** 2026-06-05T12:05

## What
In the menu bar app, show the count of "ready for review" (`.review`), "in review" (`.inReview`), and "in progress" (`.inProgress`) plans in the menu bar icon space — the macOS status item label area shown next to the icon, NOT the dropdown content. This is in addition to what the dropdown (`MenuBarView`) already shows. If a category has zero plans across all projects, that category does not appear in the icon space. Reuse the existing per-status glyph + color (`glanceGlyph` + `glanceColor`) with a small count next to each.

**Decisions (from elaboration):**
- **Render style:** colored glyph + count (e.g. `▶3 ★2 ◉1`), each glyph tinted with its status `glanceColor`. Chosen over SF Symbols because macOS may desaturate symbol colors in the menu bar; colored text reliably preserves the status colors.
- **Order:** in-progress → ready-for-review → in-review (`[.inProgress, .review, .inReview]`) — lead with actively-running work as most urgent. This is a NEW order specific to the icon space, distinct from `glanceOrder`.
- **Empty state:** when all three counts are zero, show the icon only (`list.bullet`) with no counts/label.

## Why
Adds value by surfacing outstanding-work counts at a glance in the always-visible menu bar icon space, so the user sees how many plans are in progress / ready for review / in review without opening the dropdown.

## How
- [x] Step 1: Add a computed property `iconSpaceCounts: [(status: TaskStatus, count: Int)]` to `PlansStore` (`Sources/Plans/PlansStore.swift`) that aggregates counts across all `projects` for the three target statuses in the order `[.inProgress, .review, .inReview]`, omitting any status whose total is 0. Reuse the existing `project.counts[status]` dictionary (no new parsing).
- [x] Step 2: Add a unit test in `Tests/PlansTests/PlansStoreTests.swift` (written first, TDD) covering: aggregation sums across multiple projects; zero-count statuses are omitted; ordering is in-progress → review → in-review; empty store yields an empty array. Use the existing fixture/injected-reader pattern already in that test file.
- [x] Step 3: Add a small `MenuBarLabel` view (in `Sources/Plans/PlansApp.swift`, or a new `Sources/Plans/MenuBarLabel.swift` if it reads cleaner) that renders the `list.bullet` icon followed by, for each entry in `store.iconSpaceCounts`, the status `glanceGlyph` in its `glanceColor` plus the count `Text`. When `iconSpaceCounts` is empty, render the icon alone.
- [x] Step 4: Switch the `MenuBarExtra` in `PlansApp.body` from the `("Plans", systemImage:)` string initializer to the `MenuBarExtra(content:label:)` overload, passing `MenuBarView()` as content and `MenuBarLabel()` (observing `store`) as the label so the counts live-update with the store's 5s poll.
- [x] 👁 Step 5: Build and run the app; observe the menu bar icon space shows the colored glyph+count badges, that colors render as intended (not desaturated), that they update as plan statuses change, and that zero-count categories disappear / all-zero shows icon only. (Visual confirmation in the real macOS menu bar — the agent cannot observe this.)

## Verification
Verify the menu bar icon space shows `▶N`, `★N`, `◉N` (colored) for non-zero in-progress / ready-for-review / in-review counts in that order, omits any zero-count category, and shows the icon alone when all three are zero. Counts update live as `.plans/` changes (within the 5s poll). The `PlansStore.iconSpaceCounts` unit tests pass and existing tests still pass (`swift test`).

## Impact Scope
_Fewer than 3 source files modified (PlansStore.swift, PlansApp.swift, plus one test file); detailed Impact Scope omitted._

## Assumptions

### Initial (from elaboration)
_Interactive elaboration — design decisions were confirmed with the user via prompts (render style, order, empty state) and are recorded under "Decisions" in the What section._

### Discovered during execution
- [high] Defined `iconSpaceOrder` as a `private static let` on `PlansStore` (local to the icon-space property), distinct from `TaskStatus.glanceOrder`. **Why:** The task explicitly required a NEW order local to where the icon-space property lives; a static let mirrors the `glanceOrder` precedent without polluting the shared `TaskStatus+Glance` ordering.
- [high] Aggregated totals with `projects.reduce(0) { $0 + ($1.counts[status] ?? 0) }` and `compactMap` over the order, dropping zero totals. **Why:** Directly mirrors `ProjectGlanceRow.statusCounts` (compactMap + skip-zero), the precedent named in the task; `counts` may omit zero-count statuses so `?? 0` is required.
- [low] Used `HStack(spacing: 4)` between icon and each entry, and `HStack(spacing: 1)` between a glyph and its count, with no spacing/padding the task specified. **Why:** No exact spacing was given; chose tight values so glyph+count read as one unit (e.g. `▶3`) and the menu bar label stays compact. The existing `ProjectGlanceRow` uses spacing 2 for glyph+count, but that row uses SF Symbols with a fixed 14pt frame; for bare colored text a tighter 1 keeps glyph and digit visually paired.
- [high] Created `MenuBarLabel` in a new `Sources/Plans/MenuBarLabel.swift` rather than in `PlansApp.swift`. **Why:** The task's preferred option; keeps `PlansApp.swift` focused on scene wiring.
- [high] Dark-mode adaptation for the pre-rendered bitmap: read `@Environment(\.colorScheme)` in `MenuBarLabel.body` (tracked SwiftUI dependency → re-runs `body` and re-bakes the bitmap on appearance change) and inject it via `.environment(\.colorScheme, colorScheme)` onto the `ImageRenderer` content, with the digit color set to `Color(nsColor: .labelColor)`. **Why:** `ImageRenderer` is not reactive and bakes colors against the content's environment; injecting the live scheme makes semantic colors resolve to the correct shade per appearance. Chose injecting `\.colorScheme` over imperatively reading `NSApp.effectiveAppearance` because the latter would not trigger SwiftUI invalidation.
- [low] Increased badge-group spacing from 4 to 6, kept glyph↔count spacing tight at 2 (was 1). **Why:** Task asked for "~6" between groups and "1–2" inside; 6/2 reads as separated groups while each glyph stays paired with its digit.
- [low] Pill background: `RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08))` with `.padding(.horizontal, 5).padding(.vertical, 2)`. **Why:** Task suggested cornerRadius ~5, faint fill (`Color.primary.opacity(0.08)`), and 5h/2v padding. `Color.primary` is semantic so the pill follows the injected color scheme and stays subtle in both modes. `.continuous` style for a softer corner. ImageRenderer sizes to the padded content so the rounded background is not clipped.
- [high] Empty state shows only `list.bullet` (no pill); when counts exist the leading `list.bullet` icon is dropped entirely. **Why:** Refinement #2 explicitly requested the icon only in the empty state and badges-only (no leading icon) when counts are present.

## Changes
- `Sources/Plans/PlansStore.swift`: Added `iconSpaceCounts: [(status: TaskStatus, count: Int)]` computed property plus a private `iconSpaceOrder` static let (`[.inProgress, .review, .inReview]`). Aggregates `project.counts[status]` across all projects, dropping zero totals.
- `Tests/PlansTests/PlansStoreTests.swift`: Added 4 TDD tests for `iconSpaceCounts` (cross-project summing, zero-status omission, ordering, empty store).
- `Sources/Plans/MenuBarLabel.swift` (new): The menu bar label view — `list.bullet` icon followed by per-entry colored `Text(glanceGlyph)` (tinted `glanceColor`) + count `Text`; icon-only when empty.
- `Sources/Plans/PlansApp.swift`: Switched `MenuBarExtra` to the `content:label:` overload with `MenuBarLabel().environment(store)` as the label, keeping `.menuBarExtraStyle(.window)`.

**Post-observation refinements (from user testing in the real menu bar):**
- `Sources/Plans/MenuBarLabel.swift`: macOS flattens a `MenuBarExtra` label to a monochrome template, stripping colors. Rewrote `MenuBarLabel` to pre-render the colored content to an `NSImage` via `ImageRenderer`, set `nsImage.isTemplate = false`, and display `Image(nsImage:).renderingMode(.original)` so the status hues survive and all entries (incl. ★ review) render together.
- `Sources/Plans/MenuBarLabel.swift`: Dark-mode adaptation — `MenuBarLabel` reads `@Environment(\.colorScheme)` and injects it onto the `ImageRenderer` content so semantic colors (count digit `.labelColor`, pill `Color.primary.opacity(0.08)`) bake correctly into the bitmap per appearance and re-render on appearance change.
- `Sources/Plans/MenuBarLabel.swift`: Hide the leading `list.bullet` icon when counts exist (icon shown only in the empty state); subtle rounded-pill background behind the badges (`RoundedRectangle(cornerRadius: 5, .continuous)`, faint fill); final spacing glyph↔count 4pt, between badge groups 10pt.

## Notes
- All reusable pieces already exist: `TaskStatus.glanceGlyph` / `.glanceColor` (`Sources/Plans/TaskStatus+Glance.swift`), per-project `counts: [TaskStatus: Int]` (`Sources/Plans/TaskParser.swift:146`), and the `@Observable PlansStore.projects` (`Sources/Plans/PlansStore.swift`). The dropdown's `MenuBarView` already demonstrates the compact glyph/symbol + count rendering pattern.
- Key constraint: `MenuBarExtra`'s string label can't show colored glyphs — must use the `MenuBarExtra(content:label:)` overload with a custom `View` label.
- Reference precedent: `ProjectCard.swift` / `MenuBarView.swift` for the "iterate statuses, skip zero counts, render glyph/symbol + color + count" pattern.
