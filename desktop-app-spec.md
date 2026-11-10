# plans-cc Desktop App — Build Spec

This document is a self-contained specification for building a native macOS
desktop app that surfaces task data managed by **plans-cc**, a lightweight task
management system for Claude Code. You do not need any prior knowledge of
plans-cc to build this app — everything required is defined below.

You are expected to build this in a **separate project/directory** from
plans-cc itself. The plans-cc repository is referenced only as the source of
truth for two data contracts (the registry file and the task-file format),
which are fully described here.

---

## 1. Purpose & the Two Surfaces

plans-cc stores tasks as markdown files inside a `.plans/` directory at the
root of each project (repo) a developer works in. A single developer typically
has many such projects scattered across their machine. There is currently no
way to see work across all of them at once — you must `cd` into each project
individually.

This app fixes that. It is a personal, machine-wide viewer for plans-cc tasks
across **all** registered projects. It has two surfaces, at two altitudes:

### Surface A — Menu bar "glance" (the 20,000-foot view)

A macOS menu bar item that gives an at-a-glance summary of work across every
known project, without opening a window. From the menu bar the user should be
able to see, per project:

- The project's name (derive from the last path component of the project root)
- A breakdown of its task counts **by status** (e.g. 2 in-progress, 1 review,
  5 pending) rendered compactly using the glyph/label vocabulary in §5.

The glance is for "what's hot right now, everywhere" — it is counts and status,
not task bodies. Clicking a project (or a "Open browser" affordance) should
**drill down** into the browser window (Surface B), ideally pre-focused on that
project.

### Surface B — Cross-project browser window

A full window for actually reading and triaging work. It must let the user:

- **Read full task bodies** — the title and the markdown sections (What, Why,
  How with its checklist, Verification, etc.) for any task in any project.
- **Filter by status across ALL projects at once** — e.g. "show me everything
  that is `in-progress` everywhere", regardless of which project it lives in.
  Filtering is global, not scoped to one project.
- **Sort by staleness** — order tasks (or projects) by how recently they were
  touched, so stale/forgotten work floats up. Use the registry `lastSeen`
  timestamp (§4) as the staleness signal for a project; for finer-grained task
  staleness you may use the task file's modification time and/or the
  `**Created:**` field (§4.3).
- **Drill down from the glance** — opening the window from a project in the menu
  bar should land the user on that project's tasks.

> This spec defines **what** these surfaces must do and the exact **data
> contracts** they consume. It deliberately does **not** prescribe UI layout,
> view hierarchy, app architecture, or framework internals beyond "native
> macOS, menu bar + window." Those choices are yours.

---

## 2. Hard Constraint: The App Never Writes `.plans/` Itself

**The app process MUST NEVER write to any `.plans/` directory, edit or create
task files, change task status, or move tasks between projects.** In-process,
all `.plans/` content is strictly read-only input: the app reads the registry
and the task files and displays them.

Mutation of plans-cc data is **not** out of scope — but it happens in exactly
one place. The app bundles an Agent-SDK **runner subprocess**
(`Tools/work-task/run-task.ts`, built to `dist/run-task.js`), and that
subprocess is the **sole writer** of a project's `.plans/` directory and git
tree. The app drives it for the plans-cc lifecycle verbs — **capture**,
**elaborate**, **execute**, **review**, **delete**, **backlog**, and
**restore** — by spawning it with a `--mode` and the task id or description, then
rendering its NDJSON progress stream.

**Review** is the one INTERACTIVE verb. Every other mode runs fully
autonomously; `review` drives a guided `plan-review` of a `review` / `in-review`
plan and PAUSES on the skill's `AskUserQuestion`, parking each question as a
`{"kind":"question", …}` NDJSON line. The app renders the choices, and the user's
answer flows back to the agent over a **review-only stdin channel** — one
`{"kind":"answer", …}` line per reply, keyed by the same `toolUseId`. Only the
`review` mode opens that stdin pipe; it unblocks the paused agent and the run
continues. A review runs at one of **three locations**, threaded as
`--review-location`: the task's **kept** execution worktree, a fresh throwaway
**review worktree** off the task branch, or the project's **main** checkout. The
app's own preflight for the review (checking the main checkout's branch and
whether its tree is dirty, to warn before a `main` review) only **reads** git via
`rev-parse` / `status --porcelain` — it never mutates it; a `main` review leaves
main on the task branch until `/plan-complete`, and the per-project default
review location is stored in the app's `UserDefaults`, never in `.plans/`.

The **backlog** / **restore** pair defers a plan into `.plans/backlog/` and
brings it back to `.plans/pending/` (see §5.1). Both are offered from the plan
detail pane and are mutually exclusive: a task is either backloggable or
restorable, never both, since the skills move the file. Backlog is deliberately
offered ONLY for a `pending` / `elaborated` task, because `plan-backlog`
auto-pauses an active one — committing uncommitted work and switching branches —
and moving git state must never follow from a single in-app click. Deferring an
active task stays a deliberate CLI action.

The distinction that matters, and that must be preserved:

- The app **never hand-edits** a task file and never parses-and-rewrites one.
  There is no code path in the Swift app that opens a `.plans/` file for
  writing.
- Every mutation goes through the corresponding **plans-cc skill**, so
  plans-cc's own conventions (id allocation, file naming, status transitions,
  pending↔completed moves, git behavior) remain owned by plans-cc rather than
  reimplemented — and drifting — in the app.

> **Note:** this has been the real architecture since the runner was introduced
> with capture/elaborate/execute; the "pure viewer" wording above it was simply
> stale. Adding **delete** did not introduce mutation, it added one more verb to
> a runner that already had three.

### 2.1 Sanctioned exception: the plans-cc `plans-git.js` helper

For projects whose `.plans/` lives on a git branch (**branch mode**, §5.1.1),
the app also spawns one more plans-cc-owned subprocess:
`node ~/.claude/plans-cc/plans-git.js <subcommand>`, with cwd set to the project
root. Only two subcommands are ever invoked:

- **`sync`**: pulls the `plans` branch (rebase), renumbers colliding task ids,
  rebuilds counters, and pushes when it committed something. It aborts a
  rebase it cannot resolve on its own.
- **`migrate`**: converts a **local**-mode project to branch mode, but only
  after the user explicitly confirms the "Convert to tracked plans…" action
  (§6.1). It moves `.plans/` aside to a backup, creates the orphan `plans`
  branch worktree, copies and verifies every file, then removes the backup.

This is the same principle as the runner, not a new one. The helper is
plans-cc code, and it owns the locking (`.plans/.git-lock`), rebase,
renumber and push semantics. The app does not reimplement any of them. The
in-process rule still holds without exception: no Swift code path opens a
`.plans/` file for writing, runs a mutating `git` command against `.plans`, or
edits the code repo's `.gitignore`. The app's own `git` calls are all
read-only queries (`rev-parse`, `check-ignore`, `rev-list`, `remote`). They
never fetch and never take the lock. The app runs the helper with a login-shell
`node`, `GIT_TERMINAL_PROMPT=0` and `GIT_SSH_COMMAND="ssh -oBatchMode=yes"`, so
it can never block on a credential prompt. Timeouts are 60s for `sync` and
180s for `migrate`. The app never retries a failed `migrate`.

The helper always exits 0. The app reads its stdout instead:

| Output line | Meaning to the app |
|-------------|--------------------|
| `Renumbered #A → #B` | A task id collided with a remote one and was moved. Shown in the indicator's tooltip and logged. |
| `Warning: …conflict it cannot resolve automatically — rebase aborted…` | Sync outcome **conflict**. |
| `Warning: …locked by another commit…` | Sync outcome **locked**: another plans-cc commit held the lock. Not surfaced. |
| `Warning: plans sync failed…` / `Warning: plans-git failed…` | Sync outcome **failed**. Offline is the common case. |
| any other `Warning: …` | Kept for the tooltip. The outcome stays **synced**. A failed push, for example, already shows as "ahead". |
| no output | **synced**. A project with no upstream also prints nothing; the indicator shows "no upstream" from its own status query. |
| final `OK: …` / `Error: …` (`migrate`) | The convert result. An `Error:` that mentions `backup kept at <path>` names that path to the user. |

A helper that is missing from `~/.claude/plans-cc/plans-git.js` reads as a
failed sync, and as a failed convert.

Note that this constraint is about **`.plans/` task data**. The registry file at
`~/.claude/plans-cc/projects.json` is a separate, much simpler artifact: it is
normally written by the plans-cc tooling itself, and the app only needs to read
it — but the app does write it in one narrow case, when the user links a new
project (`RegistryWriter`, an atomic temp-file-and-move). It never rewrites the
registry just to prune stale entries; see §4.3.

---

## 3. Platform & Distribution

- **Platform:** native macOS, written in **Swift**.
- **Form factor:** a menu bar item (Surface A) plus a window (Surface B).
- **Audience:** this is **personal tooling** for a single developer's own
  machine. It is **not** a shipped product.
- **Distribution:** built and installed **separately** from the plans-cc npm
  package. It is its own project with its own build. Do not attempt to bundle it
  into, or ship it via, `npx plans-cc`.
- **No code-signing or notarization is required.** Because it is personal tooling
  run locally by its author, you do not need to sign or notarize the build.

---

## 4. Data Contract 1 — The Registry

The app discovers which projects exist by reading a single machine-wide registry
file written by plans-cc.

### 4.1 Location

```
~/.claude/plans-cc/projects.json
```

(`~` is the current user's home directory.)

### 4.2 Schema

```json
{
  "version": 1,
  "projects": [
    { "path": "/Users/alice/code/my-app",   "lastSeen": "2026-06-04T14:01:33.000Z" },
    { "path": "/Users/alice/work/other-repo", "lastSeen": "2026-05-30T09:12:00.000Z" }
  ]
}
```

Field definitions:

| Field | Type | Meaning |
|-------|------|---------|
| `version` | integer | Schema version. Currently always `1`. Treat unknown future versions defensively. |
| `projects` | array | The list of known projects. May be empty. |
| `projects[].path` | string | **Absolute** filesystem path to a project root. The project's `.plans/` directory lives at `<path>/.plans/`. |
| `projects[].lastSeen` | string | ISO 8601 timestamp of the last time the project was "touched" (a plans-cc action ran in it). Use this as the project-level staleness/recency signal. |

Notes:
- Projects self-register: every time a plans-cc action runs in a project (its
  dashboard launches, or `/plan-init` or `/plan-capture` runs), plans-cc appends
  or updates that project's entry and refreshes `lastSeen`. The app does not
  control this; it just reads the current state.
- Paths are deduplicated by exact string. No symlink canonicalization is done by
  the producer, so two different paths pointing at the same directory may both
  appear. Do not assume paths are canonicalized.

### 4.3 Live-prune semantics (the reader's job)

An entry is **stale** if its `.plans/` directory no longer exists — i.e. if
`<path>/.plans/` is not present on disk (the project was deleted, moved, or the
`.plans/` dir was removed). The reader must:

- **Ignore/drop** any registry entry whose `<path>/.plans/` does not exist. Do
  not show those projects.
- You are not required to rewrite the registry file to remove stale entries —
  the plans-cc tooling self-heals the file on its next write. Simply skipping
  stale entries when reading is sufficient and keeps the *stale-entry* path
  read-only. (This is scoped to pruning during reads. The app does write
  `projects.json` elsewhere — `RegistryWriter` registers a newly linked project
  — but it never rewrites the registry merely to garbage-collect stale
  entries.)

### 4.4 Tolerance: missing / empty / corrupt

The registry file may be in any of these states, and the app **must handle all
of them gracefully without crashing**:

- **Missing** — the file does not exist (no project has ever registered, or
  plans-cc is not installed). Treat as **zero known projects**.
- **Empty** — zero-byte file, or `{ "version": 1, "projects": [] }`. Treat as
  **zero known projects**.
- **Corrupt** — invalid JSON, or valid JSON of the wrong shape (e.g. `projects`
  is missing or not an array). Treat as **zero known projects** and never throw.

In every degenerate case the correct behavior is the same: show "no projects"
(an empty but functional UI), and keep polling/watching so the app recovers
automatically once a valid registry appears. Never surface a crash or a fatal
error dialog for a bad registry.

---

## 5. Data Contract 2 — The `.plans/` Task Files

For each non-stale project from the registry, read its tasks from
`<path>/.plans/`. The format below is the contract. The plans-cc repository
contains a **reference implementation of these exact parse rules** in
`lib/parse-tasks.js` — treat it as the source of truth. It is JavaScript; you
will re-implement the same behavior in Swift, but it should mirror what that
file does. A summary of its behavior is given in §5.5.

### 5.1 Directory layout under each project root

```
<project-root>/
  .plans/
    pending/        # active task files (NNN-slug.md) — see §5.2 for statuses
    completed/      # archived, completed task files (NNN-slug.md)
    backlog/        # consciously deferred task files (NNN-slug.md)
    config.json     # project settings: { "next_id": <int>, "git_commits": <bool>, ... }
    CONTEXT.md      # project knowledge      (optional to parse)
    PROGRESS.md     # current work status    (optional to parse)
    HISTORY.md      # completed-work archive (optional to parse)
```

- `pending/`, `completed/`, and `backlog/` are the three directories that contain
  task files. Any of them may be missing or empty — handle that.
- `backlog/` is a **holding pen** for consciously deferred plans: work the user
  has chosen to set aside rather than abandon. plans-cc populates it with the
  `plan-backlog` command and empties it with `plan-restore` (which moves a file
  back to `pending/`). Backlogged tasks are deferred, not outstanding — see §5.4
  and §5.5 for how they are kept separate from active work.
- `config.json` holds project-level settings such as `next_id` (the next task
  id to allocate) and `git_commits` (whether plans-cc auto-commits). You may read
  it but it is not required for the core views.
- The three top-level `.md` docs are project-level prose and are **optional to
  parse**. You may surface them later but they are not required for the views in
  §1.

### 5.1.1 Storage modes

plans-cc stores a project's `.plans/` in one of four **storage modes**. The app
resolves the mode with an exact port of plans-cc `detectMode`
(`~/.claude/plans-cc/lib/plans-git.js`), checking these rules in order:

| Mode | Rule | Meaning |
|------|------|---------|
| `none` | `git -C <root> rev-parse --show-toplevel` fails | The project root isn't a git repo. |
| `branch` | `git -C <root>/.plans rev-parse --show-toplevel` succeeds, its realpath **equals** realpath(`<root>/.plans`), **and** it differs from the realpath of the root's toplevel | `.plans` is the top of its own worktree. |
| `local` | `git -C <root> check-ignore -q .plans` succeeds | `.plans` is gitignored by the code repo and never committed. |
| `inline` | otherwise | `.plans` is tracked in the code repo. |

The "differs from the root's toplevel" clause matters. Without it, a project
whose root *is* `.plans`'s repo would be misread as branch mode.

**Branch-mode layout.** `.plans/` is a permanent `git worktree` of an
**orphan** branch (default name `plans`) in the project's own repo. That
branch shares no history with the code branches. It is checked out at
`<root>/.plans` and stays put whatever branch the main checkout is on, so a
capture made while the code checkout is on a review branch still lands on
`plans`. The code repo ignores `.plans`. `migrate` writes the entry to
`.git/info/exclude`; plans-cc may also add a slashless `.plans` line to
`.gitignore`. Execution worktrees under `<root>/.worktrees/<id>-…/` reach the
same data through a `.plans` symlink. The task-file contract (§5.2–§5.5) is
**identical** in every mode, so the app parses `.plans/` the same way
whatever the mode is.

A branch-mode `.plans/` holds entries that local mode doesn't have. The
parser must ignore all of them:

| Entry | What it is |
|-------|------------|
| `.git` (a **file**, not a dir) | The worktree's `gitdir:` pointer. |
| `.git-lock/` | plans-cc's `mkdir` commit mutex. It's transient, and plans-cc breaks a lock older than 60s (`lockStaleMs`). |
| `.gitignore` | Ignores `.DS_Store` and `.git-lock` inside the worktree. |
| `.gitattributes` | Merge drivers: `HISTORY.md merge=union`, `PROGRESS.md merge=ours`, `config.json merge=ours`. |
| `archive/` | Archived task files. plans-cc scans them only for id allocation, and `lib/parse-tasks.js` doesn't read them. |
| `config.json` → `sync` | The optional key `{ "remote": "origin", "branch": "plans", "auto_push": true }` (defaults shown). The app reads `sync.branch` (as the fallback branch name) and `sync.remote` for the status query. It never writes the key. |

`backlog/` is a task directory in every mode (see above), not an ignored
entry. The parser needs no special-casing for any of this. It lists only
`*.md` files directly inside `pending/`, `completed/` and `backlog/`, and the
reload signature covers only those three directories, so a lock appearing and
disappearing doesn't force a re-parse.
`TaskParserTests.testBranchModeWorktreeEntriesAreIgnored` pins this behavior.

**Sync status** is a port of plans-cc `syncStatus`, queried for branch-mode
projects only. It reads, without fetching or taking the lock:

- **branch**: `git -C .plans rev-parse --abbrev-ref HEAD`. When that fails or
  the HEAD is detached, it falls back to `sync.branch`, then to `plans`.
- **upstream**: whether `rev-parse --abbrev-ref --symbolic-full-name @{u}`
  succeeds.
- **ahead / behind**: from `rev-list --left-right --count HEAD...@{u}`. The
  left count is ahead and the right count is behind.
- **rebaseStuck**: whether either `rev-parse --git-path rebase-merge` or
  `rebase-apply` exists.

Because the app never fetches, "behind" is only as fresh as the last `sync`'s
pull. "Ahead" means local plans commits that a background push hasn't
delivered yet.

### 5.2 Task filename format

```
NNN-slug.md
```

- `NNN` is a task id zero-padded to a **minimum** of 3 digits, e.g. `006`, `012`,
  `001` — and, past 999, `1000`, `1001` (padding never truncates).
- The id is **the full run of leading digits before the first `-`** (regex
  `^(\d+)-`, ASCII digits only). Never take a fixed 3-character slice: that turns
  `1000` and `1001` into the same `100`. Keep the id as a string so `006` keeps its
  padding. A filename that doesn't match falls back to its first 3 characters.
- The rest is a human-readable slug derived from the title, e.g.
  `006-system-wide-dashboard.md`.
- Only files ending in `.md` are task files.

### 5.3 Task markdown structure

Each task file is markdown with this shape (example abbreviated):

```markdown
# System-wide plans registry + desktop app handoff spec

**ID:** 006
**Created:** 2026-04-13T00:00
**Type:** feature
**Status:** in-progress
**Branch:** feature/006-system-wide-dashboard
**Blocked by:** 004 005

## What
Prose describing the task.

## Why
Prose describing the motivation.

## How
- [x] Step 1: Do the first thing
- [x] Step 2: Do the second thing
- [ ] Step 3: Do the third thing

## Verification
1. Numbered checks the user runs to confirm the work.
```

Elements to parse:

- **Title** — the first line beginning with `# ` (a single leading `# ` then a
  space). Everything after `# ` on that line, trimmed, is the title.
- **Bold "frontmatter" fields** — lines of the form `**Field:** value` appearing
  near the top of the file. They are inline-bold markdown, not YAML. Match them
  with a per-line pattern anchored to the start of a line. The fields are:

  | Field | Required | Notes |
  |-------|----------|-------|
  | `**ID:**` | yes | The id (3+ digits); matches the filename prefix. |
  | `**Created:**` | usually | A timestamp (ISO-ish, e.g. `2026-04-13T00:00`). Use as a fallback staleness signal. |
  | `**Type:**` | usually | One of the type vocabulary (§5.4). |
  | `**Status:**` | usually | One of the status vocabulary (§5.4). |
  | `**Branch:**` | optional | Git branch name, when the task uses one. |
  | `**Blocked by:**` | optional | Space/comma-separated list of task ids this task depends on; a valid token matches `^#?(\d{3}\|[1-9]\d{3,})$` (exactly 3 digits, or 4+ with no leading zero). |

  Parse defensively: any field may be absent. A missing `**Status:**` for a file
  in `pending/` should be treated as unknown rather than crashing.

- **`##` sections** — second-level headings delimit sections. The common ones
  are **What**, **Why**, **How**, and **Verification**. Other sections you may
  encounter include **Impact Scope**, **Notes**, **Changes**, **Assumptions**,
  and **Issues**. A section runs from its `## Heading` line until the next `## `
  line (or end of file). Render section bodies as markdown in the browser
  window.

### 5.3.1 Checkbox progress convention (inside `## How`)

The `## How` section contains the task's steps as **markdown checkboxes**:

- `- [ ] ...` — an **incomplete** step.
- `- [x] ...` — a **complete** step (also accept uppercase `- [X]`).

**Progress = completed checkboxes / total checkboxes, counted only within the
`## How` section.** Do not count checkboxes that appear in other sections.
Concretely: start counting after the `## How` line, stop at the next `## ` line,
and within that range count lines matching `- [ ]` / `- [x]`. A task with no
checkboxes in How has progress `0/0` (show it as no-progress, not as complete).

### 5.4 Vocabularies (exact strings)

**Status** (the value of `**Status:**`):

| Status | Meaning |
|--------|---------|
| `pending` | Captured but not yet fleshed out. |
| `elaborated` | Has Why/How/Verification filled in; ready to start. |
| `in-progress` | Actively being worked on. |
| `review` | Execution complete, awaiting user review. |
| `in-review` | Actively being walked through in review. |
| `completed` | Done and archived. |

Directory ↔ status relationship:
- Files in `pending/` may carry any of: `pending`, `elaborated`, `in-progress`,
  `review`, `in-review`.
- Files in `completed/` carry `completed`. (Treat the containing directory as
  authoritative for completion: a file in `completed/` is completed regardless of
  what its `**Status:**` line says.)
- Files in `backlog/` are **BACKLOGGED**, a condition defined by the source
  directory rather than by a status. Unlike `completed/`, the directory does
  **not** override the file's `**Status:**`: a backlogged task retains its real
  `pending` / `elaborated` (etc.) status. "Backlogged" is orthogonal to the
  status vocabulary above — it is where the task lives, not what state it is in.

**Type** (the value of `**Type:**`):

| Type | Inferred from |
|------|---------------|
| `bug` | fix / bug / broken / error / crash / fail |
| `feature` | add / new / implement / create / support |
| `refactor` | refactor / clean / reorganize / restructure |
| `chore` | update / upgrade / config / setup / docs / test |

### 5.5 Reference implementation summary (`lib/parse-tasks.js`)

The plans-cc repo's `lib/parse-tasks.js` is the source of truth. Mirror this
behavior in Swift:

1. List `.md` files in `pending/`, `completed/`, and `backlog/`.
2. For each file, derive `id` from the leading digit run (`^(\d+)-`), not a
   fixed 3-character prefix (first 3 characters only as a fallback when the
   filename doesn't match).
3. Find the title from the first `# ` line.
4. Extract `Type`, `Status`, and `Blocked by` via per-line `**Field:**` patterns
   anchored to line start. (`Status` for a `completed/` file is forced to
   `completed`.)
5. Parse `Blocked by` into a list of ids (tokens matching
   `^#?(\d{3}|[1-9]\d{3,})$`, so `#1000` is valid and `#0430` is not); a task is
   **blocked** if any of those ids is not present in `completed/`.
6. Count How-section checkboxes into `{ done, total }` as in §5.3.1.
7. Produce a per-project summary of counts by status:
   `{ pending, elaborated, in-progress, review, in-review, completed }`.
8. Sort active tasks by status priority
   `in-progress > in-review > review > elaborated > pending`, then by id
   **numerically** (`999` before `1000`; a string compare gets this backwards).
   **This app deliberately deviates on the status order (task #028):** it lists
   `in-review > review > in-progress > elaborated > pending`, surfacing plans
   awaiting the user first. The numeric id tiebreak is the same.
9. Files scanned from `backlog/` keep their real `**Status:**` (see §5.4) and are
   carried in a **separate `backloggedTasks` collection**. They are **excluded**
   from the active-task set (`activeTasks`), from the by-status `counts`, and from
   `hasOutstandingWork` — a project whose only remaining work is backlogged has no
   outstanding work, because backlogged plans are deferred, not pending. Surface
   them as an opt-in section rather than mixing them into active counts.

You may extend beyond this (e.g. capturing full section bodies for the browser
window, reading `Created`/`Branch`), but do not contradict it.

---

## 6. Glance Vocabulary — Status & Type Glyphs

For the menu bar glance (Surface A), counts should be conveyed compactly using a
consistent glyph/label scheme so the user can read state without words. The
scheme below is a **suggested starting point — refine it to taste**; the only
hard requirement is that the six statuses are visually distinguishable and the
glance is legible at a glance.

### Status glyphs (suggested)

| Status | Glyph | Short label | Color intent |
|--------|-------|-------------|--------------|
| `in-progress` | 🔨 | WIP | active / blue |
| `in-review` | 👀 | REVIEWING | attention / yellow |
| `review` | 🟡 | REVIEW | attention / yellow |
| `elaborated` | 📋 | READY | neutral / teal |
| `pending` | ⚪ | TODO | muted / gray |
| `completed` | ✅ | DONE | success / green |

A compact per-project glance line might read, for example:
`my-app — 🔨2 🟡1 ⚪5` (2 in-progress, 1 in review-ish, 5 pending). You may
instead use SF Symbols, colored dots, or badge counts — your choice — as long as
the six statuses remain distinguishable.

### Type glyphs (suggested)

| Type | Glyph | Short label |
|------|-------|-------------|
| `bug` | 🐞 | bug |
| `feature` | ✨ | feat |
| `refactor` | ♻️ | refactor |
| `chore` | 🔧 | chore |

Type is most useful in the browser window (Surface B) as a per-task badge; the
glance can ignore type and group purely by status if that reads more cleanly.

### 6.1 Plans sync indicator and storage actions

**Branch-mode** projects (§5.1.1) get one sync glyph in the project card's git
footer, after the dirty dot. It mirrors the `plans:` line of the plans-cc
terminal dashboard (`buildPlansLine`). Projects in local, inline or `none`
mode show nothing, and the app spawns no helper for them. The card has room
for one mark, so it shows the most severe state, checked in this order:

| Priority | State | Dashboard mark | Color |
|----------|-------|----------------|-------|
| 1 | syncing (a sync is running) | `⟳ syncing` | muted `#a89984` |
| 2 | rebase stuck (`rebaseStuck`) | `⚠ rebase stuck` | red `#cc6666` |
| 3 | conflict (the last sync's outcome) | `⚠ sync conflict` | red `#cc6666` |
| 4 | no upstream | `⚠ no upstream` | amber `#fabd2f` |
| 5 | failed (including offline or a missing helper) | `⚠ sync failed` | amber `#fabd2f` |
| 6 | ahead / behind | `↑n` / `↓n` | amber `#fabd2f` |
| 7 | in sync | `✓` | green `#8ec07c` |

Red is reserved for states that need a manual fix. A failed sync is amber
because offline is the common cause, and it clears on its own. A `locked`
outcome is never surfaced. The glyph's tooltip carries the state, every
`Warning:` from the last sync, and any `Renumbered #A → #B` records.

Two actions live in the card footer's context menu (right-click):

- **Sync plans now** (branch mode). Clicking the glyph does the same. It
  bypasses the debounce, the auto-sync flag and the conflict back-off (§7),
  and it clears the back-off. It stays disabled while a sync is already
  running, a migrate is running, the project has no upstream, a rebase is
  stuck, or a run is in flight in that project. Syncing during a stuck rebase
  would let the helper abort the user's in-progress resolution.
- **Convert to tracked plans…** (local mode only). It is offered only when the
  project has a git remote (`git remote` is non-empty), no run is in flight
  there, and no convert is already running. It opens a confirmation that uses
  plans-cc's own wording: "Move `.plans/` onto a dedicated `plans` branch
  (pushed to `origin` when it exists)? Every file is copied and verified before
  the backup is removed." On confirm it runs `plans-git.js migrate` (§2.1) and
  reports the final `OK:` or `Error:` line. If the helper kept a backup, the
  report names its path. While migrate runs, polling and sync pause for that
  project, and the card stays listed even though `.plans` is briefly moved
  aside. The app never retries a convert and never edits or commits the code
  repo's `.gitignore`.

---

## 7. Live-Update Expectation

The app must reflect changes to the data **without the user manually
refreshing**. Tasks are edited continuously by plans-cc as work proceeds (status
changes, checkboxes tick, new task files appear), and the registry itself gains
new entries as new projects self-register.

Requirements:

- Changes to any registered project's `.plans/` directory (new/edited/removed
  task files, status changes, checkbox progress) should appear in the UI
  automatically and reasonably promptly.
- The **registry file** (`~/.claude/plans-cc/projects.json`) can also change at
  any time as new projects self-register or `lastSeen` updates. **Re-read it
  periodically** so newly registered projects appear without restarting the app.

The mechanism is **your choice** — filesystem watching (FSEvents / DispatchSource
/ `FileSystemWatcher`), periodic polling, or a hybrid. Pick whatever is simplest
and reliable for personal tooling. Polling every few seconds is perfectly
acceptable. Always re-validate stale projects (§4.3) on each refresh so deleted
projects drop out.

This app polls every **5s**. The read-only git queries run in a second pass:
branch, dirty, storage mode, sync status, and whether a local-mode project has
a remote. That pass is throttled per project. It re-queries on first sight,
when the `.plans/` signature changes, or after **30s**. Each `git` call has a
**10s** timeout, and a timed-out query reads as "unknown".

### 7.1 Branch-mode sync cadence

Plans written on another machine reach a branch-mode project's `.plans/` only
through a `sync`. So the app syncs in the background, without waiting for a
local plans-cc run. The scheduler runs at the end of every reload. There are
three triggers:

| Trigger | When | Gates skipped |
|---------|------|---------------|
| scheduled | Each reload, at most once per **90s** per project. | none |
| run finished | Right after any run in that project ends. | the 90s debounce |
| manual | "Sync plans now" (§6.1). | the debounce, the auto-sync flag, the conflict back-off and the lock check |

Every trigger skips a project that:

- isn't in branch mode,
- has no upstream, or a sync status that isn't known yet,
- has a stuck rebase,
- has a run in flight (so a sync never races a run's own plans commits),
- is already syncing, or
- is paused for a migrate.

Automatic triggers also skip:

- a project whose `.plans/.git-lock` is younger than **60s**, since that means a
  plans-cc commit is underway. plans-cc breaks older locks itself.
- when auto-sync is off. The flag is the `autoSyncPlans` UserDefaults key, and
  it defaults to on.

**Conflict back-off.** `sync` aborts a rebase it can't resolve, so another try
on a timer would only hit the same conflict. After a `conflict` outcome, a
project is left out of every automatic sync until the user clicks "Sync plans
now".

Syncs run concurrently in the background, at most one per project. When a
sync finishes, the app re-queries that project's git status right away. The
next 5s poll picks up any pulled task files through the normal signature
change.

---

## 8. Acceptance Summary

A correct build of this app:

1. Reads `~/.claude/plans-cc/projects.json`, tolerating missing/empty/corrupt
   files as "zero projects" without crashing.
2. Drops/ignores registered projects whose `<path>/.plans/` no longer exists.
3. For each live project, parses tasks from `.plans/pending/` and
   `.plans/completed/` per the §5 contract (id from filename, title, frontmatter
   fields, sections, How-checkbox progress, status/type vocabularies), mirroring
   `lib/parse-tasks.js`.
4. **Menu bar glance:** shows per-project task counts broken down by status using
   a distinguishable glyph/label scheme.
5. **Browser window:** reads full task bodies, filters by status across all
   projects at once, sorts by staleness, and is reachable by drilling down from
   the glance.
6. Updates live (watch or poll) and periodically re-reads the registry.
7. **Never writes `.plans/` data in-process** — the app itself never edits or
   moves a task file; all mutation (capture / elaborate / execute / delete) is
   delegated to the bundled runner subprocess, which drives the plans-cc skills
   (§2). The one other writer is the plans-cc `plans-git.js` helper (`sync`, and
   `migrate` after confirmation), spawned as a subprocess (§2.1).
8. Is native macOS (Swift), menu bar + window, built/installed separately from
   the plans-cc npm package, with no signing/notarization requirement.
9. **Storage modes:** detects each project's mode (`none` / `local` /
   `inline` / `branch`) with the `detectMode` rule. It parses a branch-mode
   `.plans/` worktree exactly like a local one, ignoring the `.git` file,
   `.git-lock/`, `.gitignore`, `.gitattributes`, `archive/` and the
   `config.json` `sync` key (§5.1.1). Local- and inline-mode projects look and
   behave as before: no indicator, and no helper spawns.
10. **Branch-mode sync:** syncs branch-mode projects in the background
    (90s debounce, right after a run in the project, or on demand). It never
    syncs a project that is busy, locked, rebase-stuck, has no upstream, or is
    backed off after a conflict. Each card shows one sync glyph by the §6.1
    priority, with a "Sync plans now" action (§7.1).
11. **Convert:** offers "Convert to tracked plans…" only for local-mode
    projects that have a remote and no run in flight. It confirms first, runs
    `plans-git.js migrate` once, and reports `OK:` / `Error:`, including any
    kept backup path (§6.1).
