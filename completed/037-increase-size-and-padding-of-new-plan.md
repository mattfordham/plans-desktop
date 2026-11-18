# Increase Size And Padding Of New Plan Input

**ID:** 037
**Created:** 2026-06-07T00:00
**Type:** refactor
**Status:** completed
**Branch:** refactor/037-increase-size-and-padding-of-new-plan
**Completed:** 2026-06-07T00:00

## What
Increase size and padding of New Plan input. Should feel like a prompt input, like Claude, etc

## Why
Improves the New Plan capture experience by making the description editor feel
like a modern, inviting prompt box (Claude/ChatGPT style) rather than a cramped
multi-line field. A taller, more generously-padded input signals "type a real
plan here" and reduces the friction of the primary capture action.

## How
- [x] Step 1: In `Sources/Plans/NewPlanModal.swift`, raise `editorMinHeight` (line 55) from `96` to `160` so the editor shows several comfortable lines by default — a prompt-box-sized hero element.
- [x] Step 2: Increase the `TextEditor` internal padding (line 147) from `.padding(4)` to `.padding(.horizontal, 12).padding(.vertical, 10)` for breathable, Claude-style insets.
- [x] Step 3: Update the placeholder text padding (lines 165–166) to match the new editor insets (`.padding(.leading, 14)`, `.padding(.top, 12)`) so "Describe the plan…" stays aligned with the caret.
- [x] Step 4: Soften the editor corners — bump `cornerRadius` from `6` to `8` on both the background fill (line 150) and the border overlay (line 154) for a softer, prompt-input feel.
- [x] Step 5: Raise the modal minimum height (line 121) from `minHeight: 320` to `minHeight: 380` so the taller editor is the visual hero without crowding the toggles/buttons.
- [x] 👁 Step 6: Build (`swift build`) and run the app; open the New Plan modal and confirm the input now reads as a larger, well-padded prompt box (Claude-style) with the placeholder correctly aligned and buttons still accessible. _(✓ Confirmed during review. Follow-up during review: bumped the input font to `.title2` and replaced SwiftUI `TextEditor` with an `NSTextView`-backed `PlanTextEditor` so the placeholder/caret align exactly at the larger font.)_

## Verification
- The New Plan modal's description editor is visibly taller (≈160pt min) and more generously padded, reading as a prompt-style input box.
- The "Describe the plan…" placeholder remains aligned to the text caret after the padding change.
- `swift build` succeeds and the app launches; the modal's toggles and Clear/Cancel/Capture buttons remain visible and usable.

## Assumptions

### Initial (from elaboration)
- [low] Target editor min height of 160pt (≈4–5 lines). **Why:** Research offered 160–180pt as the "large prompt box" range; picked the lower end to stay compact on smaller screens while still feeling like a prompt input. UX value the source description didn't specify.
- [low] Internal padding 12h × 10v rather than symmetric 12. **Why:** Research suggested both; chose asymmetric to mirror Claude's slightly tighter vertical rhythm. A judgement call with multiple plausible options.
- [low] Modal min height raised to 380 (from 320). **Why:** Research flagged 380–420 as optional; chose 380 to accommodate the taller editor with minimal added screen real estate. Scope/UX call not specified by the task.
- [low] Corner radius bumped 6 → 8 (not 10). **Why:** Research offered 8–10; chose 8 as a subtle softening consistent with the existing 6pt language rather than a dramatic change.
- [high] Keep `TextEditor` (not switch to `TextField`), keep `.scrollContentBackground(.hidden)` and the ZStack placeholder overlay. **Why:** Research explicitly flagged these as the correct, intentional macOS patterns — single plausible path with clear precedent in the file.
- [high] Skipped font-size change (kept `.font(.body)`). **Why:** Font bump was marked optional in research; the codebase uses `.body` consistently, so leaving it avoids diverging from the existing type scale.

### Discovered during execution
- [high] SwiftUI `TextEditor` hides the underlying `NSTextView`'s `textContainerInset`, so a ZStack placeholder overlay drifts off the real caret as the font grows. **Resolved:** drove the text view directly via an `NSViewRepresentable` (`PlanTextEditor`) with an explicit, shared inset. Single correct fix — guessing pad values per font is fragile.

## Changes
- `Sources/Plans/NewPlanModal.swift`:
  - `editorMinHeight` raised `96` → `160` (taller default prompt box).
  - `TextEditor` internal padding `.padding(4)` → `.padding(.horizontal, 12).padding(.vertical, 10)`.
  - Placeholder padding `.leading 9 → 14`, `.top 4 → 12` (re-aligned to new caret inset); explanatory comment updated.
  - Editor corner radius `6` → `8` on both background fill and border overlay.
  - Modal `.frame` `minHeight: 320` → `380` (minWidth left at 460).
  - `swift build` succeeds. Step 6 (visual confirmation of Claude-style prompt feel) confirmed during /plan-review.
  - **Review follow-up:** input font raised to `.title2` for a bigger prompt feel. Replaced SwiftUI `TextEditor` with an `NSTextView`-backed `PlanTextEditor` (`NSViewRepresentable`) exposing a known `textContainerInset`, so the placeholder/caret align exactly at the larger font (SwiftUI `TextEditor` hides its intrinsic insets, which caused drift). Placeholder positioned against the shared `editorInset` + 5pt line-fragment padding via the `editorFont`/`editorInset` constants.

## Notes
- Single-file change scoped to `Sources/Plans/NewPlanModal.swift`; no Impact Scope section needed (< 3 files).
- No existing tests reference `NewPlanModal` (confirmed via search of `Tests/PlansTests/`). This is a pure visual/layout tweak with no behavioral logic to unit-test; verification is by build + visual observation.
