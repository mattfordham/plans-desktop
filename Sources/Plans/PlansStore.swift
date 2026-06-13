import Foundation
import Observation

/// The shared, observable application store. Holds the live projects (with their
/// parsed tasks and per-status counts) plus the current drill-down selection.
///
/// `reload()` drives the read path verbatim: `RegistryReader.readProjects()` →
/// `TaskParser.parseProject(at:)` for each live project. No new parsing happens
/// here — this type only orchestrates the existing, already-tested readers.
///
/// Seams for later segments:
/// - `selectedProjectPath` is the drill-down handoff that #005 reads.
/// - `reload()` is driven reactively by `startPolling()` (task #006), which
///   re-runs the read path on a repeating main-thread timer.
///
/// The readers are injected (defaulting to `RegistryReader()` / `TaskParser()`)
/// so `reload()` is unit-testable against temp-dir fixtures.
@Observable
final class PlansStore {
    /// The live projects with their parsed tasks and counts, in registry order.
    private(set) var projects: [ProjectTasks] = []

    /// The path of the project the user has drilled into, or `nil` for none.
    /// This is the Surface A → Surface B handoff seam read by task #005.
    var selectedProjectPath: String?

    /// The user's manual card order as an ordered list of project paths (#017).
    /// Drives the browser grid order when `manualOrderActive` is true; project
    /// paths absent from this list are treated as new and sort to the TOP (see
    /// `BrowserViewModel.applyManualOrder`). Persisted to `defaults` on every set
    /// so the override survives app restarts. NEVER written to `.plans/` (§2
    /// read-only) — UserDefaults is the only persistence sink.
    var projectOrderOverride: [String] = [] {
        didSet { defaults.set(projectOrderOverride, forKey: Self.orderKey) }
    }

    /// Whether the manual card order (`projectOrderOverride`) is active. When
    /// false the browser falls back to the automatic recency sort. Persisted on
    /// every set; the revert toggle (#017 step 4) flips this off.
    var manualOrderActive: Bool = false {
        didSet { defaults.set(manualOrderActive, forKey: Self.activeKey) }
    }

    /// Whether the browser hides projects with no outstanding plans (#021). When
    /// true, `BrowserWindow.sortedProjects` filters out projects whose
    /// `hasOutstandingWork` is false; when false every project is shown. Persisted
    /// on every set so the preference survives app restarts. NEVER written to
    /// `.plans/` (§2 read-only) — UserDefaults is the only persistence sink.
    var hideEmptyProjects: Bool = false {
        didSet { defaults.set(hideEmptyProjects, forKey: Self.hideEmptyKey) }
    }

    /// A persisted, unsubmitted plan-capture draft for one project (#031). Holds
    /// the in-flight description text plus the two run toggles so the "New Plan"
    /// sheet can restore exactly what the user was typing if it is dismissed and
    /// reopened (or the app is relaunched) before submitting. Pure value state —
    /// NEVER written to `.plans/` (§2 read-only); UserDefaults is the only sink.
    struct CaptureDraft: Codable, Equatable {
        /// The in-flight plan description text.
        var text: String
        /// Whether the "Execute" toggle is on (run autonomously in a worktree).
        var execute: Bool
        /// Whether the "Elaborate" toggle is on (flesh the plan out after capture).
        var elaborate: Bool
        /// The PNG bytes of an image pasted/dropped into the form (#048), or nil
        /// when no image is staged. Held alongside the text so a dismissed-and-
        /// reopened sheet (or an app relaunch) restores the staged image too.
        /// NEVER written to `.plans/` (§2 read-only); the only persistence sink is
        /// UserDefaults (this whole draft is JSON-encoded there). The image bytes
        /// are written to disk under Application Support — outside `.plans/` — only
        /// at submit time by `CaptureImageStore`.
        var imageData: Data?

        /// Memberwise init (explicit so the type can be constructed across the
        /// module without relying on the synthesized internal initializer).
        /// `imageData` defaults to nil so existing call sites and decoding of
        /// older drafts (saved before #048, with no `imageData` key) still work —
        /// the synthesized `Codable` decodes an absent `Data?` key as nil.
        init(text: String, execute: Bool, elaborate: Bool, imageData: Data? = nil) {
            self.text = text
            self.execute = execute
            self.elaborate = elaborate
            self.imageData = imageData
        }
    }

    /// Per-project unsubmitted capture drafts, keyed by project path (#031). The
    /// "New Plan" sheet reads/writes these so an in-progress description and its
    /// toggles survive dismissal and app relaunch. Persisted on every set by
    /// JSON-encoding the whole dictionary to `captureDraftsKey` in `defaults`
    /// (the encoded `Data`). NEVER written to `.plans/` (§2 read-only) —
    /// UserDefaults is the only persistence sink. Mutate via `setDraft`/
    /// `clearDraft`; read via `draft(for:)`.
    var captureDrafts: [String: CaptureDraft] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(captureDrafts) {
                defaults.set(data, forKey: Self.captureDraftsKey)
            }
        }
    }

    /// The set of "starred" project paths the user has pinned to keep visible
    /// (#035), keyed by `ProjectTasks.projectPath`. A starred project's card
    /// stays in the dashboard even when it has no outstanding work and the
    /// "Hide Empty" filter is on (see `BrowserWindow.sortedProjects`). Persisted
    /// on every set by writing `Array(starredProjectPaths)` to
    /// `starredProjectsKey` in `defaults` (UserDefaults stores arrays, not Sets).
    /// NEVER written to `.plans/` (§2 read-only) — UserDefaults is the only sink.
    var starredProjectPaths: Set<String> = [] {
        didSet { defaults.set(Array(starredProjectPaths), forKey: Self.starredProjectsKey) }
    }

    /// A non-persisted "open the New Plan form" trigger (#034). Bridges the
    /// scene-level ⌘N menu command (in `PlansApp`) to `BrowserWindow`'s sheet
    /// state: the menu command can't reach the window's `@State`, so it bumps
    /// this observable counter and `BrowserWindow` observes it via `.onChange`,
    /// opening the same modal the toolbar button does. Pure in-memory UI state —
    /// deliberately NOT UserDefaults-backed (no `didSet`, never loaded in `init`),
    /// since "open a form" is a transient action, not persisted preference.
    var newPlanTrigger: Int = 0

    /// Requests that the New Plan form open (#034). Increments `newPlanTrigger`
    /// (overflow-safe) so any observer reacts to the change even on repeated
    /// invocations. Invoked by the app-wide ⌘N command in `PlansApp`.
    func requestNewPlan() {
        newPlanTrigger &+= 1
    }

    /// UserDefaults key for the persisted per-project capture drafts (#031). The
    /// stored value is the JSON-encoded `[String: CaptureDraft]` as `Data`.
    private static let captureDraftsKey = "captureDrafts"

    /// The card-grid layout mode for the browser dashboard (#033): `.scroll` (the
    /// default responsive scrolling grid) or `.fit` (a near-square grid sized to
    /// fit every card on screen). Persisted on every set (its `rawValue` is the
    /// wire form) so the choice survives app restarts. NEVER written to `.plans/`
    /// (§2 read-only) — UserDefaults is the only persistence sink.
    var cardLayoutMode: CardLayoutMode = .scroll {
        didSet { defaults.set(cardLayoutMode.rawValue, forKey: Self.cardLayoutKey) }
    }

    /// UserDefaults key for the persisted manual card order (array of paths).
    private static let orderKey = "cardOrderOverride"

    /// UserDefaults key for the persisted manual-order-active flag.
    private static let activeKey = "cardOrderManualActive"

    /// UserDefaults key for the persisted hide-empty-projects flag (#021).
    private static let hideEmptyKey = "hideEmptyProjects"

    /// UserDefaults key for the persisted card layout mode (#033).
    private static let cardLayoutKey = "cardLayoutMode"

    /// UserDefaults key for the persisted starred project paths (#035). The
    /// stored value is `Array(starredProjectPaths)` (UserDefaults stores arrays).
    private static let starredProjectsKey = "starredProjects"

    /// The statuses surfaced in the menu bar icon space, in a fresh order that
    /// leads with actively-running work: in-progress → review → in-review. This
    /// is INTENTIONALLY distinct from `TaskStatus.glanceOrder` (the TUI
    /// dashboard order used by the drop-down rows) and is local to the icon
    /// space, where the goal is at-a-glance awareness of work in motion.
    private static let iconSpaceOrder: [TaskStatus] = [
        .inProgress, .review, .inReview,
    ]

    /// The per-status totals shown in the menu bar icon label, aggregated across
    /// every live project. Only the three `iconSpaceOrder` statuses are
    /// considered, in that order; any whose total across all projects is 0 is
    /// omitted (so an empty array means "nothing in motion" and the label falls
    /// back to the bare icon). Reuses each `project.counts[status]` verbatim —
    /// no new parsing happens here.
    var iconSpaceCounts: [(status: TaskStatus, count: Int)] {
        Self.iconSpaceOrder.compactMap { status in
            let total = projects.reduce(0) { sum, project in
                sum + (project.counts[status] ?? 0)
            }
            guard total > 0 else { return nil }
            return (status, total)
        }
    }

    /// The registry reader used by `reload()` to discover live projects.
    @ObservationIgnored private let registryReader: RegistryReader

    /// The registry writer used by `linkProject(at:)` to persist a manually
    /// linked project into `projects.json`.
    @ObservationIgnored private let registryWriter: RegistryWriter

    /// The task parser used by `reload()` to parse each project's `.plans/`.
    @ObservationIgnored private let taskParser: TaskParser

    /// The UserDefaults instance backing the persisted manual-order state (#017).
    /// Injected (defaulting to `.standard`) so tests can pass an isolated suite.
    @ObservationIgnored private let defaults: UserDefaults

    /// The repeating timer that drives live refresh, or `nil` when not polling.
    /// `@ObservationIgnored` because the timer itself is not observable UI state.
    @ObservationIgnored private var pollTimer: Timer?

    /// Defaults to the real readers/writer and `.standard` UserDefaults. Inject
    /// fixtures-backed readers/writer (all pointed at the same temp registry URL)
    /// and an isolated `UserDefaults(suiteName:)` in tests. The persisted
    /// manual-order state (#017) is loaded eagerly here so the override is in
    /// effect before the first grid layout.
    init(
        registryReader: RegistryReader = RegistryReader(),
        registryWriter: RegistryWriter = RegistryWriter(),
        taskParser: TaskParser = TaskParser(),
        defaults: UserDefaults = .standard
    ) {
        self.registryReader = registryReader
        self.registryWriter = registryWriter
        self.taskParser = taskParser
        self.defaults = defaults
        // Load persisted manual-order state. Assigning the backing fields avoids
        // re-persisting (the `didSet` would write the just-read value back).
        _projectOrderOverride = defaults.stringArray(forKey: Self.orderKey) ?? []
        _manualOrderActive = defaults.bool(forKey: Self.activeKey)
        _hideEmptyProjects = defaults.bool(forKey: Self.hideEmptyKey)
        _cardLayoutMode = CardLayoutMode(rawValue: defaults.string(forKey: Self.cardLayoutKey) ?? "") ?? .scroll
        // Load persisted starred project paths (#035): the stored array round-trips
        // back into the `Set`. Assigning the backing field avoids the `didSet`
        // re-persisting the just-read value.
        _starredProjectPaths = Set(defaults.stringArray(forKey: Self.starredProjectsKey) ?? [])
        // Load persisted capture drafts (#031): decode the stored JSON `Data`,
        // defaulting to an empty map on missing/corrupt data. Assigning the
        // backing field avoids the `didSet` re-persisting the just-read value.
        if let data = defaults.data(forKey: Self.captureDraftsKey),
           let decoded = try? JSONDecoder().decode([String: CaptureDraft].self, from: data) {
            _captureDrafts = decoded
        } else {
            _captureDrafts = [:]
        }
    }

    /// Returns the saved capture draft for `projectPath`, or `nil` when none has
    /// been persisted (#031). Pure read of the in-memory `captureDrafts` map.
    func draft(for projectPath: String) -> CaptureDraft? {
        captureDrafts[projectPath]
    }

    /// Stores `draft` as the capture draft for `projectPath` (#031), replacing
    /// any prior draft. Triggers persistence via the `captureDrafts` setter.
    /// Never writes `.plans/` (§2) — UserDefaults is the only sink.
    func setDraft(_ draft: CaptureDraft, for projectPath: String) {
        captureDrafts[projectPath] = draft
    }

    /// Removes the saved capture draft for `projectPath` (#031), if any. Called
    /// after a successful submit or an explicit "Clear". Triggers persistence
    /// via the `captureDrafts` setter; never writes `.plans/` (§2).
    func clearDraft(for projectPath: String) {
        captureDrafts.removeValue(forKey: projectPath)
    }

    /// Activates the manual card order and replaces it with `paths` (the new
    /// ordered list of project paths), persisting both in one shot. Called by the
    /// browser after a drag-drop resolves a new ordering. Pure mutate+persist —
    /// never touches `.plans/` (§2 read-only).
    func setManualOrder(_ paths: [String]) {
        manualOrderActive = true
        projectOrderOverride = paths
    }

    /// Reverts to the automatic recency sort by turning the manual order OFF. The
    /// saved `projectOrderOverride` is intentionally retained so re-enabling
    /// (a future feature) could restore it; only the active flag flips. Persisted
    /// via the `manualOrderActive` setter.
    func clearManualOrder() {
        manualOrderActive = false
    }

    /// Errors surfaced by `linkProject(at:)` so the UI can present a message.
    enum LinkError: Error, Equatable {
        /// The chosen directory has no `.plans/` subdirectory, so it is not a
        /// plans-cc project and must not be added to the registry.
        case missingPlansDirectory
    }

    /// Manually links the project at `path` into the registry: validates that
    /// `<path>/.plans/` exists (throwing `LinkError.missingPlansDirectory`
    /// otherwise — and writing nothing in that case), upserts the path via
    /// `RegistryWriter`, then `reload()`s so the linked project appears
    /// immediately. `path` is used verbatim, matching `RegistryReader`'s
    /// no-canonicalization contract.
    func linkProject(at path: String) throws {
        let plansPath = URL(fileURLWithPath: path)
            .appendingPathComponent(".plans")
            .path
        guard FileManager.default.fileExists(atPath: plansPath) else {
            throw LinkError.missingPlansDirectory
        }

        try registryWriter.upsertProject(path: path)
        reload()
    }

    /// Re-reads the registry and re-parses every live project, replacing
    /// `projects`. Reuses the existing readers verbatim — no new parsing. Never
    /// throws: the underlying readers are tolerant (missing/corrupt registry or
    /// `.plans/` directories yield empty results rather than crashing).
    func reload() {
        // Snapshot the previously-known git info per path so the re-parse below
        // can carry it over. The parser constructs `ProjectTasks` with `nil` git
        // fields; without this carry-over, every 5s poll would momentarily reset
        // each card's git row to `nil` (hiding the branch + dirty dot) until the
        // async second pass repopulates it — a visible flash on every poll (#024).
        let priorGitInfo = Dictionary(
            projects.map { ($0.projectPath, ($0.gitBranch, $0.gitIsDirty)) },
            uniquingKeysWith: { first, _ in first }
        )

        projects = registryReader.readProjects().map { project in
            let parsed = taskParser.parseProject(at: project.path, lastSeen: project.lastSeen)
            guard let prior = priorGitInfo[project.path] else { return parsed }
            return ProjectTasks(
                projectPath: parsed.projectPath,
                projectName: parsed.projectName,
                lastSeen: parsed.lastSeen,
                tasks: parsed.tasks,
                counts: parsed.counts,
                activeTasks: parsed.activeTasks,
                gitBranch: prior.0,
                gitIsDirty: prior.1
            )
        }

        // Second pass (#024): gather live git state OFF the main thread so the
        // blocking `git` subprocesses never stall the UI, then merge it back on
        // the main thread. `GitHelper` methods are `nonisolated`/blocking; we
        // collect plain Sendable tuples on a background queue and apply them on
        // the main queue. The first (synchronous) pass above already painted the
        // cards carrying over the last-known git fields, so this only refreshes
        // them with live values.
        //
        // GCD (not structured concurrency) is used deliberately: `PlansStore` is
        // a non-`Sendable`, main-thread-only reference type, and GCD lets us hop
        // background→main without crossing a Swift-concurrency Sendability
        // boundary on `self`. The captured `paths` are value-type Strings.
        //
        // `self` is captured `nonisolated(unsafe)`: `PlansStore` is not
        // `Sendable`, but it is only ever touched on the main thread, and the
        // only `self` access in these closures is `applyGitInfo`, which we
        // re-dispatch onto the main queue. The unsafe annotation documents that
        // invariant and keeps the `@Sendable` GCD closures warning-clean. The
        // capture is strong — the store is app-lifetime (same rationale as the
        // poll timer above) so there is no meaningful retain cycle to break.
        let paths = projects.map(\.projectPath)
        nonisolated(unsafe) let unsafeSelf = self
        DispatchQueue.global(qos: .utility).async {
            var results: [GitResult] = []
            for path in paths {
                let branch = GitHelper.currentBranch(at: path)
                let dirty = GitHelper.isDirty(at: path)
                results.append(GitResult(path: path, branch: branch, dirty: dirty))
            }
            DispatchQueue.main.async {
                unsafeSelf.applyGitInfo(results)
            }
        }
    }

    /// A Sendable carrier for one project's git query results, used to ferry the
    /// `GitHelper` output from the background queue back to the main queue (#024).
    private struct GitResult: Sendable {
        let path: String
        let branch: String?
        let dirty: Bool?
    }

    /// Merges the background-gathered git results into `projects` (#024). MUST be
    /// called on the main thread (it mutates the observable `projects` that
    /// SwiftUI reads). For each result, finds the matching project BY PATH and
    /// rebuilds that element (structs are value types) carrying over all existing
    /// fields plus the git values. Projects that disappeared between the parse
    /// pass and this merge are simply skipped.
    private func applyGitInfo(_ results: [GitResult]) {
        for result in results {
            guard let index = projects.firstIndex(where: { $0.projectPath == result.path }) else {
                continue
            }
            let existing = projects[index]
            projects[index] = ProjectTasks(
                projectPath: existing.projectPath,
                projectName: existing.projectName,
                lastSeen: existing.lastSeen,
                tasks: existing.tasks,
                counts: existing.counts,
                activeTasks: existing.activeTasks,
                gitBranch: result.branch,
                gitIsDirty: result.dirty
            )
        }
    }

    /// Begins live refresh: performs an immediate `reload()` (preserving the
    /// one-shot launch semantics — `projects` is populated synchronously before
    /// this returns) and then schedules a repeating main-run-loop `Timer` that
    /// calls `reload()` every `interval` seconds. Any existing timer is
    /// invalidated first, so calling this repeatedly is safe.
    func startPolling(interval: TimeInterval = 5) {
        stopPolling()
        reload()
        // `self` is captured strongly: the store is app-lifetime and owns the
        // timer, so there is no meaningful retain cycle to break here.
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [self] _ in
            reload()
        }
    }

    /// Stops live refresh by invalidating and clearing the repeating timer.
    /// Safe to call when not polling (a no-op in that case).
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Test-only hook: whether a live (scheduled, non-invalidated) poll timer is
    /// currently installed. Lets tests assert `startPolling()`/`stopPolling()`
    /// lifecycle behavior without waiting on real wall-clock timer firing.
    var isPolling: Bool {
        pollTimer?.isValid ?? false
    }
}
