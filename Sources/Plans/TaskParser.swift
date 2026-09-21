import Foundation

/// The status of a task, drawn from the exact §5.4 vocabulary. The raw values
/// match the strings that appear after `**Status:**` in a task file. Decoding is
/// tolerant: a missing or unrecognized `**Status:**` value yields `nil` rather
/// than crashing (see `TaskStatus(rawValueTolerant:)`), mirroring plans-cc's
/// defensive parsing.
enum TaskStatus: String, Codable, CaseIterable, Equatable {
    case pending
    case elaborated
    case inProgress = "in-progress"
    case review
    case inReview = "in-review"
    case completed

    /// Tolerant lookup from a raw `**Status:**` value. Unknown or absent values
    /// (`nil`) map to `nil` — never a crash. The input is trimmed of surrounding
    /// whitespace before matching the exact §5.4 strings.
    init?(rawValueTolerant raw: String?) {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces),
              !trimmed.isEmpty,
              let value = TaskStatus(rawValue: trimmed) else {
            return nil
        }
        self = value
    }

    /// Sort priority for active-task ordering: higher sorts first. The order is
    /// the reverse of the header badge `glanceOrder`, so rows read
    /// `in-review > review > in-progress > elaborated > pending` (in-review at
    /// the top of the card, pending at the bottom).
    /// `completed` is not an active status and is given the lowest priority so
    /// it never floats above an active task should it ever be sorted.
    var activePriority: Int {
        switch self {
        case .inReview: return 5
        case .review: return 4
        case .inProgress: return 3
        case .elaborated: return 2
        case .pending: return 1
        case .completed: return 0
        }
    }
}

/// The type of a task, drawn from the exact §5.4 vocabulary. Decoding is tolerant
/// in the same way as `TaskStatus`: a missing or unrecognized `**Type:**` value
/// yields `nil`.
enum TaskType: String, Codable, CaseIterable, Equatable {
    case bug
    case feature
    case refactor
    case chore

    /// Tolerant lookup from a raw `**Type:**` value. Unknown or absent values
    /// (`nil`) map to `nil` — never a crash. The input is trimmed before matching
    /// the exact §5.4 strings.
    init?(rawValueTolerant raw: String?) {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces),
              !trimmed.isEmpty,
              let value = TaskType(rawValue: trimmed) else {
            return nil
        }
        self = value
    }
}

/// A failure overlay derived from the durable `run-outcomes.log` (#079), NOT
/// from the task file itself. A plan file cannot express "the last run failed" —
/// `TaskStatus` is a fixed six-case data contract — so this value is correlated
/// onto a `Task` by the store from the LATEST `RunOutcome` for the task's
/// `(projectPath, taskID)` key. A `nil` `failure` on a `Task` means healthy: no
/// failing outcome, or a since-superseded one.
///
/// Only carries the fields the UI needs to render the failure banner and its
/// retry affordance; the full `RunOutcome` (cost, turns, mode) stays out of the
/// parsed model.
struct TaskFailure: Equatable {
    /// The terminal classification of the latest run (`truncated`, `error`,
    /// `crashed`, `stranded`). The store only builds a `TaskFailure` for the
    /// failing classifications; `completed` never produces one.
    let classification: RunOutcome.Classification

    /// The human-readable error message from the run (a streamed `error` line, a
    /// budget/turn-cap message, or a generic nonzero-exit message), or `nil` when
    /// the run recorded none.
    let errorMessage: String?

    /// The raw terminal stop reason (`error_max_budget_usd`, `error_max_turns`,
    /// …), or `nil` when no `done` line was seen.
    let stopReason: String?

    /// The ISO-8601 timestamp of the failing run, carried through verbatim.
    let timestamp: String
}

/// A `## ` second-level section of a task file. `heading` is the text after the
/// `## ` marker (trimmed); `body` is the verbatim text from after the heading
/// line up to (but excluding) the next `## ` line or end of file. Bodies are kept
/// in full so the browser window (§1 Surface B) can render them as markdown.
struct TaskSection: Equatable {
    let heading: String
    let body: String
}

/// A single parsed task file (§5.3). Fields mirror the bold frontmatter and
/// structural elements of the markdown; optional fields are `nil` when the
/// corresponding line is absent, matching the defensive parsing the spec
/// requires (every field may be missing).
struct Task: Equatable {
    /// The 3-character id taken literally from the start of the filename (§5.2).
    let id: String

    /// The title — the text after the first `# ` line, trimmed. `nil` when the
    /// file has no `# ` line.
    let title: String?

    /// The `**Type:**` value, tolerant-decoded; `nil` when absent/unrecognized.
    let type: TaskType?

    /// The effective status. For a file under `completed/` this is forced to
    /// `.completed` regardless of the `**Status:**` line (the directory is
    /// authoritative, §5.4). Otherwise it is the tolerant-decoded `**Status:**`
    /// value, or `nil` when absent/unrecognized.
    let status: TaskStatus?

    /// The raw `**Created:**` value (kept as a `String`; date parsing is deferred
    /// to a later task). `nil` when absent.
    let created: String?

    /// The raw `**Branch:**` value. `nil` when absent.
    let branch: String?

    /// Whether the task has a live `**Worktree:**` field — i.e. it was executed
    /// with the `keep` keyword so its execution worktree survives for isolated,
    /// concurrent review (the field is written by plans-cc `plan-execute` and
    /// stripped by `plan-complete` at teardown). `true` only when the field is
    /// present AND its value is non-empty; a stripped/blank `**Worktree:**` is
    /// `false`. This mirrors the plans-cc dashboard TUI's `kept` boolean, which
    /// drives its `⌂ kept` badge. The field only meaningfully appears on
    /// `review` / `in-review` tasks.
    let isKeptWorktree: Bool

    /// The 3-digit ids parsed from `**Blocked by:**` (split on whitespace and
    /// commas). Empty when the field is absent or lists nothing.
    let blockedBy: [String]

    /// The `## ` sections in file order, each with its heading and verbatim body.
    let sections: [TaskSection]

    /// Checkbox progress counted only within the `## How` section (§5.3.1).
    /// `(done: 0, total: 0)` means no How checkboxes — no-progress, NOT complete.
    let howProgress: (done: Int, total: Int)

    /// Whether this task is blocked by an unmet dependency. This is a project-
    /// level concern (it depends on which ids exist under `completed/`) and is
    /// resolved in segment 2; single-file parsing leaves it `false`.
    let isBlocked: Bool

    /// The run-failure overlay (#079), correlated from the latest `RunOutcome`
    /// for this task's `(projectPath, taskID)` key. `nil` = healthy (no failing
    /// outcome). This is NOT parsed from the task file — a plan file cannot
    /// express failure — so single-file parsing leaves it `nil`; the store fills
    /// it in during reload (segment 2). Threaded onto the model here, alongside
    /// `isBlocked`, so the type is complete once the correlation lands.
    let failure: TaskFailure?

    /// Whether this file was found under `completed/`. Threaded in by the caller
    /// so the parser can force `status` to `.completed`.
    let isCompletedDir: Bool

    /// Whether this file was found under `backlog/` (#077). Threaded in by the
    /// caller so the browser can distinguish backlogged plans. Unlike
    /// `completed/`, backlog is a SOURCE DIRECTORY only — it does NOT force a
    /// status; a backlogged file keeps its real `**Status:**` (`pending` /
    /// `elaborated`).
    let isBacklogged: Bool

    /// Memberwise initializer with `failure` defaulting to `nil` (#079). The
    /// explicit init exists so the parser and the many call sites/tests that omit
    /// the run-failure overlay continue to compile unchanged after the field was
    /// added; the store reconstructs a `Task` supplying `failure` during reload
    /// correlation (segment 2). Mirrors the same defaulted-field pattern
    /// `ProjectTasks` uses for its git fields.
    init(
        id: String,
        title: String?,
        type: TaskType?,
        status: TaskStatus?,
        created: String?,
        branch: String?,
        isKeptWorktree: Bool,
        blockedBy: [String],
        sections: [TaskSection],
        howProgress: (done: Int, total: Int),
        isBlocked: Bool,
        isCompletedDir: Bool,
        isBacklogged: Bool,
        failure: TaskFailure? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.status = status
        self.created = created
        self.branch = branch
        self.isKeptWorktree = isKeptWorktree
        self.blockedBy = blockedBy
        self.sections = sections
        self.howProgress = howProgress
        self.isBlocked = isBlocked
        self.isCompletedDir = isCompletedDir
        self.isBacklogged = isBacklogged
        self.failure = failure
    }

    /// Hand-written `Equatable` (#066). Swift cannot synthesize the conformance
    /// here because `howProgress` is a TUPLE `(done: Int, total: Int)`, and
    /// tuples do not conform to protocols.
    ///
    /// This `==` is load-bearing: it gates whether a reload PUBLISHES a new
    /// `projects` value, so a field omitted here would cause a real on-disk
    /// change to be silently dropped from both surfaces. Every one of the
    /// fourteen stored properties is therefore compared, in declaration order:
    /// `id`, `title`, `type`, `status`, `created`, `branch`, `isKeptWorktree`,
    /// `blockedBy`, `sections`, `howProgress` (both tuple elements), `isBlocked`,
    /// `failure`, `isCompletedDir`, `isBacklogged`. If a property is ever ADDED to
    /// `Task`, it MUST be added here too.
    static func == (lhs: Task, rhs: Task) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.type == rhs.type
            && lhs.status == rhs.status
            && lhs.created == rhs.created
            && lhs.branch == rhs.branch
            && lhs.isKeptWorktree == rhs.isKeptWorktree
            && lhs.blockedBy == rhs.blockedBy
            && lhs.sections == rhs.sections
            && lhs.howProgress.done == rhs.howProgress.done
            && lhs.howProgress.total == rhs.howProgress.total
            && lhs.isBlocked == rhs.isBlocked
            && lhs.failure == rhs.failure
            && lhs.isCompletedDir == rhs.isCompletedDir
            && lhs.isBacklogged == rhs.isBacklogged
    }
}

/// A project's parsed tasks plus a per-status count summary (§5.5 step 7).
/// Assembled in segment 2; defined here so the model is complete.
struct ProjectTasks: Equatable {
    /// The project root path (the registry `path`).
    let projectPath: String

    /// The project's display name — the last path component of `projectPath`.
    let projectName: String

    /// The registry `lastSeen` value, carried verbatim as the raw ISO string
    /// (parsing to a `Date` is deferred to sort time in the browser view model,
    /// keeping this Foundation-only type free of date interpretation). `""` when
    /// no `lastSeen` was supplied (e.g. older call sites / tests).
    let lastSeen: String

    /// All parsed tasks for the project (pending + completed), in directory-scan
    /// order (`pending/` then `completed/`, each sorted by filename).
    let tasks: [Task]

    /// Counts of tasks keyed by status (§5.5 step 7). Statuses with zero tasks
    /// may be absent from the dictionary. Tasks with a `nil` status are not
    /// counted toward any bucket.
    let counts: [TaskStatus: Int]

    /// The ACTIVE (non-completed, non-`nil`-status) tasks sorted by the §5.5
    /// step-8 ordering: status priority `in-progress > in-review > review >
    /// elaborated > pending`, then by id ascending. Completed tasks and tasks
    /// whose status failed to decode are excluded.
    let activeTasks: [Task]

    /// The BACKLOGGED tasks (files under `.plans/backlog/`), kept SEPARATE from
    /// `tasks`/`counts`/`activeTasks` so backlog never inflates active work or
    /// status counts (#077). Backlog is a source directory, not a status: each
    /// task keeps its real `**Status:**`. Sorted like `activeTasks` — status
    /// priority descending, then id ascending.
    let backloggedTasks: [Task]

    /// Whether the project has any outstanding work — i.e. at least one active
    /// (non-completed, non-`nil`-status) task. `false` for a project whose tasks
    /// are all completed or have unrecognized statuses. Drives the browser's
    /// browser's `.active` project view mode (#072); mirrors the "No outstanding
    /// plans" terminology shown on an empty `ProjectCard`.
    var hasOutstandingWork: Bool { !activeTasks.isEmpty }

    /// The currently checked-out git branch name for the project (#024), or
    /// `nil` when the project is not a git repo / git is unavailable / the
    /// command failed. The UI renders the whole git indicator only when this is
    /// non-`nil`. Populated asynchronously by `PlansStore.reload()` off the main
    /// actor (parsing leaves it `nil`).
    let gitBranch: String?

    /// Whether the project's working tree has uncommitted changes (#024).
    /// `true` = dirty, `false` = known-clean (no dirty dot shown), `nil` =
    /// unknown (not a repo / git unavailable / command failed — also no dot).
    /// The dirty dot renders ONLY when this is exactly `true`. Populated
    /// asynchronously by `PlansStore.reload()` off the main actor.
    let gitIsDirty: Bool?

    /// Memberwise initializer with `gitBranch` / `gitIsDirty` defaulting to
    /// `nil`. The explicit init exists so the parser and tests that omit the
    /// git fields continue to compile unchanged after #024 added them; the
    /// store reconstructs `ProjectTasks` with the git values supplied.
    init(
        projectPath: String,
        projectName: String,
        lastSeen: String,
        tasks: [Task],
        counts: [TaskStatus: Int],
        activeTasks: [Task],
        backloggedTasks: [Task] = [],
        gitBranch: String? = nil,
        gitIsDirty: Bool? = nil
    ) {
        self.projectPath = projectPath
        self.projectName = projectName
        self.lastSeen = lastSeen
        self.tasks = tasks
        self.counts = counts
        self.activeTasks = activeTasks
        self.backloggedTasks = backloggedTasks
        self.gitBranch = gitBranch
        self.gitIsDirty = gitIsDirty
    }
}

/// A cheap, comparable fingerprint of a project's `.plans/` state (#066).
///
/// The reload path re-parses a project ONLY when its signature differs from the
/// signature captured on the previous tick; when the signature is unchanged, the
/// previous `ProjectTasks` is reused verbatim. This collapses the idle cost of a
/// poll tick from "list + read + markdown-parse every task file in every
/// project" down to "one directory listing per project, with mtime/size
/// prefetched in the same syscall batch".
///
/// ## What the signature covers, and why
///
/// The signature is built from BOTH `.plans/pending/` and `.plans/completed/`
/// and, for each `.md` file in them, the tuple:
///
///   `(relative path, content-modification date, file size)`
///
/// - **Path set** catches files being ADDED, REMOVED, RENAMED, and MOVED between
///   `pending/` and `completed/` (what plans-cc `plan-complete` does).
/// - **Size** catches the overwhelmingly common in-place content edit, where a
///   task file's body grows or shrinks (a checkbox ticked, a section appended).
/// - **Modification date** catches an in-place edit that happens to preserve the
///   byte count exactly (e.g. `pending` → `elabora`-length swaps, or a single
///   character flipped).
///
/// Deliberately NOT used: the containing DIRECTORY's own mtime. A directory's
/// mtime changes when its entry list changes but NOT when an existing file's
/// contents are rewritten in place, so gating on it alone would silently stop
/// surfacing edits to existing tasks — a far worse bug than the energy cost this
/// change exists to fix.
///
/// ## Known failure mode
///
/// A same-size rewrite that ALSO lands within the filesystem's mtime resolution
/// of the previous write would be missed for one tick. On APFS, `mtime` has
/// nanosecond resolution, so this requires two writes in the same nanosecond —
/// not reachable in practice. Any real editor / `plan-*` script write stamps a
/// fresh mtime. The signature also self-heals: the NEXT genuine change re-parses
/// the whole project, so no state can be permanently stale.
///
/// Content hashing was rejected: it would require reading every file's bytes
/// each tick, which is most of the cost being eliminated.
struct ProjectSignature: Equatable {
    /// One entry per `.md` file, in a deterministic (sorted) order:
    /// `(relative path, modification-date epoch seconds, size in bytes)`.
    /// `Equatable` compares these element-wise, so any add/remove/rename/edit
    /// shows up as an inequality.
    let entries: [Entry]

    /// A single file's fingerprint within a `ProjectSignature`.
    struct Entry: Equatable {
        /// `"pending/001-foo.md"` — the directory plus filename, so a move
        /// between `pending/` and `completed/` registers as a change.
        let relativePath: String
        /// The file's content-modification time as a `TimeInterval` since the
        /// reference date, or `nil` when unavailable.
        let modified: TimeInterval?
        /// The file's size in bytes, or `nil` when unavailable.
        let size: Int?
    }
}

/// Parses plans-cc task files (Data Contract 2, §5), mirroring the behavior of
/// the plans-cc `lib/parse-tasks.js` reference implementation. Parsing is
/// tolerant throughout: missing fields, missing sections, and malformed input
/// yield empty/`nil` values rather than throwing.
///
/// Single-file parsing (filename + text → `Task`) plus project-level assembly
/// (directory listing of `pending/`/`completed/`, blocked-by resolution against
/// the set of `completed/` ids, per-status counts, and the active-task sort).
///
/// The `FileManager` is injectable so tests can point `parseProject` at fixtures
/// rather than the real filesystem, mirroring `RegistryReader`. This struct only
/// ever READS from disk (directory listings and file contents) — it never
/// writes, creates, moves, or deletes (§2).
struct TaskParser {
    let fileManager: FileManager

    /// Defaults to the real filesystem. Inject a custom `fileManager` in tests.
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Change detection (#066)

    /// Computes the cheap change-detection fingerprint for the project rooted at
    /// `projectPath` — see `ProjectSignature` for the full rationale on what it
    /// covers and its one (unreachable-in-practice) failure mode.
    ///
    /// Cost is one `contentsOfDirectory` call per `.plans` subdirectory, with
    /// `.contentModificationDateKey` / `.fileSizeKey` PREFETCHED in that same
    /// call so the per-file attribute reads are served from the batched
    /// enumeration rather than costing an extra `stat` round-trip each.
    ///
    /// Tolerant like every other parser path: a missing `.plans/`, a missing
    /// subdirectory, or an unreadable attribute yields an empty/partial
    /// signature rather than throwing. Two consecutive calls against an
    /// unchanged tree are always equal.
    func projectSignature(at projectPath: String) -> ProjectSignature {
        let plansDir = URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".plans")

        var entries: [ProjectSignature.Entry] = []
        // Every directory `parseProject` enumerates, in the same order, so the
        // resulting entry list is deterministic. `backlog` is included (#077) so
        // a backlog/restore file move changes the signature and triggers a
        // reload.
        for subdir in ["pending", "completed", "backlog"] {
            entries.append(
                contentsOf: signatureEntries(
                    in: plansDir.appendingPathComponent(subdir),
                    subdir: subdir
                )
            )
        }
        return ProjectSignature(entries: entries)
    }

    /// Builds the signature entries for one `.plans` subdirectory. Returns an
    /// empty array when the directory is missing (tolerant, never throws).
    private func signatureEntries(
        in directory: URL,
        subdir: String
    ) -> [ProjectSignature.Entry] {
        // Prefetching the two keys we need means the values come back with the
        // batched directory enumeration instead of one `stat` per file.
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )) ?? []

        return urls
            .filter { $0.pathExtension == "md" }
            // Sorted so the entry order is stable across ticks regardless of the
            // order the filesystem hands entries back in.
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                )
                return ProjectSignature.Entry(
                    relativePath: "\(subdir)/\(url.lastPathComponent)",
                    modified: values?.contentModificationDate?.timeIntervalSinceReferenceDate,
                    size: values?.fileSize
                )
            }
    }

    // MARK: - Project-level assembly

    /// Parses all tasks for a project rooted at `projectPath`, reading
    /// `<projectPath>/.plans/pending/` and `<projectPath>/.plans/completed/`
    /// (Data Contract 2, §5.5).
    ///
    /// Tolerance: either directory may be missing or empty — that simply yields
    /// no tasks for that directory, never a crash (mirrors plans-cc
    /// `lib/parse-tasks.js`). Files under `completed/` have their `status`
    /// forced to `.completed` (the directory is authoritative, §5.4).
    ///
    /// Blocked resolution: the set of ids found under `completed/` is built
    /// first, then each task's `isBlocked` is computed — `true` when ANY id in
    /// its `**Blocked by:**` list is NOT present among the completed ids
    /// (§5.5 step 5).
    ///
    /// `lastSeen` is the registry staleness signal carried through verbatim
    /// (defaulting to `""` so call sites/tests that omit it still compile). It is
    /// stored raw on `ProjectTasks`; the ISO→`Date` parse happens at sort time in
    /// the browser view model, keeping this parser Foundation-only.
    func parseProject(at projectPath: String, lastSeen: String = "") -> ProjectTasks {
        let plansDir = URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".plans")
        let pendingDir = plansDir.appendingPathComponent("pending")
        let completedDir = plansDir.appendingPathComponent("completed")
        let backlogDir = plansDir.appendingPathComponent("backlog")

        // Parse each directory's `.md` files. The completed-ids set is derived
        // from the completed files so blocked-by can be resolved (§5.5 step 5).
        let completedTasks = parseTaskFiles(in: completedDir, isCompletedDir: true)
        let completedIds = Set(completedTasks.map(\.id))

        let pendingParsed = parseTaskFiles(in: pendingDir, isCompletedDir: false)

        // Resolve isBlocked for pending tasks against the completed-ids set. A
        // task is blocked if any dependency id is not yet completed. Completed
        // tasks are never blocked (they are done).
        let pendingTasks = pendingParsed.map { resolveBlocked($0, completedIds: completedIds) }

        let tasks = pendingTasks + completedTasks

        // §5.5 step 7: per-status counts. `nil`-status tasks count for nothing.
        var counts: [TaskStatus: Int] = [:]
        for task in tasks {
            if let status = task.status {
                counts[status, default: 0] += 1
            }
        }

        // §5.5 step 8: active tasks (the five non-completed statuses), sorted by
        // status priority then id ascending.
        let activeTasks = tasks
            .filter { task in
                guard let status = task.status else { return false }
                return status != .completed
            }
            .sorted { lhs, rhs in
                let lp = lhs.status?.activePriority ?? 0
                let rp = rhs.status?.activePriority ?? 0
                if lp != rp { return lp > rp }
                return lhs.id < rhs.id
            }

        // #077: backlogged tasks (files under `backlog/`) are kept SEPARATE —
        // never added to `tasks`, `counts`, or `activeTasks`. `isBlocked` is
        // resolved against the SAME completed-ids set as pending tasks. Backlog
        // keeps each task's real `**Status:**` (no status is forced). Sorted like
        // `activeTasks`: status priority descending, then id ascending.
        let backloggedParsed = parseTaskFiles(
            in: backlogDir,
            isCompletedDir: false,
            isBacklogged: true
        )
        let backloggedTasks = backloggedParsed
            .map { resolveBlocked($0, completedIds: completedIds) }
            .sorted { lhs, rhs in
                let lp = lhs.status?.activePriority ?? 0
                let rp = rhs.status?.activePriority ?? 0
                if lp != rp { return lp > rp }
                return lhs.id < rhs.id
            }

        let projectName = URL(fileURLWithPath: projectPath).lastPathComponent.titleized()

        return ProjectTasks(
            projectPath: projectPath,
            projectName: projectName,
            lastSeen: lastSeen,
            tasks: tasks,
            counts: counts,
            activeTasks: activeTasks,
            backloggedTasks: backloggedTasks
        )
    }

    /// Lists the `*.md` files in `directory` (non-recursively, sorted by
    /// filename for deterministic order) and parses each into a `Task`. Returns
    /// an empty array when the directory is missing or empty — tolerant, never
    /// throws (§5.5 step 1). `isCompletedDir` is threaded into single-file
    /// parsing so `completed/` files are forced to `.completed` (§5.4).
    private func parseTaskFiles(
        in directory: URL,
        isCompletedDir: Bool,
        isBacklogged: Bool = false
    ) -> [Task] {
        // contentsOfDirectory throws when the directory is missing; tolerate it.
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        let mdFiles = entries
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return mdFiles.compactMap { url -> Task? in
            // Reading the file may fail (e.g. it was removed between listing and
            // reading); tolerate by skipping that file rather than crashing.
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return nil
            }
            return parse(
                filename: url.lastPathComponent,
                text: text,
                isCompletedDir: isCompletedDir,
                isBacklogged: isBacklogged
            )
        }
    }

    /// Returns a copy of `task` with `isBlocked` resolved against `completedIds`.
    /// Blocked when ANY id in `task.blockedBy` is absent from the completed set
    /// (§5.5 step 5). Because `Task` fields are `let`, the value is rebuilt.
    private func resolveBlocked(_ task: Task, completedIds: Set<String>) -> Task {
        let isBlocked = task.blockedBy.contains { !completedIds.contains($0) }
        return Task(
            id: task.id,
            title: task.title,
            type: task.type,
            status: task.status,
            created: task.created,
            branch: task.branch,
            isKeptWorktree: task.isKeptWorktree,
            blockedBy: task.blockedBy,
            sections: task.sections,
            howProgress: task.howProgress,
            isBlocked: isBlocked,
            isCompletedDir: task.isCompletedDir,
            isBacklogged: task.isBacklogged,
            failure: task.failure
        )
    }

    // MARK: - Single-file parsing

    /// Parses one task file into a `Task`.
    ///
    /// - Parameters:
    ///   - filename: The file's name (e.g. `006-system-wide-dashboard.md`); the
    ///     id is the literal first 3 characters (§5.2).
    ///   - text: The full file contents.
    ///   - isCompletedDir: `true` when the file lives under `completed/`, which
    ///     forces `status` to `.completed` regardless of the `**Status:**` line
    ///     (the directory is authoritative, §5.4).
    ///   - isBacklogged: `true` when the file lives under `backlog/` (#077).
    ///     Recorded on the `Task` but does NOT affect `status` — backlogged
    ///     files keep their real `**Status:**`.
    func parse(
        filename: String,
        text: String,
        isCompletedDir: Bool,
        isBacklogged: Bool = false
    ) -> Task {
        // §5.2: the id is literally the first 3 characters of the filename. If
        // the filename is shorter than 3 characters, take what is there.
        let id = String(filename.prefix(3))

        // Split into lines once; reused by every sub-parse. Splitting on "\n"
        // and keeping empty subsequences preserves blank lines in section bodies.
        let lines = text.components(separatedBy: "\n")

        let title = Self.parseTitle(lines: lines)

        // Bold frontmatter (§5.3), each anchored to the start of a line.
        let createdRaw = Self.frontmatterValue(field: "Created", lines: lines)
        let typeRaw = Self.frontmatterValue(field: "Type", lines: lines)
        let statusRaw = Self.frontmatterValue(field: "Status", lines: lines)
        let branchRaw = Self.frontmatterValue(field: "Branch", lines: lines)
        let worktreeRaw = Self.frontmatterValue(field: "Worktree", lines: lines)
        let blockedByRaw = Self.frontmatterValue(field: "Blocked by", lines: lines)

        let type = TaskType(rawValueTolerant: typeRaw)

        // §5.4: the containing directory is authoritative for completion. A file
        // under completed/ is `.completed` no matter what its `**Status:**` says.
        let status: TaskStatus? = isCompletedDir
            ? .completed
            : TaskStatus(rawValueTolerant: statusRaw)

        // A live worktree marker: the field is present and non-empty. A
        // stripped/blank `**Worktree:**` (value trimmed to "") is NOT kept.
        // (`frontmatterValue` already returns the trimmed value.)
        let isKeptWorktree = !(worktreeRaw ?? "").isEmpty

        let blockedBy = Self.parseBlockedBy(blockedByRaw)

        let sections = Self.parseSections(lines: lines)
        let howProgress = Self.howProgress(sections: sections)

        return Task(
            id: id,
            title: title,
            type: type,
            status: status,
            created: createdRaw,
            branch: branchRaw,
            isKeptWorktree: isKeptWorktree,
            blockedBy: blockedBy,
            sections: sections,
            howProgress: howProgress,
            // Resolved at the project level in segment 2; false at single-file
            // scope (we don't yet know the set of completed/ ids).
            isBlocked: false,
            isCompletedDir: isCompletedDir,
            isBacklogged: isBacklogged
        )
    }

    // MARK: - Title

    /// Returns the title — the text after the first line beginning with `# `
    /// (a single `# ` then a space), trimmed (§5.3). A `## ` line is NOT a title
    /// because it does not start with `# ` followed by a non-`#` (`"## "` starts
    /// with `"# "`? no — it starts with `"#"` then `"#"`). We require the second
    /// character to be a space. Returns `nil` when no such line exists.
    private static func parseTitle(lines: [String]) -> String? {
        for line in lines where line.hasPrefix("# ") {
            let title = String(line.dropFirst(2))
                .trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        return nil
    }

    // MARK: - Frontmatter

    /// Returns the value of a bold frontmatter field (e.g. `Status`), matched by
    /// a per-line pattern anchored to line start: `^\*\*Field:\*\*\s*(.*)$`
    /// (§5.3). The returned value is trimmed of trailing whitespace; leading
    /// whitespace after the field marker is already consumed by `\s*`. Returns
    /// `nil` when no line matches.
    private static func frontmatterValue(field: String, lines: [String]) -> String? {
        let prefix = "**\(field):**"
        for line in lines where line.hasPrefix(prefix) {
            let rest = String(line.dropFirst(prefix.count))
            // Consume the `\s*` after the marker and any trailing whitespace.
            return rest.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Parses a `**Blocked by:**` raw value into 3-digit ids. The list is split
    /// on whitespace and commas (§5.5 step 5); empty/whitespace tokens are
    /// dropped. Returns an empty array when `raw` is `nil` or yields nothing.
    private static func parseBlockedBy(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ","))
        return raw
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
    }

    // MARK: - Sections

    /// Splits the file into `## ` sections (§5.3). A section runs from its
    /// `## Heading` line until the next `## ` line or end of file; the body is
    /// the verbatim text between those bounds (heading line excluded). Lines
    /// before the first `## ` (title, frontmatter) are not part of any section.
    private static func parseSections(lines: [String]) -> [TaskSection] {
        var sections: [TaskSection] = []
        var currentHeading: String?
        var currentBody: [String] = []

        func flush() {
            guard let heading = currentHeading else { return }
            // Join with "\n" to reconstruct the verbatim body. We do not trim the
            // body so it round-trips for markdown rendering, but we drop a single
            // trailing empty line that is an artifact of the heading-to-heading
            // split is avoided by joining the captured lines exactly as seen.
            let body = currentBody.joined(separator: "\n")
            sections.append(TaskSection(heading: heading, body: body))
        }

        for line in lines {
            if line.hasPrefix("## ") {
                // Starting a new section: flush the previous one first.
                flush()
                currentHeading = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                currentBody = []
            } else if currentHeading != nil {
                currentBody.append(line)
            }
        }
        flush()

        return sections
    }

    // MARK: - How-progress

    /// Counts checkbox progress within the `## How` section only (§5.3.1).
    /// Lines matching `- [ ]` are incomplete; `- [x]` / `- [X]` are complete.
    /// Returns `(done: 0, total: 0)` when there is no How section or it has no
    /// checkboxes — no-progress, NOT complete. Checkboxes in other sections are
    /// never counted (this scans only the How section's body).
    private static func howProgress(sections: [TaskSection]) -> (done: Int, total: Int) {
        guard let how = sections.first(where: { $0.heading == "How" }) else {
            return (done: 0, total: 0)
        }

        var done = 0
        var total = 0
        for rawLine in how.body.components(separatedBy: "\n") {
            // Ignore leading whitespace so indented checkboxes still count.
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- [ ]") {
                total += 1
            } else if line.hasPrefix("- [x]") || line.hasPrefix("- [X]") {
                total += 1
                done += 1
            }
        }
        return (done: done, total: total)
    }
}
