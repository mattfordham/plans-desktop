# Fix window layout overflow when a plan is open in the detail column

**ID:** 109
**Created:** 2026-11-08T08:37
**Type:** bug
**Status:** completed
**Completed:** 2026-11-08T09:10
**Branch:** fix/109-fix-window-layout-overflow-when-a-plan

## What
Fix window layout overflow when a plan is open in the detail column (regression from #106).

Symptom: with a project selected and a plan open in the detail column, the whole window content shifts up and is clipped at the top. The sidebar slides under the traffic lights (the Status section is lost off the top), the middle task-list column goes blank, and the detail header is clipped away. It does not happen when the detail column shows "No Plan Selected".

Cause: #106 (a7998b9) moved the detail header/progress panel/run-log drawer out of the ScrollView into a pinned banner in `PlanDetailView.planScrollView` (`Sources/Plans/PlanDetailView.swift` ~816). The banner now sets the detail column's minimum height: the title's `.fixedSize(horizontal: false, vertical: true)` (~311) can wrap very tall at the narrow widths `NavigationSplitView` proposes when computing minimum sizes, and the expanded drawer log adds up to 360pt.

Agreed fix (option A, shrinkable banner): keep the header pinned but stop it from setting the column's minimum height. Limit the title to ~3 lines instead of fixedSize, give the body ScrollView layout priority over the banner, and keep only the collapsed drawer header row pinned, moving the expanded `RunLogContents` into the scrolling body. Do not measure sizes with GeometryReader (#096 layout-loop history).

Verification: in a narrow/short window with a long title and an expanded run drawer, the sidebar, content column and header all stay in place and are not clipped; the body still scrolls under a fixed header.

## Why
Improves reliability by fixing a #106 regression. Opening any plan can break the whole browser window: the sidebar slides under the titlebar, the task list goes blank and the detail header disappears. That makes the main browsing flow (pick a project, open a plan) unusable.

## How Summary
Keep #106's pinned header, but make sure the pinned part can never set the detail column's minimum height higher than the window allows. Limit the title to a fixed number of lines instead of `fixedSize`. Pin only the compact parts (header, progress panel, collapsed drawer row). Move the expanded run log (up to 360pt) into the scrolling body, and give the body `ScrollView` higher layout priority so it absorbs any squeeze. Don't measure anything with GeometryReader (#096).

**Files of note:**
- `Sources/Plans/PlanDetailView.swift` — `planScrollView` (~816) pinned banner; `detailHeader` title `fixedSize` (~311); `progressDrawer` (~730) expanded `RunLogContents` with `maxHeight: 360`; `body` (~175) stacks the plan above the discussion panel/composer.
- `Tests/PlansTests/PlanDetailViewTests.swift` — pure-helper tests (`showsProgressPanel` / `showsProgressDrawer`); add coverage for any new pure helper (e.g. title line limit constant / drawer placement).

## Diagnosis
**Most likely:** #106's pinned banner (`PlanDetailView.swift:824-850`) sits outside any `ScrollView`, so its full height counts toward the detail column's minimum height. The title's `.fixedSize(horizontal: false, vertical: true)` (`PlanDetailView.swift:311`) can report a very tall height at the narrow widths `NavigationSplitView` tries while working out minimum sizes. Together with the discussion composer stacked below the plan (`PlanDetailView.swift:188-200`), that minimum ends up taller than the window, so the hosting view overflows and clips the top of every column.
**Evidence:** Before #106 (`a7998b9`) the whole plan, header included, was inside one `ScrollView`, which has no minimum height. The symptom only appears when a plan is open in the detail column, not with "No Plan Selected". All three columns are shifted up together (sidebar under the traffic lights, detail header off the top), which points to the window's whole content being too tall rather than a bug in one column.
**Confidence:** high
**Alternative:** The expanded run-log drawer (`RunLogContents … .frame(maxHeight: 360)`, `PlanDetailView.swift:740-744`) pinned in the banner pushes the minimum height past the window on its own when a run exists. **Confidence:** medium. It makes the bug worse but probably isn't needed to trigger it.
**Alternative:** #108's sidebar `projectRow` `HStack` (`BrowserWindow.swift:332`). **Confidence:** low. It's the same pattern as `smartViewRow`, and the symptom needs a plan open in the detail column.
**To confirm:** Reproduce with a long-titled plan open and the window made short or narrow. Then temporarily wrap the pinned banner back inside the `ScrollView` (or give it `.layoutPriority(-1)` and remove the title `fixedSize`) and check the overflow goes away.

## How
- [x] 👁 Step 1: Reproduce the overflow: open a plan with a long title, then shrink the window's height and width. Then temporarily remove the title's `fixedSize` and move the banner back inside the `ScrollView`, and check that the sidebar, content column and header stay in place. This confirms the Diagnosis before any fix.
- [x] Step 2: In `detailHeader` (`PlanDetailView.swift:308-313`), replace `.fixedSize(horizontal: false, vertical: true)` on the title with a line limit (e.g. `.lineLimit(3)` through a named `static let titleLineLimit`, with a `.help`/tooltip showing the full title). Add a small test for the constant/helper in `PlanDetailViewTests.swift` first (TDD).
- [x] Step 3: In `progressDrawer` / `planScrollView`, pin only the drawer's header row. Move the expanded `RunLogContents` (with its `maxHeight: 360` and top inset) into the top of the scrolling body, so expanding the log never grows the pinned banner. Keep Stop/Done/expand on the pinned header row. Extract a pure placement helper if needed and test it first.
- [x] Step 4: Give the body `ScrollView` priority over the banner (e.g. `.layoutPriority(1)` on the `ScrollView` and/or `.frame(minHeight: 0)` on it), so any squeeze is taken by the scrolling body. No GeometryReader or measured sizes (#096).
- [x] 👁 Step 5: Re-run the Step 1 reproduction: long title, expanded run drawer, short/narrow window, with and without the discussion transcript open. Confirm nothing is clipped and the body still scrolls under a fixed header. Run `swift test`.

## Verification
- With a project selected and a plan open, the sidebar stays below the traffic lights with its Status section visible, the task-list column shows its rows, and the detail header stays pinned and visible. Check this with a long title, an expanded run drawer, an open discussion transcript, and the window at its minimum size.
- The plan body still scrolls under the fixed header (#106 behaviour kept), and expanding/collapsing the run log works from the pinned drawer row.
- `swift test` passes.

## Impact Scope
- Modify: `Sources/Plans/PlanDetailView.swift`, `Tests/PlansTests/PlanDetailViewTests.swift`
- Related (read-only): `Sources/Plans/BrowserWindow.swift` (split-view column widths / `windowMinHeight`)

## Assumptions

### Initial (from elaboration)
- [high] Root cause is #106's pinned banner, not #108. **Why:** the user confirmed it only happens with a plan open in the detail column, and #108 only changed a sidebar row to the same pattern `smartViewRow` already uses.
- [high] Fix shape is option A (shrinkable pinned banner) rather than a slim bar or reverting #106. **Why:** agreed with the user in /plan-discuss.
- [low] Title capped at 3 lines with a tooltip for the full title. **Why:** the user agreed "~3 lines"; the exact number and tooltip are a UX detail.
- [low] The expanded run log moves into the scrolling body, which changes #107's layout (the log used to sit in the pinned band). **Why:** agreed as part of option A; it means the log scrolls away with the body instead of staying put.

### Discovered during execution
- [high] The diagnostic build wraps the whole banner + body in one outer `ScrollView` and turns the old inner `ScrollView` into a plain `VStack`, which matches the pre-#106 structure. **Why:** this was the smallest edit that restores the single-scroll layout without moving any code blocks.
- [low] Removed the banner's `.background(.bar)` for the diagnostic too, because pre-#106 code didn't have it. **Why:** it's only there for a pinned banner. It doesn't affect layout sizing, so dropping it shouldn't change what the experiment shows.
- [high] `.textSelection(.enabled)` moved from the inner ScrollView to the outer one. **Why:** it keeps selection behaviour the same for the body (the header Text sets it itself).
- [high] Reverted the segment-1 diagnostic and built the fix on HEAD ef930a5 (pinned #106 banner kept, `.background(.bar)` kept). **Why:** the user confirmed the diagnosis and wants the pinned header.
- [low] Title capped with `.lineLimit(PlanDetailView.titleLineLimit)` (3) and `.truncationMode(.tail)`, with `.help(title)` showing the full title. **Why:** removes the vertical `fixedSize` that let a long title set an inflexible banner min height.
- [low] Expanded run log now renders via a new `expandedRunLog(_:)` as the first, full-bleed item inside the body ScrollView, gated by the new pure `showsExpandedRunLog(hasRun:isExpanded:)`. The pinned drawer is only the header row plus Divider. The floating-header ZStack is gone, and `drawerLogTopInset` dropped from 52 to 12 (now internal for testing). **Why:** expanding the log must never grow the pinned banner, and there is no overlay to clear any more.
- [high] Step 4 gives the BANNER `.layoutPriority(1)` and the ScrollView `.frame(minHeight: 0)`, which is the reverse of the plan's suggestion to raise the ScrollView's priority. **Why:** in a VStack the higher-priority child is laid out first and gets everything except the lower-priority children's minimums. A greedy ScrollView at priority 1 would always squash the banner to its minimum (title truncated to 1 line). With the banner at priority 1 and the ScrollView's min at 0, the banner keeps its natural height when it fits and the body takes the squeeze. When it doesn't fit, the banner compresses (nothing in it is vertically fixedSize), so it can't overflow the window.
- [low] Left the `.fixedSize()` on the header's "More" overflow `Menu`. **Why:** it's a single-line control with a constant height, so it doesn't change how the banner's min height scales.
- [low] Nesting the log's own ScrollView (capped `maxHeight: 360`) inside the body ScrollView depends on the inner ScrollView reporting its content height under an unbounded proposal. **Why:** that needs checking in the Step 5 observation (log shows up at a sensible height and isn't collapsed to 0).

## Changes
- Step 1: temporary diagnostic (pre-#106 single ScrollView, no title fixedSize) confirmed by the user to remove the overflow. Diagnosis confirmed; diagnostic reverted in segment 2.
- Steps 2-4 (commit 1062836): title capped at `titleLineLimit = 3` with a `.help` tooltip, replacing `fixedSize`. Only the drawer header row is pinned; the expanded run log moved into the scroll body (`expandedRunLog`, `showsExpandedRunLog(hasRun:isExpanded:)`, `drawerLogTopInset` 52→12). Banner `.layoutPriority(1)` + body ScrollView `.frame(minHeight: 0)`. Files: `Sources/Plans/PlanDetailView.swift`, `Tests/PlansTests/PlanDetailViewTests.swift` (3 new tests; PlanDetailViewTests 68/68 pass).

## Notes
_Additional context_
