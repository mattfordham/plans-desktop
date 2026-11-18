# Image Paste From Clipboard And Image Drag And Drop Are Not Working For Attaching To The Prompt Dialogue

**ID:** 062
**Created:** 2026-08-14T21:03
**Type:** bug
**Status:** completed
**Completed:** 2026-08-17T12:52
**Branch:** fix/062-image-paste-and-drag-drop-not-working

## What
Image paste from clipboard (Cmd+V) and image drag-and-drop are not working for
attaching images to the new-plan / prompt input dialogue. Task #048 added image
paste support to the new-plan form, but in practice neither paste nor drop
attaches an image. Both should stage a PNG that is written to disk and referenced
from the plan description at submit time.

## Why
Improves reliability by making the image-attach feature added in #048 actually
work. The feature shipped without ever being verified in the running app, so the
two mechanisms (clipboard paste and drag-and-drop) are effectively broken. Users
expect to paste a screenshot or drag an image straight into the prompt.

## How Summary
Two independent AppKit bugs in the `PlanNSTextView` subclass make image capture
fail. (1) **Drag-and-drop:** `registerForDraggedTypes` is called in `init`, but
`NSTextView` re-derives its own registered drag types when `isRichText`/editing
config is set later in `makeNSView`, wiping the image types — so image drops are
refused. The fix moves registration to the *end* of `makeNSView`, after all text
view configuration. (2) **Clipboard paste:** `pngData(from:)` only reads raw
`.png`/`.tiff` pasteboard data, which many sources (screenshots, browsers,
Preview) don't populate — they offer an `NSImage`/promised object instead. The
fix adds an `NSImage`-from-pasteboard branch that re-encodes to PNG. The
extraction helper is made testable and covered by unit tests over several
pasteboard shapes.

**Files of note:**
- `Sources/Plans/NewPlanModal.swift` — `PlanTextEditor.makeNSView` (drag-type
  registration ordering) and `PlanNSTextView` (`pngData(from:)` extraction, drag
  registration). The single load-bearing file for the fix.
- `Sources/Plans/CaptureImageStore.swift` — `saveImage` / `flattenDescription`;
  already correct, reused as-is (storage is not the bug).
- `Tests/PlansTests/` — new test file for `pngData(from:)` extraction coverage.
- `Sources/Plans/ReElaborateModal.swift` — also embeds `PlanTextEditor`
  (no-op `onImagePasted`); must not regress plain-text paste there.

## How
- [x] Step 1: Make the pasteboard→PNG extraction testable. In
      `Sources/Plans/NewPlanModal.swift`, change `PlanNSTextView` from `private`
      and/or its `static func pngData(from:)` (and `hasImage(on:)`) from `private`
      to `internal` so XCTest with `@testable import Plans` can call the
      extraction directly. Keep behavior identical for now.
- [x] Step 2: Write failing tests (TDD red) in a new
      `Tests/PlansTests/PlanTextEditorImageTests.swift`. Build an in-memory
      `NSPasteboard` (or exercise the static helper against constructed
      pasteboard contents) for each shape and assert non-nil PNG `Data` comes
      back: (a) raw `.png` data, (b) `.tiff` data, (c) an `NSImage` object written
      via `writeObjects` (the currently-failing case), (d) a `file://` image URL.
      Also assert plain text / empty pasteboard returns nil. Run only this file:
      `swift test --filter PlanTextEditorImageTests`.
- [x] Step 3: Fix the paste root cause (TDD green): in `pngData(from:)`, after the
      `.png` and `.tiff` fast paths and before returning nil, add a branch that
      reads an `NSImage` from the pasteboard
      (`pasteboard.readObjects(forClasses: [NSImage.self], options: nil)` or
      `NSImage(pasteboard:)`), takes the first image's `tiffRepresentation`, wraps
      it in `NSBitmapImageRep`, and returns `.representation(using: .png, ...)`.
      Keep the existing fast paths and the file-URL fallback. Re-run the filtered
      tests until green.
- [x] Step 4: Fix the drag-and-drop root cause: remove the
      `registerForDraggedTypes([.png, .tiff, .fileURL])` call from
      `PlanNSTextView.init` and instead register the dragged types at the very
      end of `PlanTextEditor.makeNSView` — after `isRichText`, `isEditable`, all
      other configuration, and after `scrollView.documentView = textView` — so the
      subclass's image types survive `NSTextView`'s own re-registration. (Register
      additively / re-register alongside any inherited types so plain text/URL
      drop is not lost.)
- [x] Step 5: Guard against regressions in `ReElaborateModal.swift` (shares
      `PlanTextEditor` with a no-op `onImagePasted`): confirm plain-text paste and
      drop still fall through to `super` there — no image capture, text still
      pastes. Verify by reading the wiring; no behavioral change expected.
- [x] Step 6: Build the app and run the targeted tests: `swift build`, then
      `swift test --filter PlanTextEditorImageTests`. Ensure a clean build and
      green tests for the extraction logic.
- [x] 👁 Step 7: Manually verify in the running app (`./build.sh`): open the new
      plan form (Cmd+N), (a) copy a screenshot to the clipboard and press Cmd+V —
      an image thumbnail preview should appear; (b) drag an image file from Finder
      onto the editor — the drop should be accepted (copy cursor) and the same
      preview should appear. Submit and confirm the plan description references the
      saved `file://…/attachments/<uuid>.png`. AppKit drag registration and real
      paste cannot be unit-tested, so this manual run is the source of truth.

## Verification
- Copying a screenshot to the clipboard and pressing Cmd+V in the new-plan
  editor attaches the image (thumbnail preview appears).
- Dragging an image file from Finder onto the editor is accepted (copy cursor)
  and attaches the image.
- The saved plan description references the on-disk PNG under
  `Application Support/Plans/attachments/<uuid>.png`.
- Plain-text paste/drop in both the new-plan form and the re-elaborate sheet is
  unchanged.
- `swift test --filter PlanTextEditorImageTests` passes; `swift build` is clean.

## Impact Scope
_Fewer than 3 files modified (primarily `NewPlanModal.swift` plus one new test
file); detailed Impact Scope omitted._

## Assumptions

### Initial (from elaboration)
- [high] Two root causes: drag-type registration is wiped by `isRichText`/editing
  config set after `init`, and paste extraction misses `NSImage`-only
  pasteboards. **Why:** Confirmed by reading `NewPlanModal.swift` — `init`
  registers drag types at line 474 while `isRichText = false` is set later at
  line 425 in `makeNSView`, and `pngData(from:)` (530-546) only reads raw
  `.png`/`.tiff`/file-URL, never an `NSImage` object.
- [low] Fix scope is limited to the extraction helper + registration ordering (no
  new representable, no focus/first-responder change, no multi-image support).
  **Why:** Research recommended the minimal two-change fix and flagged focus as an
  open question, not a confirmed cause; #048 explicitly scoped out multi-image.
  Kept narrow to match the bug report; focus-on-open can be a follow-up if manual
  verification shows paste-on-open still fails.
- [low] Make `pngData(from:)`/`PlanNSTextView` `internal` (not `private`) to
  enable unit testing rather than testing purely via the running app.
  **Why:** The extraction logic is the broken part and is currently untested;
  exposing it internally is the least-intrusive way to add regression coverage
  under `@testable import Plans`, consistent with the project's TDD convention.
- [high] Reuse `CaptureImageStore.saveImage` / `flattenDescription` unchanged.
  **Why:** Research confirmed storage/flatten are correct; the defect is upstream
  in pasteboard extraction and drag registration only.

### Discovered during execution
- [high] Reproduced the failing NSImage-object paste case with a PDF-only pasteboard (`setData(pdfData, forType: .pdf)`) rather than `writeObjects([nsImage])`. **Why:** On this AppKit version `writeObjects([nsImage])` eagerly places raw `.tiff` bytes on the pasteboard, so the pre-existing `.tiff` branch already handled it and the test could NOT fail RED. A PDF-only pasteboard is readable as an `NSImage` object via `readObjects` but returns nil for `data(forType: .png/.tiff)`, faithfully mirroring real sources (Preview, browsers, screenshots) and correctly failing before the fix.
- [high] Placed the NSImage-object branch BEFORE the file-URL fallback in `pngData(from:)`. **Why:** Per segment instructions, so in-memory images win; the file-URL test still passes because `readObjects(forClasses: [NSImage.self])` returns nil for a bare `file://` URL, letting the URL branch handle it.
- [high] Read the object via `pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage` then re-encode its `.tiffRepresentation` through `NSBitmapImageRep`. **Why:** Matches the existing tiff/URL re-encode pattern in the same function and handles the object/promised-type case.
- [high] Marked the new test class `@MainActor`. **Why:** `PlanNSTextView` (an `NSTextView` subclass) is main-actor isolated, so its now-`internal static` helpers are too; without `@MainActor` the tests hit Swift 6 `SendingRisksDataRace` errors passing the pasteboard into the static method.
- [high] Moved image dragged-type registration from `PlanNSTextView.init` to the END of `PlanTextEditor.makeNSView`, registering additively (`registeredDraggedTypes + [.png, .tiff, .fileURL]`). **Why:** `NSTextView` re-derives its own dragged-type list when `isRichText`/editing config is applied after `init`, wiping the init-time registration and causing drops to be refused; registering last (after config and `documentView` install) survives that re-derivation, and additive registration preserves inherited plain-text/URL drop types.
- [low] Left `ReElaborateModal`'s no-op `onImagePasted: { _ in }` unchanged. **Why:** Step 5 read-and-confirm — the public `PlanTextEditor` API and plain-text paste/drop fall-through to `super` are unaffected by the registration/access-level changes; no compile or behavior problem found, so no edit made.

## Changes
- **Segment 1 (steps 1-3):** Fixed the clipboard-paste root cause.
  - `Sources/Plans/NewPlanModal.swift`: made `PlanNSTextView` `internal` (was
    `private`) and its `pngData(from:)` / `hasImage(on:)` `static` (was `private
    static`) for testability. Added an `NSImage`-from-pasteboard branch to
    `pngData(from:)` (before the file-URL fallback) that reads the image object via
    `readObjects(forClasses: [NSImage.self])` and re-encodes `.tiffRepresentation`
    through `NSBitmapImageRep` to PNG — covers screenshot/browser/Preview
    clipboards that expose only an object (no raw `.png`/`.tiff` data).
  - `Tests/PlansTests/PlanTextEditorImageTests.swift` (new): 6 cases over an
    off-general uniquely-named pasteboard — raw `.png`, raw `.tiff`,
    NSImage-object (PDF-only, the previously-failing case), `file://` URL,
    plain-string→nil, empty→nil; each asserts a re-decodable PNG. RED confirmed for
    the NSImage-object case before the fix; 6/6 green after.
- **Segment 2 (steps 4-6):** Fixed the drag-and-drop root cause.
  - `Sources/Plans/NewPlanModal.swift`: removed the
    `registerForDraggedTypes([.png, .tiff, .fileURL])` call from
    `PlanNSTextView.init` (with a comment noting why it must not go back there) and
    re-registered the dragged types at the very end of `PlanTextEditor.makeNSView`
    — after all text-view config and `scrollView.documentView = textView` —
    additively (`registeredDraggedTypes + [.png, .tiff, .fileURL]`) so the image
    types survive `NSTextView`'s own re-registration triggered by `isRichText`.
  - `ReElaborateModal.swift`: read-and-confirmed no regression — plain-text
    paste/drop still fall through to `super`; no change made.
  - `swift build` clean; `swift test --filter PlanTextEditorImageTests` 6/6 green.

- **Review fix (step 7 replay):** the original paste fix corrected the extraction
  helper but hooked it to a code path ⌘V never reached, so unit tests went green
  while the app stayed broken. Manual review caught it (drag worked, paste did
  not). Real root cause: with `isRichText = false`,
  `NSTextView.readablePasteboardTypes` is text-only and AppKit validates the
  Paste command against that list — `validateUserInterfaceItem(paste:)` returned
  false for an image-only clipboard, so ⌘V was never dispatched and both
  `paste(_:)` and `readSelection(from:)` were unreachable. Drag was unaffected
  because it validates against the separately-registered dragged types.
  - `Sources/Plans/NewPlanModal.swift`: override `readablePasteboardTypes` to
    advertise `.png`/`.tiff`/`.fileURL` (the load-bearing change), and funnel
    `paste`, `pasteAsPlainText`, `pasteAsRichText`, `readSelection(from:)` and
    `performDragOperation` through one shared `captureImage(from:)` helper.
  - `Tests/PlansTests/PlanTextEditorImageTests.swift`: added coverage for the
    paste entry point and the validation gate (RED confirmed via stubs).
  - `swift build` clean; full suite 321 tests, 0 failures. User re-verified paste,
    drag, and plain-text paste in the running app.

## Notes
Related prior task: #048 (add image paste option to new plan form) introduced
this feature. This task fixes it so it actually works. The `👁` manual step
(Step 7) is deferred to review under yolo/worktree mode.
