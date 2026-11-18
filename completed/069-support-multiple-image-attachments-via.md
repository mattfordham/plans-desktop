# Support Multiple Image Attachments via Paste/Drag

**ID:** 069
**Created:** 2026-08-25T11:13
**Type:** feature
**Status:** completed
**Branch:** feature/069-support-multiple-image-attachments-via
**Completed:** 2026-08-25T13:09

## What
Support multiple image attachments via paste/drag

## Why
Adds value by letting a user attach more than one image to a plan they are
capturing. Single-image paste/drop already works end-to-end (#048 staging, #062
paste-command fix), but a second paste currently *replaces* the first — so a plan
that needs two screenshots (before/after, a stack trace plus a UI shot) can only
carry one. This lifts that one-image ceiling.

## How Summary
Extend the existing single-image capture path in the New Plan form from one
staged image to a list. The staged `imageData: Data?` becomes `imageDatas: [Data]`
across the modal state and the persisted `CaptureDraft`; the paste/drop callback
*appends* instead of replacing; the preview renders a row of thumbnails each with
its own Remove; and submit loops over the staged images, saving each under
Application Support and appending one markdown reference per image. Backward
compatibility for drafts persisted with the old single `imageData` key is handled
in `CaptureDraft.init(from:)`, following the existing `deep`-key migration
precedent. To also cover *several files dropped in one gesture*, the pasteboard
extractor gains a plural `pngDatas(from:)` variant. The §2 read-only constraint is
untouched — image bytes still go only to Application Support, never `.plans/`.

**Files of note:**
- `Sources/Plans/NewPlanModal.swift` — capture form state, `imagePreview`, submit
  path, and the `PlanNSTextView` paste/drop extractor (`pngData` → add `pngDatas`).
- `Sources/Plans/PlansStore.swift` — `CaptureDraft` struct; migrate `imageData:
  Data?` → `imageDatas: [Data]` with backward-compatible decoding.
- `Sources/Plans/CaptureImageStore.swift` — `saveImage` (call per image);
  `flattenDescription` gains a multi-URL variant.
- `Tests/PlansTests/PlansStoreTests.swift` — draft round-trip + `CaptureImageStore`
  tests; add array + multi-image-flatten coverage.
- `Tests/PlansTests/NewPlanDraftPersistenceTests.swift` — legacy-decode template
  (`testOlderDraftWithoutDeepKeyDecodesAsDeepFalse`) for the field migration.
- `Tests/PlansTests/PlanTextEditorImageTests.swift` — pasteboard→PNG extraction
  tests; add multi-image-per-pasteboard coverage.

## How
- [x] Step 1: (TDD) In `Tests/PlansTests/NewPlanDraftPersistenceTests.swift` and
      `Tests/PlansTests/PlansStoreTests.swift`, add failing tests for the
      `CaptureDraft` migration: (a) a draft encoded with the new `imageDatas` array
      round-trips; (b) a legacy draft JSON carrying a single `imageData` key decodes
      into a one-element `imageDatas` array; (c) a draft with neither key decodes to
      `[]`. Mirror `testOlderDraftWithoutDeepKeyDecodesAsDeepFalse`.
- [x] Step 2: Migrate `CaptureDraft` in `Sources/Plans/PlansStore.swift`: replace
      `var imageData: Data?` with `var imageDatas: [Data] = []`; update the
      memberwise `init` signature; in `init(from:)` decode `imageDatas` via
      `decodeIfPresent([Data].self, forKey: .imageDatas)`, falling back to wrapping a
      legacy `imageData` value (`decodeIfPresent(Data.self, forKey: .imageData)`) into
      a one-element array, else `[]`. Add `imageDatas` (and keep `imageData` for
      legacy decode) to `CodingKeys`. Make Step 1's tests pass.
- [x] Step 3: In `Sources/Plans/NewPlanModal.swift`, change `@State private var
      imageData: Data?` to `@State private var imageDatas: [Data] = []`, and update
      the paste/drop callback `onImagePasted: { imageData = $0 }` to *append*:
      `onImagePasted: { imageDatas.append($0) }`. Update the `.onChange(of:)`
      persistence trigger to observe `imageDatas`.
- [x] Step 4: In `Sources/Plans/NewPlanModal.swift`, update `loadDraft`, `clear`,
      and `persistDraft` to read/write `imageDatas` (list) instead of `imageData`,
      constructing `CaptureDraft(... imageDatas: imageDatas)`.
- [x] Step 5: Rework the `imagePreview` view to render one thumbnail per staged
      image in a horizontally-scrolling / wrapping row (`ForEach` over
      `imageDatas.indices`), each with its own Remove control that removes just that
      element and re-persists the draft. Render nothing when the list is empty so the
      no-image layout is unchanged.
- [x] Step 6: (TDD) In `Tests/PlansTests/PlansStoreTests.swift`, add a failing test
      for a multi-image flatten helper — appending N markdown image references (one
      per URL) to a description in order, and returning the description unchanged for
      an empty list.
- [x] Step 7: In `Sources/Plans/CaptureImageStore.swift`, add
      `flattenDescription(_ description: String, imageURLs: [URL]) -> String` that
      appends one `![pasted image](file://<abs-path>)` paragraph per URL (empty list
      → unchanged). Keep the existing single-URL overload or express it in terms of
      the new one. Make Step 6's test pass.
- [x] Step 8: Update `submit()` in `Sources/Plans/NewPlanModal.swift` to iterate the
      staged images: `saveImage` each under Application Support, collect the returned
      URLs, and flatten all references into the description via the new multi-URL
      helper. Preserve the per-image failure fallback (log and skip a failed save,
      never crash or block the capture). Reset `imageDatas = []` after submit.
- [x] Step 9: (TDD) In `Tests/PlansTests/PlanTextEditorImageTests.swift`, add a
      failing test that a pasteboard carrying multiple image objects / file URLs
      yields multiple PNGs.
- [x] Step 10: In `Sources/Plans/NewPlanModal.swift`, add a plural
      `PlanNSTextView.pngDatas(from:) -> [Data]` that maps ALL `NSImage`/`NSURL`
      objects (not just `.first`) to PNG, and route `captureImage(from:)` through it
      to fire `onImagePasted` once per extracted image — so several files dropped/
      pasted in a single gesture each stage. Keep `pngData(from:)`/`hasImage` working
      (express `pngData` as `pngDatas(...).first`). Make Step 9's test pass.
- [x] 👁 Step 11: Build and run the app (`./build.sh`), open the New Plan form, and
      manually verify: pasting two images stages two thumbnails; dropping several
      image files at once stages all of them; each Remove drops only its own
      thumbnail; capturing a plan produces one markdown image reference per staged
      image in the resulting task; and reopening the form restores all staged images.

## Verification
- `swift test` passes, including the new draft-migration, multi-image-flatten, and
  multi-image-extraction tests, and all pre-existing image tests still pass.
- Legacy drafts (persisted with a single `imageData` key) still load, appearing as
  one staged image.
- Manual (👁 Step 11): multiple images stage via both repeated paste/drop AND a
  single multi-file drop; per-thumbnail Remove works; a captured plan carries one
  `![pasted image](file://…)` reference per image; a dismissed/reopened form
  restores every staged image.
- §2 holds: no writes to any `.plans/` directory; image bytes land only under
  `~/Library/Application Support/Plans/attachments/`.

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/PlansStore.swift` — `CaptureDraft`: `imageData: Data?` →
  `imageDatas: [Data]` with backward-compatible decoding.
- [ ] `Sources/Plans/NewPlanModal.swift` — staged-image state, paste/drop append,
  multi-thumbnail preview, submit loop, and plural `pngDatas` extractor.
- [ ] `Sources/Plans/CaptureImageStore.swift` — multi-URL `flattenDescription`
  variant.
- [ ] `Tests/PlansTests/PlansStoreTests.swift` — array round-trip, legacy decode,
  multi-image flatten tests.
- [ ] `Tests/PlansTests/NewPlanDraftPersistenceTests.swift` — legacy single-`imageData`
  → array decode test.
- [ ] `Tests/PlansTests/PlanTextEditorImageTests.swift` — multi-image-per-pasteboard
  extraction test.

### Related Files (may need updates)
- `Sources/Plans/ReElaborateModal.swift` — sibling modal reusing `PlanTextEditor`;
  intentionally stages no images (`onImagePasted: { _ in }`). Left unchanged
  (New-Plan-only scope) — but its call site must still compile after the callback
  signature stays `(Data) -> Void`.

### Endpoints/UI Affected
- New Plan capture form (`NewPlanModal`) — image preview area becomes a
  multi-thumbnail row; paste/drop accumulates rather than replaces.

## Assumptions

### Initial (from elaboration)
- [low] "Multiple attachments" covers BOTH accumulating images across repeated
  paste/drop gestures AND dropping/pasting several files in a single gesture. The
  former needs only append-vs-replace; the latter also needs a plural
  `pngDatas(from:)` extractor (today's `pngData` returns one PNG via `.first`).
  **Why:** the description says "multiple attachments" without qualifying the
  gesture, and one-file-per-drop would be a surprising limitation; both paths are
  cheap given the existing extractor. Research Open Question #1.
- [low] No maximum image count and no dedupe of identical images — keep it simple.
  **Why:** unspecified in the description; the existing design has no cap or dedupe,
  and adding either is speculative. Noted risk: drafts live in UserDefaults, so many
  large PNGs can bloat it — flagged for follow-up rather than solved here. Research
  Open Questions #2, #4.
- [high] Scope is New-Plan-only; `ReElaborateModal` is NOT extended. **Why:**
  `ReElaborateModal` deliberately passes `onImagePasted: { _ in }` and stages no
  images today; the task is about attaching images to a plan being captured, and
  broadening to re-elaborate is out of scope. Research Open Question #3.
- [high] Image bytes continue to be flattened as `![pasted image](file://…)`
  markdown references in the plan description, with no structured "attachments"
  concept and no `.plans/` writes. **Why:** the plans-cc task format has no
  attachment field (confirmed in `desktop-app-spec.md`), and §2 forbids `.plans/`
  writes; this is the established, only-supported mechanism (#048).

### Discovered during execution
- [high] Implemented an explicit `encode(to:)` on `CaptureDraft` (not synthesized) alongside an explicit `CodingKeys` (current keys) and a separate decode-only `LegacyCodingKeys` for the pre-#069 scalar `imageData`. **Why:** keeping the legacy key out of `CodingKeys` guarantees encoded output never re-emits `imageData`, while a second keyed container in `init(from:)` still reads it for migration. This is the cleanest way to satisfy round-trip + legacy-decode + neither-key-present tests without a legacy key polluting the wire form.
- [low] In `submit()`, the multi-image path saves each staged image and chains `CaptureImageStore.flattenDescription` per image, appending one markdown reference per image in staging order. **Why:** `flattenDescription` appends a single reference, so chaining is behavior-equivalent for one image and a reasonable minimal extension for many. The task marks full multi-image submit as a later segment, so this keeps it compiling and correct without pre-empting that work.
- [low] `imagePreview` renders only the FIRST staged image with a Remove control that drops the first blob. **Why:** the segment explicitly defers the full multi-thumbnail preview to a later step and asks only for a minimal compiling bridge off the array.
- [high] Updated the two existing `#048` PlansStoreTests (`testCaptureDraftImageDataRoundTripsAcrossStoreInstances`, `testCaptureDraftNilImageDataRoundTripsAsNil`) to the new `imageDatas` array shape rather than deleting them. **Why:** they referenced the removed `imageData` property and would not compile; converting them preserves the store-round-trip coverage they provided.
- [low] Multi-thumbnail `imagePreview` uses a horizontal `ScrollView` + `HStack` (not a wrapping layout). **Why:** horizontal scroll keeps the modal's fixed layout stable and simple while preventing many thumbnails from blowing out width; a wrapping grid would grow the sheet's vertical space unpredictably. Thumbnails stack the Remove button beneath each image (icon-only `xmark.circle`) so per-image controls stay compact in the row.
- [low] `remove(at:)` is bounds-guarded with `imageDatas.indices.contains(index)` even though each Remove is a discrete re-rendering user action. **Why:** cheap defense against a stale captured index if two removals were ever coalesced; harmless no-op otherwise.
- [high] The multi-URL `flattenDescription(_:imageURLs:)` overload is implemented as a `reduce` over the single-URL overload rather than duplicating the format string. **Why:** guarantees the exact same per-URL markdown format and keeps one source of truth; empty list folds to the unchanged description automatically.
- [high] `submit()` now saves all staged images first, collecting surviving URLs into an array, then calls the multi-URL flatten helper ONCE. **Why:** replaces the per-image single-URL chaining with the intended #069 shape; a failed `saveImage` is logged and skipped so surviving images are still referenced and capture is never blocked.
- [high] `pngData(from:)` is re-expressed as `pngDatas(from:).first`; the new plural `pngDatas(from:)` is now the single extraction source, and `captureImage` fires `onImagePasted` once per extracted image. **Why:** keeps the existing single-image public signature and all callers (`hasImage`, single-image tests) working unchanged while making a single paste/drop of N images stage all N. Extraction priority order (raw png → tiff → NSImage objects → file URLs) is preserved.
- [high] When a pasteboard carries BOTH a raw `.png`/`.tiff` AND multiple items/objects, the raw single-blob branch is taken ONLY when `pasteboard.pasteboardItems?.count <= 1`; with multiple items the extractor skips straight to the NSImage/URL object branches. **Why:** `NSImage`/file URLs written together via `writeObjects` still expose a non-nil `data(forType: .tiff)` for the FIRST item only, so the raw branch would silently collapse a multi-image drop to one. Gating on item count preserves single-image priority order while letting the object branches see every image. Multi-image extraction therefore only applies to the object (NSImage/URL) paths, never to a genuine single raw-png/tiff source.

## Changes

### Segment 1 (steps 1–4)
- `Sources/Plans/PlansStore.swift`: migrated `CaptureDraft.imageData: Data?` →
  `imageDatas: [Data] = []`. Updated memberwise init. Added explicit `CodingKeys`
  (current keys) + decode-only `LegacyCodingKeys`; `init(from:)` decodes
  `imageDatas`, falling back to wrapping a legacy scalar `imageData` into a
  one-element array else `[]`; added explicit `encode(to:)` that emits only
  current keys (never re-emits legacy `imageData`).
- `Sources/Plans/NewPlanModal.swift`: `@State imageData: Data?` → `imageDatas:
  [Data] = []`; `onImagePasted` now *appends*; `.onChange` observes `imageDatas`;
  `loadDraft`/`clear`/`persistDraft`/`submit`/`imagePreview` all updated to the
  array (full preview + submit rework deferred to segments 2–3, kept compiling).
- `Tests/PlansTests/NewPlanDraftPersistenceTests.swift`: added
  `testMultipleImageDatasRoundTrip`, `testLegacySingleImageDataDecodesAsOneElementArray`,
  `testDraftWithoutAnyImageKeyDecodesAsEmptyArray`.
- `Tests/PlansTests/PlansStoreTests.swift`: converted the two `#048` `imageData`
  round-trip tests to `imageDatas`-array equivalents.
- Tests: `NewPlanDraftPersistenceTests` (11 passed), `PlansStoreTests` (62 passed);
  `swift build` clean.

### Segment 2 (steps 5–8)
- `Sources/Plans/NewPlanModal.swift`: reworked `imagePreview` into a horizontal
  `ScrollView`+`HStack` `ForEach` over `imageDatas.indices` — one thumbnail per
  staged image, each with its own bounds-guarded Remove (`imageDatas.remove(at:)`
  + `persistDraft()`); renders nothing when empty. `submit()` now collects saved
  URLs (skipping failed saves with a logged error) and calls the multi-URL
  `flattenDescription` once; `imageDatas` reset after submit.
- `Sources/Plans/CaptureImageStore.swift`: added `static func
  flattenDescription(_:imageURLs: [URL]) -> String` (a `reduce` over the single-URL
  overload; empty list → unchanged).
- `Tests/PlansTests/PlansStoreTests.swift`: added
  `testFlattenDescriptionAppendsOneReferencePerURLInOrder` and
  `testFlattenDescriptionReturnsInputUnchangedForEmptyURLList`.
- Tests: `PlansStoreTests` (64 passed, new tests RED→GREEN); `swift build` clean.

### Segment 3 (steps 9–10)
- `Sources/Plans/NewPlanModal.swift`: added `static func pngDatas(from:) -> [Data]`
  extracting ALL images (priority: raw png → tiff → every NSImage object → every
  file URL). Gated the single-blob raw png/tiff branch on
  `pasteboardItems?.count <= 1` so a multi-image gesture (which still exposes a
  non-nil `.tiff` for the first item) falls through to the object branches and
  captures every image. Re-expressed `pngData(from:)` as `pngDatas(from:).first`
  (all existing callers/tests unchanged). Routed `captureImage(from:)` through the
  plural extractor so `onImagePasted` fires once per extracted image.
- `Tests/PlansTests/PlanTextEditorImageTests.swift`: added
  `testExtractsMultiplePNGsFromMultipleFileURLs`,
  `testExtractsMultiplePNGsFromMultipleNSImages`,
  `testPluralExtractorReturnsEmptyForNoImage`.
- Tests: `PlanTextEditorImageTests` (15 passed, new tests RED→GREEN); `swift build`
  clean.

## Notes
_Additional context_
