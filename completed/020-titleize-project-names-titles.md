# Titleize Project Names/Titles

**ID:** 020
**Created:** 2026-06-06T00:00
**Type:** feature
**Status:** completed
**Branch:** feature/020-titleize-project-names-titles
**Completed:** 2026-06-06T00:00

## What
Titleize project names/titles. For example: "plans-desktop" becomes "Plans Desktop". Handles casing and separators ("-", "_").

## Why
Adds value by making project names readable and presentable across all surfaces (menu bar glance, browser cards, plan detail). Raw directory names like `plans-desktop` or `my_project` read as filesystem artifacts; titleized names look intentional and polished.

## How
- [x] Step 1: Add a failing test `Tests/PlansTests/StringTitleizeTests.swift` covering hyphen, underscore, mixed separators, already-title-case, single word, and empty string cases for a new `String.titleized()` helper.
- [x] Step 2: Implement `Sources/Plans/String+Titleize.swift` with a `titleized()` extension that replaces `-`/`_` with spaces, splits camelCase boundaries, collapses extra spaces, and capitalizes each word — making the test from Step 1 pass.
- [x] Step 3: Apply the helper at the single derivation site in `Sources/Plans/TaskParser.swift:238` — change `lastPathComponent` to `lastPathComponent.titleized()` so all three display surfaces (MenuBarView, ProjectCard, PlanDetailView) inherit it automatically.
- [x] Step 4: Run the targeted tests (`swift test` filtered to the new + TaskParser tests) and confirm green.

## Verification
- "plans-desktop" renders as "Plans Desktop" in the browser cards, menu bar, and plan detail.
- Underscore-separated and mixed-separator names also titleize correctly.
- New `StringTitleizeTests` pass; existing `TaskParser` tests still pass.

## Impact Scope
_Fewer than 3 files modified (1 new helper, 1 source edit, test files) — no separate Impact Scope needed._

## Assumptions

### Initial (from elaboration)
- [high] Centralize the transformation at the single derivation point `TaskParser.swift:238` rather than at each display site. **Why:** Research confirmed `projectName` is derived in exactly one place and read unchanged by all three display surfaces; one edit covers everything and matches the project's single-source pattern.
- [high] Implement as a `String` extension in its own file, mirroring `TaskType+Glyph.swift` / `TaskStatus+Glance.swift`. **Why:** This is the codebase's established idiom for layering display helpers onto types.
- [low] Split camelCase boundaries (e.g. "PlansDesktop" → "Plans Desktop") in addition to separator handling. **Why:** The task only specified "-" and "_" separators and casing; camelCase splitting is an inferred nicety. Edge case: irregular caps like "plansDESKTOP" would over-split — acceptable given lowercase+separator is the naming convention.

### Discovered during execution
- [high] Updated the existing `TaskParserTests.testProjectNameFromLastPathComponent` to expect `tempDir.lastPathComponent.titleized()` instead of the raw component. **Why:** Titleizing at the derivation site intentionally changes the `projectName` contract; the test asserted the old raw value (a UUID temp-dir name) and had to track the new behavior. This is a 4th touched file beyond the three named in scope, but it is a test-only contract update directly caused by Step 3.
- [low] camelCase split treats each consecutive uppercase letter as a new word boundary, so acronym-style names (e.g. "plansDESKTOP") would over-split into "Plans D E S K T O P". **Why:** No precedent or spec for acronym handling; lowercase + separator is the established directory naming convention, and a simpler rule keeps the helper predictable for the common cases.
- [high] Treated a literal space (in addition to `-`/`_`) as a separator and collapsed runs/trimmed via split. **Why:** Spec asked to "collapse extra/empty spaces"; handling pre-existing spaces uniformly with separators is the natural reading and avoids double-spacing.

## Changes
- Added `Sources/Plans/String+Titleize.swift` — `String.titleized()` extension: normalizes `-`/`_`/space separators, splits camelCase boundaries, collapses/trims whitespace, capitalizes each word.
- Added `Tests/PlansTests/StringTitleizeTests.swift` — 6 cases (hyphen, underscore, mixed, camelCase, single word, empty). 6/6 pass.
- Edited `Sources/Plans/TaskParser.swift` (~line 238) — `lastPathComponent` → `lastPathComponent.titleized()` at the single project-name derivation site; all three display surfaces inherit it.
- Edited `Tests/PlansTests/TaskParserTests.swift` — updated `testProjectNameFromLastPathComponent` to expect the titleized value (contract change from titleizing at the derivation site). 22/22 pass.

## Notes
_Additional context_
