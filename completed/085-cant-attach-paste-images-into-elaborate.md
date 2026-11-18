# Can't attach/paste images into elaborate plan form

**ID:** 085
**Created:** 2026-09-30T00:00
**Type:** feature
**Status:** completed
**Completed:** 2026-09-30T10:55
**Branch:** feature/085-cant-attach-paste-images-into-elaborate

## What
Can't attach/paste images into elaborate plan form.

## Why
Adds value by letting users paste or drop screenshots/images as guidance when
elaborating (and refining) a plan, the same way the "New Plan" capture form
already supports. Today images pasted into the Elaborate / Refine sheets are
silently discarded, so a user can't hand a screenshot to the elaboration run.

## How Summary
The image paste/drop engine (`PlanNSTextView`), the app-owned persistence
(`CaptureImageStore.saveImage`), and the markdown flattening
(`CaptureImageStore.flattenDescription`) already exist and are used by
`NewPlanModal`. They are only wired into the capture form, not the elaborate
forms: `ElaborateModal` and `ReElaborateModal` both pass `onImagePasted: { _ in }`
(a no-op) and stage nothing. The fix ports the three missing UI pieces into both
sheets — staged-image `@State`, a real `onImagePasted`, and a thumbnail preview
strip — and routes submit through a shared save+flatten helper so the flattened
`file://` markdown reaches the elaborate run via its existing `--description`
guidance channel. No filesystem writes to `.plans/` are added (§2): images go
only to Application Support, exactly as the capture form already does.

**Files of note:**
- `Sources/Plans/ElaborateModal.swift` — the Elaborate sheet; wire in staging, preview, and save+flatten on submit.
- `Sources/Plans/ReElaborateModal.swift` — the Refine sheet; same wiring (in scope for consistency).
- `Sources/Plans/CaptureImageStore.swift` — add a shared `saveAndFlatten` helper so the submit loop isn't copied a third time.
- `Sources/Plans/NewPlanModal.swift` — reference implementation of the preview strip and submit loop; reuse its `PlanTextEditor`/`PlanNSTextView` and route its submit through the new helper too.
- `Tests/PlansTests/PlansStoreTests.swift` — where `CaptureImageStore` is unit-tested; add coverage for the new helper.

## How
- [x] Step 1: Add a shared `CaptureImageStore.saveAndFlatten(description:imageDatas:)` helper (returns the description with each staged image saved under Application Support and its markdown ref appended, per-image save failure logged-and-skipped) so the save+flatten submit loop lives in ONE place instead of being duplicated per modal. Write failing unit tests first (TDD) in `Tests/PlansTests/PlansStoreTests.swift`: empty `imageDatas` returns the description unchanged; a non-empty list appends one `![pasted image](file://…)` ref per successfully-saved image, in order, under the injected Application Support temp dir and never inside `.plans/`.
- [x] Step 2: Refactor `NewPlanModal.submit()` to call the new `saveAndFlatten` helper instead of its inline save loop, preserving identical behaviour (same logger category, same log-and-skip on per-image failure). Run the `NewPlanDraftPersistenceTests` / `PlansStoreTests` image tests to confirm no regression.
- [x] Step 3: Wire image staging into `ElaborateModal`: add `@State private var imageDatas: [Data] = []`, change the editor's `onImagePasted: { _ in }` to `onImagePasted: { imageDatas.append($0) }`, and add the `imagePreview` thumbnail strip (ported from `NewPlanModal`, each thumb with its own bounds-guarded Remove) rendered under `editor`. Update the now-inaccurate doc comments that assert "no image paste".
- [x] Step 4: Update `ElaborateModal.submit()` so that when images are staged it routes the guidance through `CaptureImageStore.saveAndFlatten`, and passes the flattened markdown as the `--description` even when the typed guidance is empty (image-only elaboration). Keep the existing empty-and-no-images path submitting `nil` (the bare-elaboration behaviour) unchanged.
- [x] Step 5: Apply the same wiring (Steps 3–4) to `ReElaborateModal`: staged `@State`, real `onImagePasted`, preview strip, save+flatten on submit, and enable submit when images are staged even if the text box is empty (today it's disabled on empty text). Update its "no image paste" doc comments.
- [x] Step 6: Build and run the targeted test files (`swift test --filter PlansStoreTests --filter PlanTextEditorImageTests`) to confirm the new helper tests and the existing paste-engine tests all pass, and that the refactor caused no regressions.

## Verification
- `swift build` succeeds and `swift test --filter PlansStoreTests` / `--filter PlanTextEditorImageTests` pass, including the new `saveAndFlatten` tests.
- Pasting (⌘V) or dragging an image into the Elaborate #NNN sheet stages a thumbnail with a Remove control (previously nothing happened / the image was discarded).
- Submitting the Elaborate sheet with a staged image writes the PNG under `~/Library/Application Support/Plans/attachments/` and appends a `![pasted image](file://…)` reference to the guidance passed to the elaborate run — never into any `.plans/` directory.
- The Refine Plan sheet behaves the same way, and a bare (no-text, no-image) Elaborate submit still fires the plain elaboration with no `--description`.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/CaptureImageStore.swift` — add the shared `saveAndFlatten(description:imageDatas:)` helper.
- [x] `Sources/Plans/ElaborateModal.swift` — stage images, real `onImagePasted`, preview strip, save+flatten submit.
- [x] `Sources/Plans/ReElaborateModal.swift` — same wiring as ElaborateModal.
- [x] `Sources/Plans/NewPlanModal.swift` — route its submit through the shared helper (de-duplicate).
- [x] `Tests/PlansTests/PlansStoreTests.swift` — add unit tests for `saveAndFlatten`.

### Related Files (may need updates)
- `Sources/Plans/ExecuteModal.swift` — has the identical `onImagePasted: { _ in }` no-op but no guidance box, so it is OUT of scope.
- `Sources/Plans/PlanDetailView.swift` / `Sources/Plans/ProjectCard.swift` — present the sheets; no signature change expected (staging is internal `@State`).

### Endpoints/UI Affected
- Elaborate #NNN sheet — gains image paste/drop + thumbnail preview.
- Refine Plan #NNN sheet — gains image paste/drop + thumbnail preview.

## Assumptions

### Initial (from elaboration)
- [low] Scope covers BOTH `ElaborateModal` and `ReElaborateModal` (the Elaborate and Refine sheets), not just the one literally named "elaborate". **Why:** both are "elaborate plan forms" with the identical `onImagePasted: { _ in }` no-op and the same optional-guidance channel; the research recommended fixing both for consistency, and it is the complete reading of the user's phrasing. `ExecuteModal` is excluded because it has no guidance box.
- [low] When images are staged but the guidance text box is empty, submit stays enabled and passes the flattened image markdown as the `--description` (image-only elaboration guidance). **Why:** discarding staged images on an empty text box would reintroduce the exact "images silently dropped" defect this task fixes; passing the flattened markdown is the only way the image reaches the run.
- [low] Staged images are EPHEMERAL (lost on Cancel), with no draft persistence added. **Why:** `ElaborateModal`/`ReElaborateModal` are deliberately no-draft sheets (unlike `NewPlanModal`); adding UserDefaults draft persistence here would be scope creep beyond "attach/paste images".
- [high] Reuse the existing paste engine (`PlanNSTextView`/`PlanTextEditor`) and persistence/flatten (`CaptureImageStore`) as-is, and extract the duplicated submit save-loop into a shared `saveAndFlatten` helper rather than copying it a third time. **Why:** the engine is a subtle, well-tested layer (the `readablePasteboardTypes` override is the non-obvious ⌘V fix); reimplementing it is an anti-pattern the research explicitly warned against, and a third copy of the save loop would invite drift.

### Discovered during execution
- [low] `saveAndFlatten`'s skip-log uses a CaptureImageStore-owned `Logger` (category `CaptureImageStore`) rather than `NewPlanModal`'s `modalLog` (category `NewPlanModal`). **Why:** the helper now lives in `CaptureImageStore`, so its log belongs to that file's logger; the segment brief explicitly allowed the category to change since the behaviour (skip, don't crash) is what matters.
- [low] The `saveAndFlatten` test asserts the flattened output via `![pasted image](file://…)` substring parsing (extracting each saved path from the refs) rather than hardcoding the UUID filenames. **Why:** saved filenames are random UUIDs, so the test derives the paths from the returned string and verifies existence/location/bytes per path in order.
- [high] `ElaborateModal.imagePreview` is a near-verbatim port of `NewPlanModal.imagePreview` with the single `persistDraft()` call dropped from the Remove button. **Why:** the brief specified this port and ElaborateModal keeps no draft, so there is nothing to persist on removal.
- [low] `ReElaborateModal.submit()` calls `saveAndFlatten` UNCONDITIONALLY (not gated on `!imageDatas.isEmpty`), then passes its result as `description:`. **Why:** `saveAndFlatten` returns the trimmed description unchanged for empty `imageDatas`, so the text-only path is byte-identical to the old `description: trimmed` while avoiding a branch; `ElaborateModal` needed the explicit branch only because its no-image path sends `nil` (bare elaboration), whereas Refine always sends the text.
- [low] `ElaborateModal.submit()` keeps its two-branch shape (`imageDatas.isEmpty ? (nil-or-trimmed) : saveAndFlatten(...)`) rather than always calling `saveAndFlatten`. **Why:** the empty-box, no-image case must send `nil` (not `""`) to preserve the bare-Elaborate behaviour, and `saveAndFlatten("", [])` would return `""`, not `nil` — so the branch is required there.

## Changes

**Summary:** Wired the existing (but unused-here) image paste/drop feature into
the Elaborate and Refine sheets, and de-duplicated the submit save-loop into a
shared `CaptureImageStore` helper. Images pasted/dropped into either sheet are
now staged with a thumbnail preview and, on submit, written under Application
Support and appended to the guidance as `file://` markdown references that flow
to the elaborate/refine run through its existing `--description` channel. §2
upheld — no `.plans/` writes were added.

**Files changed (5, on branch `feature/085-cant-attach-paste-images-into-elaborate`):**
- `Sources/Plans/CaptureImageStore.swift` — added instance method
  `saveAndFlatten(description:imageDatas:)`: saves each staged PNG via `saveImage`
  (logging-and-skipping any per-image failure, never throwing), then returns the
  description with one markdown ref appended per saved image. Empty `imageDatas`
  returns the description unchanged. Added `import OSLog` + a `CaptureImageStore`
  logger.
- `Sources/Plans/NewPlanModal.swift` — replaced its inline save-loop in `submit()`
  with a single call to the shared `saveAndFlatten` helper (behaviour preserved;
  skip-log now under CaptureImageStore's logger).
- `Sources/Plans/ElaborateModal.swift` — added `@State imageDatas`, a real
  `onImagePasted: { imageDatas.append($0) }`, an `imagePreview` thumbnail strip
  (per-image bounds-guarded Remove) under the editor, and a two-branch `submit()`
  that routes staged images through `saveAndFlatten` (image-only submit sends a
  non-nil description) while preserving the exact no-image behaviour (empty box →
  `nil` bare elaboration, non-empty → trimmed text). Updated the "no image paste"
  doc comments.
- `Sources/Plans/ReElaborateModal.swift` — same staging/preview wiring; Refine
  button enabled on `!text.isEmpty || !images.isEmpty`; `submit()` guard relaxed to
  proceed on staged-images-only and routes through `saveAndFlatten`. Updated doc
  comments.
- `Tests/PlansTests/PlansStoreTests.swift` — added 2 TDD unit tests for
  `saveAndFlatten` (empty list unchanged; non-empty appends one ref per saved image
  in order, each file under the injected Application Support temp dir and never in
  `.plans/`).

**Tests / build (run in the worktree, independently re-verified by the orchestrator):**
- `swift build` — clean.
- `swift test --filter PlansStoreTests` — 80 passed, 0 failed (incl. 2 new).
- `swift test --filter PlanTextEditorImageTests` — 15 passed, 0 failed.
- `swift test --filter NewPlanDraftPersistenceTests` — 14 passed, 0 failed.

**Out of scope (unchanged):** `ExecuteModal` (has the same `{ _ in }` no-op but no
guidance box). The sheet presenters (`PlanDetailView`, `ProjectCard`) needed no
signature changes — staging is internal `@State`.

## Notes
Captured and elaborated autonomously via `/plan-execute … yolo`. The premise
holds: this app does have an "elaborate plan form" (`ElaborateModal`), and the
full image paste/attach feature already exists in `NewPlanModal` — it was simply
never wired into the elaborate sheets (a documented no-op).
