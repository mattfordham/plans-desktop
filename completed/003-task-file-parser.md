# Task-file parser mirroring lib/parse-tasks.js

**ID:** 003
**Created:** 2026-06-04T14:41
**Type:** feature
**Status:** completed
**Completed:** 2026-06-04T15:53
**Branch:** feature/003-task-file-parser
**Source:** Imported from desktop-app-spec.md

## What
Implement Data Contract 2. For each live project, parse tasks from `<path>/.plans/pending/` and `<path>/.plans/completed/`.

- Filename format `NNN-slug.md` (id = first 3 chars).
- Parse: title (first `# ` line); bold frontmatter fields (`**ID:**`, `**Created:**`, `**Type:**`, `**Status:**`, `**Branch:**`, `**Blocked by:**`) via per-line anchored patterns; and `##` sections (What/Why/How/Verification/etc.).
- **How-checkbox progress** = completed/total checkboxes counted only within `## How` (`- [ ]` / `- [x]`/`- [X]`); `0/0` = no-progress, not complete.
- Force `completed` status for files in `completed/` (directory is authoritative).
- Parse `Blocked by` into 3-digit ids; task is blocked if any id is not present in `completed/`.
- Produce per-project status counts and sort active tasks by status priority (`in-progress > in-review > review > elaborated > pending`) then by id.

Mirror `lib/parse-tasks.js` exactly; handle missing/empty dirs and missing fields defensively. Status & type vocabularies per §5.4.

Spec reference: §5 (Data Contract 2 — The `.plans/` Task Files).

## Why
Adds value by giving both UI surfaces a single, faithful source of task data. The menu bar glance (§1 Surface A, task #004) needs per-project status counts; the browser window (§1 Surface B, task #005) needs full task bodies, type/status badges, blocked state, and staleness signals. Mirroring `lib/parse-tasks.js` exactly (§5.5) keeps the read-only viewer consistent with plans-cc's own interpretation of the task-file contract, so the app never diverges from what the tooling itself reports. Decided to build the **full model now** (sections + Created/Branch) so #004/#005 consume it without reopening the parser — §5.5 explicitly permits these extensions.

## How
- [x] Step 1: Add `Sources/Plans/TaskParser.swift` defining the model structs. `TaskStatus` and `TaskType` as `String` enums over the exact §5.4 vocabularies (`pending`/`elaborated`/`in-progress`/`review`/`in-review`/`completed`; `bug`/`feature`/`refactor`/`chore`), each with an `unknown`-tolerant decode (missing/unrecognized `**Status:**`/`**Type:**` → `nil`, never crash). Define `TaskSection { heading: String; body: String }`, `Task` (id, title, type?, status, created?, branch?, blockedBy: [String], sections: [TaskSection], howProgress: (done: Int, total: Int), isBlocked: Bool, isCompletedDir: Bool), and `ProjectTasks` (projectPath, projectName, tasks: [Task], counts keyed by status). Document the struct/field intent in comments matching the `RegistryReader.swift` house style.
- [x] Step 2: Implement single-file parsing: read file text, derive `id` from the **first 3 characters of the filename** (§5.2), find title from the first line beginning with `# ` (trim the remainder), and extract bold frontmatter (`**ID:**`, `**Created:**`, `**Type:**`, `**Status:**`, `**Branch:**`, `**Blocked by:**`) via per-line patterns anchored to line start (`^\*\*Field:\*\*\s*(.*)$`). Parse defensively — every field may be absent (§5.3).
- [x] Step 3: Implement `## `-section splitting: a section runs from its `## Heading` line until the next `## ` line or EOF; capture heading text and verbatim body into `[TaskSection]` (full bodies for the Surface B markdown render, per the chosen scope).
- [x] Step 4: Implement How-progress (§5.3.1): count `- [ ]` (incomplete) and `- [x]`/`- [X]` (complete) lines **only** within the `## How` section range; expose as `(done, total)`. No How checkboxes ⇒ `0/0` (no-progress, not complete). Do not count checkboxes in any other section.
- [x] Step 5: Implement directory + status rules. List only `*.md` files in `<path>/.plans/pending/` and `<path>/.plans/completed/`, tolerating a missing or empty directory (return no tasks for that dir). Force `status = .completed` for any file under `completed/` regardless of its `**Status:**` line (directory is authoritative, §5.4). Parse `**Blocked by:**` into 3-digit ids (split on whitespace/commas); a task `isBlocked` if **any** of those ids is not present among the `completed/` ids (§5.5 step 5).
- [x] Step 6: Produce the per-project summary: counts by status (`pending`/`elaborated`/`in-progress`/`review`/`in-review`/`completed`), and a sorted active-task list ordered by status priority `in-progress > in-review > review > elaborated > pending`, then by id ascending (§5.5 steps 7–8). Derive `projectName` from the last path component of the project root (§1 Surface A).
- [x] Step 7: Add `Tests/PlansTests/TaskParserTests.swift` (XCTest, mirroring `RegistryReaderTests` temp-dir fixture pattern). Cover: id-from-filename; title extraction (and missing-title fallback); each frontmatter field present/absent; section splitting with bodies preserved; How-progress incl. `0/0`, uppercase `[X]`, and checkboxes-outside-How ignored; `completed/` forcing `.completed`; blocked-by resolution (blocked when a dep id is absent from `completed/`, unblocked when present); missing/empty `pending/`+`completed/` dirs; status-priority + id sort order; per-project counts. Use the repo's own real task files' shape as fixture templates where helpful.
- [x] Step 8: Verify the parser is purely read-only — it must only read files (no writes, creates, moves, or deletes anywhere under `.plans/`), satisfying §2 and acceptance item 7.

## Verification
Run `swift test` from the project root — all `TaskParserTests` (and existing `RegistryReaderTests`) pass. Confirm: ids derive from filename prefixes; titles/frontmatter/sections parse per §5.3; How-progress counts only within `## How` (`0/0` for none, uppercase `[X]` accepted); files in `completed/` always report `.completed`; blocked-by resolves against `completed/` ids; missing/empty task dirs are tolerated without crashing; per-project counts and the status-priority→id sort match §5.5. Spot-check by parsing this repo's own `.plans/` (it has `pending/` and `completed/` task files) and confirm counts/order look right. Confirm `swift build` succeeds and no code writes to `.plans/`.

## Assumptions

### Discovered during execution
- [low] Frontmatter matching uses `line.hasPrefix("**Field:**")` rather than a literal `NSRegularExpression` for the `^\*\*Field:\*\*\s*(.*)$` pattern. **Why:** `hasPrefix` is anchored to line start by construction (each line is matched individually), reads cleaner, and the segment prompt explicitly permits readable line-scanning over heavy regex as long as the match is anchored to line start. Whitespace after the marker is consumed by trimming, matching `\s*(.*)`.
- [low] Tolerant enum decode is exposed as a custom `init?(rawValueTolerant:)` (trims, then attempts exact `RawValue` lookup, else `nil`) rather than adding an `unknown` case to the enums. **Why:** the model uses `TaskType?`/`TaskStatus?` (optionals) for missing/unrecognized values, so an `unknown` case would be redundant; an optional-returning initializer keeps the vocabulary enums limited to the exact §5.4 strings.
- [high] Section bodies are joined verbatim with `\n` and NOT trimmed (blank lines preserved). **Why:** §5.3 / Surface B require full bodies for markdown rendering, so the body must round-trip faithfully.
- [low] `**Blocked by:**` is split on whitespace ∪ comma and empty tokens dropped; ids are kept as raw 3-char-ish tokens without validating they are exactly 3 digits. **Why:** the prompt says "split on whitespace/commas"; strict 3-digit validation / resolution against `completed/` ids is a project-level concern deferred to segment 2 (step 5).
- [high] How-progress matches checkbox lines after trimming leading whitespace (`- [ ]` / `- [x]` / `- [X]`), counting only within the section whose heading equals `How`. **Why:** §5.3.1 restricts counting to the `## How` range; trimming allows indented/nested checkboxes to count, which matches typical markdown task lists.
- [high] `parseProject(at:)` lists directory `.md` files sorted by filename for deterministic order, and `ProjectTasks.tasks` holds pending tasks first then completed tasks. **Why:** the spec doesn't mandate a tasks-array order, but a stable filename sort makes parsing deterministic/testable; the active-task sort (§5.5 step 8) is applied separately to `activeTasks`.
- [low] The active-task sort is exposed as a stored `activeTasks: [Task]` field on `ProjectTasks` (computed once in `parseProject`) rather than a computed property or method. **Why:** the prompt offered a choice; a stored field computed during assembly avoids recomputing the sort on every access and keeps `ProjectTasks` a plain value type that already owns `counts`.
- [low] Added an `activePriority: Int` computed property to `TaskStatus` to drive the status-priority sort (`in-progress`=5 … `pending`=1, `completed`=0). **Why:** centralizes the §5.5 step-8 ordering on the enum so the sort comparator stays readable; `completed` is given 0 defensively though completed/nil tasks are filtered out before sorting.
- [low] `parseProject` tolerates a per-file read failure (e.g. a file removed between directory listing and read) by skipping that file via `compactMap` rather than crashing. **Why:** extends the spec's missing/empty-dir tolerance to the live-filesystem race the read-only viewer can hit while polling; never throws.
- [high] `resolveBlocked` is applied only to pending tasks (completed tasks keep `isBlocked: false`). **Why:** a completed task is done, so blocked-state is meaningless for it; §5.5 step 5 frames blocking as a property of not-yet-completed work.

## Changes
- Added `Sources/Plans/TaskParser.swift`: model structs (`TaskStatus`/`TaskType` tolerant enums, `TaskSection`, `Task`, `ProjectTasks`) and single-file parsing (id-from-filename, title, anchored bold frontmatter, `## ` section splitting with verbatim bodies, How-progress counting within `## How` only). `status`/`title` modeled as optionals for tolerant decode; `completed/` forces `.completed`.
- Extended `TaskParser` with `parseProject(at:)` (injectable `FileManager`): lists `*.md` in `pending/`+`completed/` (tolerates missing/empty dirs), forces `.completed` for `completed/` files, resolves `isBlocked` against the `completed/` id set (blocked if any dep id absent). `ProjectTasks` gains per-status `counts` and a sorted `activeTasks` list (priority `in-progress > in-review > review > elaborated > pending`, then id ascending); `projectName` = last path component.
- Added `Tests/PlansTests/TaskParserTests.swift`: 22 XCTest cases (fixture temp-dir pattern) covering id/title/frontmatter/sections/How-progress/`completed/`-forcing/blocked-by/missing+empty dirs/sort/counts. All pass; parser confirmed purely read-only (only `contentsOfDirectory` + `String(contentsOf:)`).

## Notes
_Imported from desktop-app-spec.md_
