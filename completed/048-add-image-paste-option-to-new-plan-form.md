# Add Image Paste Option to "New Plan" Form

**ID:** 048
**Created:** 2026-06-12T00:00
**Type:** feature
**Status:** completed
**Branch:** feature/048-add-image-paste-option-to-new-plan-form
**Completed:** 2026-06-15T00:00

## What
Add an image-paste affordance to the existing "New Plan" capture sheet
(`NewPlanModal`), so a user composing a plan can paste an image from the
clipboard (⌘V) — or drop one onto the editor — and have it captured alongside
the typed description. The image is stored in an app-owned location (NOT
`.plans/`, per the §2 read-only hard constraint) and a markdown image reference
is appended to the `--description` text handed to `TaskRunner.capture`, so the
plans-cc Node runner (the sole `.plans/` writer) records the reference in the
new task file.

## Why
Adds value by letting users attach visual context (screenshots, mockups, error
shots) when capturing a plan, instead of describing images in prose. Screenshots
are the natural artifact for many bug reports and UI tasks; supporting paste at
capture time removes the manual "save file, find path, type a markdown link"
friction and keeps the desktop app the fast front door for plans-cc capture.

## How
- [x] Step 1: Add an `imageAttachment` value type and storage helper. In a new
      `Sources/Plans/CaptureImageStore.swift` (or extend `PlansStore`), add a
      helper that, given an `NSImage`/`Data`, writes a PNG into an **app-owned**
      directory OUTSIDE any `.plans/` dir —
      `~/Library/Application Support/Plans/attachments/<uuid>.png` (resolve via
      `FileManager.default.url(for: .applicationSupportDirectory, …)`). Return
      the absolute file URL. This respects §2: the app never writes `.plans/`;
      it only writes its own Application Support sandbox. Mirror the
      `RegistryWriter` atomic-write style (write to temp, then move).
- [x] Step 2: Extend `PlansStore.CaptureDraft` (`PlansStore.swift:58`) with an
      optional `imageData: Data?` field (keep it `Codable`/`Equatable`; update
      the explicit memberwise `init` and all call sites). Persisting raw PNG
      `Data` in the per-project draft keeps the pasted image resilient across
      sheet dismissal / app relaunch, matching the existing text/toggle draft
      behaviour. UserDefaults remains the only sink (§2).
- [x] Step 3: Capture paste/drop in `PlanTextEditor`
      (`NewPlanModal.swift:279`). In the `NSTextView` subclass/coordinator,
      override paste handling (`readSelection(from:)` / `validateProposed…` or a
      custom `paste(_:)`) to detect image data on `NSPasteboard.general`
      (`.png`, `.tiff`) and route it to a new `onImagePasted: (Data) -> Void`
      closure on `PlanTextEditor`, instead of inserting it as text. Also accept
      a registered `NSDraggingDestination` image drop. Keep plain-text paste
      working unchanged.
- [x] Step 4: Wire image state into `NewPlanModal`
      (`NewPlanModal.swift:22`). Add `@State private var imageData: Data?`,
      pass `onImagePasted:` into `PlanTextEditor`, restore/persist it through
      `loadDraft`/`persistDraft`/`clear` alongside `text`, and reset it in
      `submit`. Update the `isSwitchingProject` guard reasoning to cover the new
      field.
- [x] Step 5: Show a thumbnail + remove control. Below the editor in
      `NewPlanModal.editor` (or as a sibling row), when `imageData != nil`
      render `Image(nsImage:)` scaled to a small preview with an "✕ Remove"
      button that clears `imageData` (and re-persists the draft). Gate it so the
      placeholder/layout is undisturbed when there's no image.
- [x] Step 6: Flatten the image into the description on submit
      (`NewPlanModal.submit`, `NewPlanModal.swift:257`). When `imageData != nil`,
      call the Step 1 helper to persist the PNG, get its absolute URL, and append
      a markdown reference — `\n\n![pasted image](file:///abs/path.png)` — to the
      trimmed description BEFORE calling `runner.capture(description:…)`. The
      runner contract is unchanged: a single `--description` string
      (`TaskRunner.swift:595`, `:307`) reaches the Node runner, which writes the
      task file with the reference.
- [x] Step 7: Tests (TDD — write first). In
      `Tests/PlansTests/PlansStoreTests.swift`, add a draft round-trip test
      asserting `imageData` survives `setDraft`/`draft(for:)`/relaunch-decode
      (mirror the existing draft tests at ~:464). Add a test for the Step 1
      storage helper: writing `Data` yields an existing PNG file under an
      Application-Support temp dir and never under any `.plans/` path. Add a
      test for the description-flattening helper: given non-nil image + text, the
      composed description contains the `![…](file://…)` reference and the
      original text; given nil image, the description is unchanged. Use the
      UUID-named per-test temp dir pattern from `setUpWithError`.
- [x] 👁 Step 8: Manual verification in the running app. Run `./build.sh`, open
      the New Plan sheet (⌘N), paste a screenshot (⌘V) and separately drag-drop
      an image; confirm the thumbnail appears, plain-text paste still works, the
      draft restores the image after Cancel+reopen, and a captured task's
      markdown contains the image reference. (Requires observing the GUI + the
      spawned capture run; the agent cannot self-verify this.)

## Verification
- `swift test` passes, including the new draft-round-trip, storage-helper, and
  description-flattening tests.
- The app NEVER writes under any `.plans/` directory: confirmed by code review
  (image writes target Application Support only) and by the storage-helper test
  asserting the written path is outside `.plans/`. §2 read-only is preserved.
- Plain-text paste and typing in the editor are unchanged; pasting/dropping an
  image instead attaches it (no raw bytes inserted as text).
- A pasted image survives sheet Cancel→reopen and app relaunch (draft
  persistence), and is cleared on successful submit / "Remove" / "Clear".
- 👁 In the running app: capturing a plan with a pasted image produces a new
  task whose markdown contains the `![…](file://…)` reference, and the
  referenced PNG exists on disk.

## Impact Scope

### Files to Modify
- [x] `Sources/Plans/NewPlanModal.swift` — add image `@State`, paste/drop
      handling in `PlanTextEditor`, thumbnail+remove UI, draft wiring, and
      description flattening in `submit`.
- [x] `Sources/Plans/PlansStore.swift` — add `imageData: Data?` to
      `CaptureDraft` (field, `init`, encode/decode) so pasted images persist as
      drafts.
- [x] `Tests/PlansTests/PlansStoreTests.swift` — draft round-trip with image,
      storage-helper, and description-flattening tests.

### Related Files (may need updates)
- `Sources/Plans/CaptureImageStore.swift` — NEW: app-owned (Application Support)
  PNG storage helper + description-flattening helper. (Could instead live as an
  extension on `PlansStore`; kept separate here for testability.)
- `Sources/Plans/TaskRunner.swift` — NO change expected. The `--description`
  string contract (`capture(...)` :595, `spawn` :307) already carries the
  flattened reference; verify no truncation/escaping issues with the longer
  description.
- `desktop-app-spec.md` — NO change required for the app contract, but the
  plans-cc task-markdown format (Data Contract 2) has no image field; the
  feature relies on a plain inline markdown reference, which is format-neutral.

### Endpoints/UI Affected
- New Plan sheet (`NewPlanModal`, opened via ⌘N / toolbar / card "+") — gains an
  image thumbnail + remove control and accepts paste/drop of images.

## Assumptions

### Initial (from elaboration)
Elaborated autonomously in skip mode (no interactive UI). Decisions made on the
user's behalf, grounded in codebase research:

- [high] "New Plan" form = the existing `NewPlanModal` capture sheet (`Sources/Plans/NewPlanModal.swift`, opened via ⌘N / toolbar / card "+"), NOT a new Surface-B compose view. **Why:** research found this sheet already implements text capture + per-project draft persistence; it is the single, canonical creation surface. (Corrects the pre-elaboration guess that the form lived in the Surface-B browser window generally.)
- [high] The Swift app must NOT write the image into any `.plans/` directory. Images are written to an app-owned location and a markdown reference is appended to the `--description` text so the plans-cc Node runner (the sole `.plans/` writer) records it. **Why:** `desktop-app-spec.md` §2 is an explicit hard constraint — "The app … MUST NEVER write to any `.plans/` directory"; the existing `TaskRunner`/Node-process boundary is the only sanctioned write path.
- [low] Pasted images are stored at `~/Library/Application Support/Plans/attachments/<uuid>.png` (app-owned), and referenced from the description as an absolute `file://` markdown link. **Why:** the task left storage "undecided"; Application Support is the standard writable, app-owned, §2-safe location, and an inline markdown reference needs no plans-cc task-format/CLI contract change (the format has no image field). Alternatives considered and rejected: a `.plans/attachments/` dir (violates §2), and base64-embedding into the description (bloats the task markdown). Flagged low — a UX/scope choice the source description did not specify; the spec author may prefer images live nearer the project or be deferred to a plans-cc format extension.
- [low] Image data is persisted in the per-project `CaptureDraft` (as `Data?`) so a pasted image survives Cancel→reopen and app relaunch, matching existing text/toggle draft behaviour. **Why:** consistency with the established draft pattern; minor storage cost. Flagged low — adds image bytes to UserDefaults, a tradeoff the description did not address.
- [low] Scope limited to clipboard paste (⌘V) plus drag-drop of a single image; no multi-image, no in-form annotation/cropping, no file-picker button in this task. **Why:** keeps the feature additive and matches the "paste option" framing; broader media handling would be a separate task.

### Discovered during execution
- [high] Created `CaptureImageStore` as a standalone struct (not an extension of `PlansStore`), mirroring `RegistryWriter`'s injectable shape (`fileManager` + base-dir constructor params). **Why:** Step 1 offered either option; a standalone struct keeps the §2-sensitive disk write isolated and trivially unit-testable, matching the existing writer's pattern.
- [low] `CaptureImageStore.applicationSupportDirectory` resolution falls back to `~/Library/Application Support` if `FileManager.url(for: .applicationSupportDirectory…)` throws (it effectively never does on macOS). **Why:** keeps the non-throwing `init` and a sane real-world default; the injected path is always used in tests.
- [low] Rebuilt `PlanTextEditor.makeNSView` to construct the `NSScrollView` + `PlanNSTextView` manually (text storage / layout manager / container) instead of `NSTextView.scrollableTextView()`. **Why:** `scrollableTextView()` returns a stock `NSTextView`; intercepting paste/drop requires our subclass to be the documentView. Insets/font/resizing config preserved to match prior behaviour.
- [low] Image extraction prefers pasteboard `.png`, then re-encodes `.tiff` via `NSBitmapImageRep`, then falls back to a dragged image file URL (read bytes → `NSBitmapImageRep` → PNG). **Why:** screenshots land as `.tiff`/`.png` on the pasteboard; file drops carry a URL. The plan named `.png`/`.tiff`; the file-URL path was added to make drag-drop of image files work as Step 3 requested.
- [low] Override both `paste(_:)` and `readSelection(from:)` for paste capture (plus `draggingEntered`/`draggingUpdated`/`performDragOperation` for drops). **Why:** `paste(_:)` is the primary ⌘V path; `readSelection` covers services-driven inserts — belt-and-suspenders per Step 3's "and/or" guidance.
- [high] The Step 5 thumbnail row is a separate `imagePreview` `@ViewBuilder` placed as a sibling between `editor` and the toggles row (not nested inside the `editor` ZStack). **Why:** keeps the editor/placeholder ZStack byte-for-byte unchanged so the placeholder alignment is undisturbed; the whole row is gated behind `if let imageData, let nsImage = NSImage(data:)` so nothing renders without a staged image.
- [low] Step 5 Remove control uses a `Label("Remove", systemImage: "xmark.circle")` button rather than a literal "✕ Remove" string. **Why:** the plan permitted "a labeled button"; an SF Symbol label is the idiomatic AppKit/SwiftUI affordance and avoids hardcoding a glyph. It sets `imageData = nil` then calls `persistDraft()` (text/toggles untouched).
- [high] Step 6 submit constructs `CaptureImageStore()` with its default (real) init, saves the PNG, and flattens via the static helper only when `imageData != nil`; a thrown save error is logged via `modalLog.error` and falls back to the plain trimmed description. **Why:** the save must never crash or block the capture (plan requirement); only tests inject a temp dir, so production uses the real Application Support container.
- [low] The 4 pre-existing `PlansStoreTests` failures (`Alpha`/`alpha` registry-ordering case mismatches) are unrelated to this segment — present on the base, in untouched tests. My diff to the test file is purely additive (5 new tests, all passing). **Why:** flagged so the failures aren't attributed to this work.

## Changes

### Segment 1 (steps 1–4)
- NEW `Sources/Plans/CaptureImageStore.swift` — injectable struct (mirrors
  `RegistryWriter`) that atomically writes pasted PNG bytes to
  `~/Library/Application Support/Plans/attachments/<uuid>.png` (outside any
  `.plans/`, §2-safe) and a pure `flattenDescription(_:imageURL:)` helper that
  appends `\n\n![pasted image](file://<abs-path>)` (or returns the text unchanged
  for a nil URL).
- `Sources/Plans/PlansStore.swift` — `CaptureDraft` gained `imageData: Data?`
  (Codable/Equatable; memberwise `init` defaults it to nil so older persisted
  drafts decode cleanly).
- `Sources/Plans/NewPlanModal.swift` — `PlanTextEditor` now takes an
  `onImagePasted: (Data) -> Void` closure; a new `PlanNSTextView: NSTextView`
  intercepts image paste (⌘V) and drag-drop (pasteboard `.png`/`.tiff`/image-file
  URL → PNG `Data`) and routes it to the closure, leaving plain-text paste
  unchanged. `NewPlanModal` added `@State imageData`, wired it through
  `loadDraft`/`persistDraft`/`clear`/`submit` and an `.onChange` handler.
- `swift build` clean.

### Segment 2 (steps 7→5→6, TDD order)
- `Tests/PlansTests/PlansStoreTests.swift` — 5 new tests: `CaptureDraft.imageData`
  round-trip across store reload (data + nil cases); `CaptureImageStore` saves a
  PNG under an injected Application-Support temp dir, contents match, and the
  path is never under any `.plans/`; `flattenDescription` appends a
  `![…](file://…)` reference when given a URL and returns the text unchanged for
  nil. All 5 pass.
- `Sources/Plans/NewPlanModal.swift` — added an `imagePreview` `@ViewBuilder`
  (thumbnail via `NSImage(data:)` → `Image(nsImage:).resizable().scaledToFit()`,
  max height ~80, plus a Remove button that clears `imageData` and re-persists
  the draft), gated on `imageData != nil` so the editor/placeholder layout is
  unchanged with no image. `submit()` now, when an image is staged, persists the
  PNG via `CaptureImageStore` and appends the markdown reference via
  `CaptureImageStore.flattenDescription` before calling `runner.capture`; a save
  failure logs and falls back to the plain trimmed description.
- Pre-existing unrelated `PlansStoreTests` failures (`testStartPolling…`,
  `Alpha`/`alpha` case ordering) confirmed present on the base branch
  (`c2f4d79`) — not introduced by this task.

## Notes
_Additional context_
