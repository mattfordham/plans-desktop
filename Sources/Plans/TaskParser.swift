import Foundation

/// The status of a task, drawn from the exact §5.4 vocabulary. The raw values
/// match the strings that appear after `**Status:**` in a task file. Decoding is
/// tolerant: a missing or unrecognized `**Status:**` value yields `nil` rather
/// than crashing (see `TaskStatus(rawValueTolerant:)`), mirroring plans-cc's
/// defensive parsing.
enum TaskStatus: String, Codable, CaseIterable {
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
enum TaskType: String, Codable, CaseIterable {
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
struct Task {
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

    /// Whether this file was found under `completed/`. Threaded in by the caller
    /// so the parser can force `status` to `.completed`.
    let isCompletedDir: Bool
}

/// A project's parsed tasks plus a per-status count summary (§5.5 step 7).
/// Assembled in segment 2; defined here so the model is complete.
struct ProjectTasks {
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

    /// Whether the project has any outstanding work — i.e. at least one active
    /// (non-completed, non-`nil`-status) task. `false` for a project whose tasks
    /// are all completed or have unrecognized statuses. Drives the browser's
    /// "Hide Empty" toolbar filter (#021); mirrors the "No outstanding plans"
    /// terminology shown on an empty `ProjectCard`.
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
        gitBranch: String? = nil,
        gitIsDirty: Bool? = nil
    ) {
        self.projectPath = projectPath
        self.projectName = projectName
        self.lastSeen = lastSeen
        self.tasks = tasks
        self.counts = counts
        self.activeTasks = activeTasks
        self.gitBranch = gitBranch
        self.gitIsDirty = gitIsDirty
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

        let projectName = URL(fileURLWithPath: projectPath).lastPathComponent.titleized()

        return ProjectTasks(
            projectPath: projectPath,
            projectName: projectName,
            lastSeen: lastSeen,
            tasks: tasks,
            counts: counts,
            activeTasks: activeTasks
        )
    }

    /// Lists the `*.md` files in `directory` (non-recursively, sorted by
    /// filename for deterministic order) and parses each into a `Task`. Returns
    /// an empty array when the directory is missing or empty — tolerant, never
    /// throws (§5.5 step 1). `isCompletedDir` is threaded into single-file
    /// parsing so `completed/` files are forced to `.completed` (§5.4).
    private func parseTaskFiles(in directory: URL, isCompletedDir: Bool) -> [Task] {
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
                isCompletedDir: isCompletedDir
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
            isCompletedDir: task.isCompletedDir
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
    func parse(filename: String, text: String, isCompletedDir: Bool) -> Task {
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
            isCompletedDir: isCompletedDir
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
