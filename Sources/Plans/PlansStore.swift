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
        /// Whether the "Deep" toggle is on (#065): draft the elaboration via a
        /// reasoning sub-agent (plans-cc `deep` mode). Orthogonal to the run mode —
        /// only meaningful when `elaborate` is on, which it modifies. Defaults to
        /// false at the property level; backward-compat for older drafts (saved
        /// before #065, with no `deep` key) is handled by the explicit
        /// `init(from:)` below via `decodeIfPresent` — Swift's SYNTHESIZED decoder
        /// does NOT consult property defaults for a non-Optional key and would
        /// otherwise throw `keyNotFound` when `deep` is absent.
        var deep: Bool = false
        /// Whether the "Keep" toggle is on (#078): preserve the run's worktree
        /// after an execute run finishes (plans-cc `--keep`), so it can be reviewed
        /// in parallel rather than being torn down. Orthogonal to the run mode —
        /// only meaningful when `execute` is on (the Keep toggle is disabled
        /// otherwise). Defaults to false at the property level; backward-compat for
        /// older drafts (saved before #078, with no `keep` key) is handled by the
        /// explicit `init(from:)` below via `decodeIfPresent` — Swift's SYNTHESIZED
        /// decoder does NOT consult property defaults for a non-Optional key and
        /// would otherwise throw `keyNotFound` when `keep` is absent.
        var keep: Bool = false
        /// The PNG bytes of the images pasted/dropped into the form (#048/#069),
        /// in staging order — empty when nothing is staged. Held alongside the
        /// text so a dismissed-and-reopened sheet (or an app relaunch) restores
        /// the staged images too. NEVER written to `.plans/` (§2 read-only); the
        /// only persistence sink is UserDefaults (this whole draft is JSON-encoded
        /// there). The image bytes are written to disk under Application Support —
        /// outside `.plans/` — only at submit time by `CaptureImageStore`.
        ///
        /// Migration (#069): a draft persisted before #069 carried a single
        /// scalar `imageData` key; `init(from:)` below wraps that legacy value
        /// into a one-element array so a pre-#069 staged image survives an app
        /// upgrade. A draft with neither key decodes to `[]`.
        var imageDatas: [Data] = []

        /// Memberwise init (explicit so the type can be constructed across the
        /// module without relying on the synthesized internal initializer).
        /// `deep` defaults to false and `imageDatas` to `[]` so existing call
        /// sites and decoding of older drafts (saved before #065 / #048, with no
        /// `deep` or image key) still work.
        init(text: String, execute: Bool, elaborate: Bool, deep: Bool = false, keep: Bool = false, imageDatas: [Data] = []) {
            self.text = text
            self.execute = execute
            self.elaborate = elaborate
            self.deep = deep
            self.keep = keep
            self.imageDatas = imageDatas
        }

        /// The coding keys for the CURRENT wire form (text/execute/elaborate/
        /// deep/imageDatas). Explicit so `encode(to:)` and the current-key decode
        /// are pinned; the legacy scalar `imageData` key is handled separately in
        /// `init(from:)` via `LegacyCodingKeys` so it never appears in the encoded
        /// output.
        private enum CodingKeys: String, CodingKey {
            case text, execute, elaborate, deep, keep, imageDatas
        }

        /// Decode-only keys for pre-#069 drafts, which carried a single scalar
        /// `imageData` instead of the `imageDatas` array. Kept out of
        /// `CodingKeys` so the synthesized-style `encode(to:)` never emits it.
        private enum LegacyCodingKeys: String, CodingKey {
            case imageData
        }

        /// Explicit `Codable` decoding so older drafts still decode cleanly:
        /// - an absent `deep` key (pre-#065) defaults to false;
        /// - `imageDatas` is taken directly when present (#069); otherwise a
        ///   legacy scalar `imageData` (pre-#069) is wrapped into a one-element
        ///   array; with neither key present it defaults to `[]` (pre-#048).
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.text = try container.decode(String.self, forKey: .text)
            self.execute = try container.decode(Bool.self, forKey: .execute)
            self.elaborate = try container.decode(Bool.self, forKey: .elaborate)
            self.deep = try container.decodeIfPresent(Bool.self, forKey: .deep) ?? false
            self.keep = try container.decodeIfPresent(Bool.self, forKey: .keep) ?? false

            if let datas = try container.decodeIfPresent([Data].self, forKey: .imageDatas) {
                self.imageDatas = datas
            } else {
                let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
                if let single = try legacy.decodeIfPresent(Data.self, forKey: .imageData) {
                    self.imageDatas = [single]
                } else {
                    self.imageDatas = []
                }
            }
        }

        /// Explicit `encode(to:)` matching `CodingKeys`. Written out (rather than
        /// synthesized) because the presence of an explicit `init(from:)` plus the
        /// decode-only `LegacyCodingKeys` means synthesis can't be relied on to
        /// emit exactly the current keys.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text, forKey: .text)
            try container.encode(execute, forKey: .execute)
            try container.encode(elaborate, forKey: .elaborate)
            try container.encode(deep, forKey: .deep)
            try container.encode(keep, forKey: .keep)
            try container.encode(imageDatas, forKey: .imageDatas)
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

    /// The set of "starred" project paths the user has curated (#035), keyed by
    /// `ProjectTasks.projectPath`. Starring is a first-class filter INPUT: the
    /// `.starred` project view mode (#072) shows exactly these projects (see
    /// `BrowserWindow.sortedProjects`). It is no longer a mere exception to an
    /// empty-project gate, so it now means something in every mode. Persisted
    /// on every set by writing `Array(starredProjectPaths)` to
    /// `starredProjectsKey` in `defaults` (UserDefaults stores arrays, not Sets).
    /// NEVER written to `.plans/` (§2 read-only) — UserDefaults is the only sink.
    var starredProjectPaths: Set<String> = [] {
        didSet { defaults.set(Array(starredProjectPaths), forKey: Self.starredProjectsKey) }
    }

    /// The path of the single project the dashboard is "focused" on (#067), or
    /// `nil` when focus mode is off and every project is shown. When set, the
    /// browser filters the grid down to just this project's card (see
    /// `BrowserViewModel.visibleUnderFocus`). Pure UI-only state — like every
    /// other browser preference it is persisted ONLY to `defaults` on each set
    /// and is NEVER written to `.plans/` (§2 read-only).
    var focusedProjectPath: String? {
        didSet { defaults.set(focusedProjectPath, forKey: Self.focusedProjectKey) }
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

    /// Which projects the browser dashboard shows (#072): `.all` (the default),
    /// `.active` (outstanding work only) or `.starred` (curated only). The single
    /// labelled control that replaced the old "Hide Empty" toggle and the star
    /// exception. Persisted on every set (its `rawValue` is the wire form) so the
    /// choice survives app restarts. NEVER written to `.plans/` (§2 read-only) —
    /// UserDefaults is the only persistence sink.
    var projectViewMode: ProjectViewMode = .all {
        didSet { defaults.set(projectViewMode.rawValue, forKey: Self.projectViewModeKey) }
    }

    /// Whether the browser surfaces backlogged plans (#077). Defaults OFF so the
    /// dashboard stays focused on active work; when on, each project's
    /// backlogged tasks become visible. Persisted on every set so the choice
    /// survives app restarts. NEVER written to `.plans/` (§2 read-only) —
    /// UserDefaults is the only persistence sink.
    var showBacklog: Bool = false {
        didSet { defaults.set(showBacklog, forKey: Self.showBacklogKey) }
    }

    /// UserDefaults key for the persisted manual card order (array of paths).
    private static let orderKey = "cardOrderOverride"

    /// UserDefaults key for the persisted manual-order-active flag.
    private static let activeKey = "cardOrderManualActive"

    /// UserDefaults key for the persisted card layout mode (#033).
    private static let cardLayoutKey = "cardLayoutMode"

    /// UserDefaults key for the persisted project view mode (#072).
    private static let projectViewModeKey = "projectViewMode"

    /// UserDefaults key for the persisted show-backlog flag (#077).
    private static let showBacklogKey = "showBacklog"

    /// UserDefaults key for the persisted starred project paths (#035). The
    /// stored value is `Array(starredProjectPaths)` (UserDefaults stores arrays).
    private static let starredProjectsKey = "starredProjects"

    /// UserDefaults key for the persisted focused project path (#067).
    private static let focusedProjectKey = "focusedProject"

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

    /// The total number of tasks with a live run-failure overlay (#079),
    /// aggregated across every live project. The failure state is an OVERLAY, not
    /// a `TaskStatus`, so it is not present in `project.counts`; it is counted
    /// directly from each task's `failure` field. `0` means nothing has failed,
    /// so the menu-bar surfaces suppress the failed badge entirely. Reuses the
    /// already-correlated `task.failure` — no new parsing happens here.
    var failedCount: Int {
        projects.reduce(0) { sum, project in
            sum + project.tasks.filter { $0.failure != nil }.count
        }
    }

    /// The registry reader used by `reload()` to discover live projects.
    @ObservationIgnored private let registryReader: RegistryReader

    /// The registry writer used by `linkProject(at:)` to persist a manually
    /// linked project into `projects.json`.
    @ObservationIgnored private let registryWriter: RegistryWriter

    /// The task parser used by `reload()` to parse each project's `.plans/`.
    @ObservationIgnored private let taskParser: TaskParser

    /// The run-outcomes log reader (#079) used by `reload()` to correlate a
    /// FAILED latest run onto its still-in-progress task as a `failure` overlay.
    /// Injected (defaulting to the real `~/.claude/plans-cc/run-outcomes.log`
    /// reader) so tests point it at a temp fixture. Stateless (holds only a
    /// `URL`/`FileManager`), so it is safe to read from the thread-agnostic
    /// `performReload`.
    @ObservationIgnored private let outcomeLogReader: RunOutcomeLogReader

    /// The UserDefaults instance backing the persisted manual-order state (#017).
    /// Injected (defaulting to `.standard`) so tests can pass an isolated suite.
    @ObservationIgnored private let defaults: UserDefaults

    /// The store's time source (#066 Step 2), defaulting to `Date.init`. The ONLY
    /// wall-clock read on the git-throttle path goes through here, so tests can
    /// inject a mutable clock and step across the throttle boundary
    /// deterministically instead of sleeping. Never call `Date()` directly in
    /// throttle logic — that would make the interval untestable.
    @ObservationIgnored private let now: () -> Date

    /// The repeating timer that drives live refresh, or `nil` when not polling.
    /// `@ObservationIgnored` because the timer itself is not observable UI state.
    @ObservationIgnored private var pollTimer: Timer?

    /// A monotonic counter bumped at the START of every reload — both the
    /// synchronous `reload()` and the async `reloadAsync()` (#059). It lets the
    /// async poll path detect that a NEWER reload (a synchronous `linkProject` /
    /// initial load, or a later poll) has started while its off-main parse was in
    /// flight, so the stale result can be dropped instead of clobbering fresher
    /// `projects`. `@ObservationIgnored` because it is internal race bookkeeping,
    /// not observable UI state. Only ever read/written on the main thread; the
    /// async path captures a snapshot value into its closure and compares it back
    /// on the main-thread hop.
    @ObservationIgnored private var reloadGeneration: Int = 0

    /// The change-gate cache (#066): the last-computed `ProjectSignature` and the
    /// `ProjectTasks` it produced, keyed by project path. On each reload, a
    /// project whose freshly-computed signature EQUALS its cached one is not
    /// re-listed/re-read/re-parsed at all — the cached `ProjectTasks` is reused
    /// verbatim. This is the fix for #066: on an idle tick, where no `.plans/`
    /// file has changed in any registered project, the reload does one cheap
    /// directory listing per project and nothing else.
    ///
    /// Freshness is preserved because the poll interval is unchanged and the
    /// signature is recomputed on EVERY tick — only the expensive read+parse is
    /// gated, never the detection. See `ProjectSignature` for exactly which
    /// on-disk changes the signature catches (adds, removes, renames, moves, and
    /// in-place content edits) and its one unreachable-in-practice failure mode.
    ///
    /// Entries for projects no longer in the registry are dropped on each reload,
    /// so an unregistered project can never resurrect a stale cached result.
    ///
    /// `@ObservationIgnored` — internal memoization, not observable UI state.
    /// Only ever read/written on the MAIN thread: the async poll path snapshots
    /// it on main before dispatching, and installs the rebuilt cache back on main
    /// inside `applyReloadResult`, under the same #059 generation guard that
    /// protects `projects` (so a stale poll can never install a stale cache).
    @ObservationIgnored private var parseCache: [String: CachedParse] = [:]

    /// One project's memoized parse: the signature of the `.plans/` state that
    /// produced `tasks`, plus that result. `Sendable` so it can ride along into
    /// the background parse closure as part of an immutable snapshot.
    private struct CachedParse {
        let signature: ProjectSignature
        let tasks: ProjectTasks
    }

    /// The mtime-gated cache of the run-outcomes log (#079). The log is read (and
    /// its latest-per-task map recomputed) ONLY when the file's modification date
    /// differs from `mtime`; on an idle tick where no run has finished, the
    /// cached `latestByTask` is reused verbatim, so the ~5s poll never re-reads
    /// and re-decodes the whole NDJSON log. This mirrors the `ProjectSignature`
    /// change-gate discipline (`parseCache`), scoped to the single append-only
    /// log file. `mtime` is `nil` when the log is missing/unreadable, which the
    /// gate treats as "no change" once cached (an empty map is reused). Threaded
    /// as a value through `performReload` — the same in/out pattern as the parse
    /// cache — so both the sync and async reload paths share one code path.
    ///
    /// `@ObservationIgnored` — internal memoization, not observable UI state.
    /// Only read/written on the MAIN thread (snapshotted before the async parse,
    /// installed back on main under the #059 generation guard).
    @ObservationIgnored private var outcomeCache = OutcomeCache(mtime: nil, latestByTask: [:])

    /// The mtime-gated run-outcomes state (#079): the log's last-seen
    /// modification date and the latest-per-`(projectPath, taskID)` outcome map
    /// derived from it. `Sendable` (immutable value fields) so it rides into the
    /// background parse closure inside the reload snapshot.
    private struct OutcomeCache: Sendable {
        let mtime: Date?
        let latestByTask: [RunOutcomeKey: RunOutcome]
    }

    /// The project paths that were actually RE-PARSED (not served from the
    /// change-gate cache) by the most recent reload, in registry order. Written
    /// on the main thread by `reload()` / `applyReloadResult`. Exposed to tests
    /// via `lastReloadParsedPathsForTesting` so the gate's behavior is directly
    /// assertable: `[]` means an entirely idle tick did zero parsing.
    @ObservationIgnored private var lastReloadParsedPaths: [String] = []

    /// Invoked at the END of every `reload()` (synchronous task-parse pass),
    /// after `projects` has been repopulated — on BOTH the run-finish hand-off
    /// path AND every 5s poll tick. The app wires this to
    /// `TaskRunner.reconcileFinishedCaptures(against:)` so a finished capture's
    /// spinner row is dismissed as soon as its new plan file appears in
    /// `projects`, regardless of which reload surfaced it (#051). Without a
    /// poll-driven reconcile, a capture whose plan lands AFTER the run-finish
    /// reconcile pass (a filesystem-flush race) would be picked up by the next
    /// poll for rendering but never reconciled, orphaning the spinner alongside
    /// the real plan row. `@ObservationIgnored` — it is a wiring seam, not UI
    /// state. Set once at injection; not part of the read contract.
    @ObservationIgnored var onDidReload: (() -> Void)?

    /// The in-flight, not-yet-persisted capture draft scheduled by
    /// `setDraftDebounced`, as a `(projectPath, draft)` pair, or `nil` when no
    /// debounced write is pending (#052). Holds the latest keystroke state so
    /// `draft(for:)` reflects it before the debounce fires; committed to
    /// `captureDrafts` (the single encode/write sink) when the timer fires or
    /// `flushPendingDraft()` is called. `@ObservationIgnored` because it is a
    /// transient persistence buffer, not observable UI state.
    @ObservationIgnored private var pendingDraft: (path: String, draft: CaptureDraft)?

    /// The cancellable work item that commits `pendingDraft` after the debounce
    /// interval (#052), or `nil` when nothing is scheduled. Cancelled and
    /// replaced on each `setDraftDebounced` call (the coalescing mechanism) and
    /// cancelled outright by `flushPendingDraft`/`setDraft`/`clearDraft`.
    /// `@ObservationIgnored` because the timer is not observable UI state.
    @ObservationIgnored private var pendingDraftWorkItem: DispatchWorkItem?

    /// Defaults to the real readers/writer and `.standard` UserDefaults. Inject
    /// fixtures-backed readers/writer (all pointed at the same temp registry URL)
    /// and an isolated `UserDefaults(suiteName:)` in tests. The persisted
    /// manual-order state (#017) is loaded eagerly here so the override is in
    /// effect before the first grid layout.
    init(
        registryReader: RegistryReader = RegistryReader(),
        registryWriter: RegistryWriter = RegistryWriter(),
        taskParser: TaskParser = TaskParser(),
        outcomeLogReader: RunOutcomeLogReader = RunOutcomeLogReader(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.registryReader = registryReader
        self.registryWriter = registryWriter
        self.taskParser = taskParser
        self.outcomeLogReader = outcomeLogReader
        self.defaults = defaults
        self.now = now
        // Load persisted manual-order state. Assigning the backing fields avoids
        // re-persisting (the `didSet` would write the just-read value back).
        _projectOrderOverride = defaults.stringArray(forKey: Self.orderKey) ?? []
        _manualOrderActive = defaults.bool(forKey: Self.activeKey)
        _cardLayoutMode = CardLayoutMode(rawValue: defaults.string(forKey: Self.cardLayoutKey) ?? "") ?? .scroll
        _projectViewMode = ProjectViewMode(rawValue: defaults.string(forKey: Self.projectViewModeKey) ?? "") ?? .all
        // Load persisted show-backlog flag (#077). `bool(forKey:)` returns false
        // for a missing key, so the default is correctly OFF. Assigning the
        // backing field avoids the `didSet` re-persisting the just-read value.
        _showBacklog = defaults.bool(forKey: Self.showBacklogKey)
        // Load persisted starred project paths (#035): the stored array round-trips
        // back into the `Set`. Assigning the backing field avoids the `didSet`
        // re-persisting the just-read value.
        _starredProjectPaths = Set(defaults.stringArray(forKey: Self.starredProjectsKey) ?? [])
        // Load persisted focused project path (#067): assigning the backing field
        // avoids the `didSet` re-persisting the just-read value.
        _focusedProjectPath = defaults.string(forKey: Self.focusedProjectKey)
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

    /// Returns the latest capture draft for `projectPath`, or `nil` when none
    /// exists (#031). Returns the in-flight `pendingDraft` (a debounced write not
    /// yet committed, #052) when its path matches, so the New Plan sheet never
    /// reads a stale value between a keystroke and the debounce fire; otherwise
    /// reads the persisted in-memory `captureDrafts` map.
    func draft(for projectPath: String) -> CaptureDraft? {
        if let pending = pendingDraft, pending.path == projectPath {
            return pending.draft
        }
        return captureDrafts[projectPath]
    }

    /// Stores `draft` as the capture draft for `projectPath` (#031), replacing
    /// any prior draft. Triggers persistence via the `captureDrafts` setter.
    /// Cancels any pending debounced write (#052) so a stale in-flight write
    /// can't later overwrite this authoritative value. Never writes `.plans/`
    /// (§2) — UserDefaults is the only sink.
    func setDraft(_ draft: CaptureDraft, for projectPath: String) {
        cancelPendingDraft()
        captureDrafts[projectPath] = draft
    }

    /// Stores `draft` as `projectPath`'s capture draft via a debounced write
    /// (#052): rapid successive calls within `interval` coalesce into at most one
    /// encode+write per typing pause, instead of the per-keystroke synchronous
    /// `JSONEncoder().encode` + UserDefaults write that caused the New Plan
    /// editor typing lag. The latest value is buffered in `pendingDraft` (so
    /// `draft(for:)` reflects it immediately) and a `DispatchWorkItem` scheduled
    /// on the main run loop commits it to `captureDrafts` — the single
    /// encode/write sink — when the pause elapses. Each call cancels and replaces
    /// the prior scheduled work item. Never writes `.plans/` (§2).
    func setDraftDebounced(
        _ draft: CaptureDraft,
        for projectPath: String,
        interval: TimeInterval = 0.3
    ) {
        pendingDraftWorkItem?.cancel()
        pendingDraft = (path: projectPath, draft: draft)
        // `self` is captured strongly: the store is app-lifetime (same rationale
        // as the poll timer) so there is no meaningful retain cycle to break.
        let workItem = DispatchWorkItem { [self] in
            commitPendingDraft()
        }
        pendingDraftWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    /// Commits any pending debounced draft (#052) to `captureDrafts` immediately,
    /// cancelling the scheduled timer. Call on the edges that must not lose an
    /// in-flight keystroke: submit, sheet dismissal, and project switch. A no-op
    /// when nothing is pending.
    func flushPendingDraft() {
        pendingDraftWorkItem?.cancel()
        pendingDraftWorkItem = nil
        commitPendingDraft()
    }

    /// Writes the buffered `pendingDraft` (if any) into `captureDrafts` — the
    /// single encode/write sink — and clears the buffer (#052). Shared by the
    /// debounce timer fire and `flushPendingDraft`.
    private func commitPendingDraft() {
        guard let pending = pendingDraft else { return }
        pendingDraft = nil
        captureDrafts[pending.path] = pending.draft
    }

    /// Cancels and discards any pending debounced draft without persisting it
    /// (#052), so a stale in-flight write can't resurrect a cleared/overwritten
    /// draft after its timer would have fired.
    private func cancelPendingDraft() {
        pendingDraftWorkItem?.cancel()
        pendingDraftWorkItem = nil
        pendingDraft = nil
    }

    /// Removes the saved capture draft for `projectPath` (#031), if any. Called
    /// after a successful submit or an explicit "Clear". Cancels any pending
    /// debounced write (#052) first so a stale in-flight write can't resurrect
    /// the cleared draft. Triggers persistence via the `captureDrafts` setter;
    /// never writes `.plans/` (§2).
    func clearDraft(for projectPath: String) {
        cancelPendingDraft()
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

    /// Toggles focus mode for `path` (#067): focuses it when it is not already the
    /// focused project, or clears focus when it already is (a second toggle on the
    /// same card exits focus mode). Persisted via the `focusedProjectPath` setter.
    /// UI-only state — never touches `.plans/` (§2 read-only).
    func toggleFocus(_ path: String) {
        focusedProjectPath = (focusedProjectPath == path) ? nil : path
    }

    /// Exits focus mode by clearing the focused project (#067), restoring the full
    /// dashboard. Persisted via the `focusedProjectPath` setter. UI-only state —
    /// never touches `.plans/` (§2 read-only).
    func clearFocus() {
        focusedProjectPath = nil
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
        // Bump the reload generation (#059). `reload()` is fully synchronous so it
        // has no stale-result risk of its own, but bumping the counter is what
        // lets a synchronous reload (from `linkProject` or the initial load) win
        // the race against an older in-flight async poll: that poll captured a now-
        // superseded generation and will drop its result when it hops back to main.
        reloadGeneration += 1

        // Snapshot the previously-known git info per path so the re-parse below
        // can carry it over. The parser constructs `ProjectTasks` with `nil` git
        // fields; without this carry-over, every 5s poll would momentarily reset
        // each card's git row to `nil` (hiding the branch + dirty dot) until the
        // async second pass repopulates it — a visible flash on every poll (#024).
        let priorGitInfo = Dictionary(
            projects.map { ($0.projectPath, ($0.gitBranch, $0.gitIsDirty)) },
            uniquingKeysWith: { first, _ in first }
        )

        // Run the parse pass on the calling (main) thread. This keeps `reload()`
        // synchronous and behavior-identical: `projects` is populated before this
        // method returns, preserving `startPolling()`'s "populated before this
        // returns" contract and `linkProject`'s immediate-appear UX.
        //
        // The change gate (#066) is threaded through as a value: the current
        // cache goes in, a rebuilt cache comes out, and it is installed here on
        // the main thread — the same shape the async path uses, so both paths
        // share one code path.
        let result = performReload(
            priorGitInfo: priorGitInfo,
            cache: parseCache,
            outcomeCache: outcomeCache
        )
        publishProjects(result.projects)
        parseCache = result.cache
        outcomeCache = result.outcomeCache
        lastReloadParsedPaths = result.parsedPaths


        // Second pass (#024): gather live git state OFF the main thread so the
        // blocking `git` subprocesses never stall the UI, then merge it back on
        // the main thread. The first (synchronous) pass above already painted the
        // cards carrying over the last-known git fields, so this only refreshes
        // them with live values. Shared with the async poll path — see
        // `startGitSecondPass()` for the full GCD/Sendability rationale.
        startGitSecondPass()

        // Reconcile finished capture spinner rows against the just-repopulated
        // `projects` on EVERY reload — poll tick included, not only the
        // run-finish hand-off (#051). Fires after the synchronous task-parse
        // pass above (the git second pass is async and irrelevant to
        // reconciliation), so the moment a captured plan's file lands and a
        // poll parses it, the orphaned spinner clears next tick.
        onDidReload?()
    }

    /// Builds the fresh `projects` array by reading the registry and re-parsing
    /// every live project, carrying over the supplied prior git info per path.
    /// Returns the built array WITHOUT mutating any store state.
    ///
    /// This method is intentionally pure and thread-agnostic: it touches no
    /// mutable `self` state (it only reads the injected `registryReader` /
    /// `taskParser`, both of which are stateless value-based readers, and the
    /// caller-supplied `priorGitInfo` snapshot). That makes it safe to invoke on
    /// any thread — the synchronous `reload()` calls it on the main thread, while
    /// `reloadAsync()` dispatches it onto a background queue and assigns the
    /// result back on the main thread. Because it never writes the observable
    /// `projects`, SwiftUI is never mutated off-main here.
    private func performReload(
        priorGitInfo: [String: (String?, Bool?)],
        cache: [String: CachedParse],
        outcomeCache: OutcomeCache
    ) -> ReloadResult {
        var freshCache: [String: CachedParse] = [:]
        var parsedPaths: [String] = []

        // Mtime-gate the run-outcomes log read (#079): recompute the latest-per-
        // task outcome map ONLY when the log file's modification date changed
        // since the last tick; otherwise reuse the cached map verbatim so an idle
        // poll never re-reads/re-decodes the whole NDJSON log. Mirrors the
        // `ProjectSignature` parse-gate discipline, scoped to one file.
        let freshOutcomeCache = refreshedOutcomeCache(from: outcomeCache)
        let latestOutcomes = freshOutcomeCache.latestByTask

        let projects = registryReader.readProjects().map { project -> ProjectTasks in
            // Cheap change detection (#066): one batched directory listing per
            // `.plans` subdirectory, with mtime + size prefetched. Recomputed on
            // EVERY tick so freshness is never gated — only the expensive
            // read + markdown-parse below is.
            let signature = taskParser.projectSignature(at: project.path)

            let parsed: ProjectTasks
            if let cached = cache[project.path],
               cached.signature == signature,
               cached.tasks.lastSeen == project.lastSeen {
                // Unchanged since the last tick: reuse the previous parse
                // verbatim. No directory re-listing of contents, no file reads,
                // no markdown parsing.
                parsed = cached.tasks
            } else {
                parsed = taskParser.parseProject(at: project.path, lastSeen: project.lastSeen)
                parsedPaths.append(project.path)
            }

            // Rebuilt from the registry each time, so a project that dropped out
            // of the registry has its cache entry dropped with it and cannot
            // resurrect a stale result if it is re-added later. The cache stores
            // the failure-free parse: the failure overlay (#079) is applied AFTER
            // the cache lookup so a new outcome badges its task even on a tick
            // where the `.plans/` file itself did not change.
            freshCache[project.path] = CachedParse(signature: signature, tasks: parsed)

            let withGit: ProjectTasks
            if let prior = priorGitInfo[project.path] {
                withGit = ProjectTasks(
                    projectPath: parsed.projectPath,
                    projectName: parsed.projectName,
                    lastSeen: parsed.lastSeen,
                    tasks: parsed.tasks,
                    counts: parsed.counts,
                    activeTasks: parsed.activeTasks,
                    backloggedTasks: parsed.backloggedTasks,
                    gitBranch: prior.0,
                    gitIsDirty: prior.1
                )
            } else {
                withGit = parsed
            }

            return Self.applyFailureOverlay(to: withGit, latestOutcomes: latestOutcomes)
        }

        return ReloadResult(
            projects: projects,
            cache: freshCache,
            parsedPaths: parsedPaths,
            outcomeCache: freshOutcomeCache
        )
    }

    /// Returns the run-outcomes cache for this tick (#079): reuses `previous`
    /// unchanged when the log file's modification date is unchanged, otherwise
    /// re-reads the log and recomputes the latest-per-task map. A missing/
    /// unreadable log yields `mtime: nil` with an empty map. Pure/thread-agnostic
    /// (reads only the injected stateless `outcomeLogReader`), so it is safe to
    /// call from the background parse.
    private func refreshedOutcomeCache(from previous: OutcomeCache) -> OutcomeCache {
        let currentMtime = try? outcomeLogReader.fileURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate

        // Unchanged since last tick (including still-missing: both `nil`) — reuse
        // the cached map without touching the file.
        if currentMtime == previous.mtime {
            return previous
        }
        return OutcomeCache(
            mtime: currentMtime,
            latestByTask: outcomeLogReader.latestOutcomeByTask()
        )
    }

    /// Applies the run-failure overlay (#079) to a project's tasks: for each task
    /// whose EFFECTIVE status is `.inProgress` and whose latest `RunOutcome`
    /// (keyed by `(projectPath, taskID)`) is a FAILURE classification, sets a
    /// `TaskFailure`. Every other task keeps `failure == nil`, so a task that has
    /// advanced past in-progress (or whose latest outcome is `completed`) shows no
    /// stale badge. Rebuilds the affected `tasks` / `activeTasks` arrays (backlog
    /// tasks are never in-progress, so they are left untouched). Static + pure so
    /// it is thread-agnostic like the rest of `performReload`.
    private static func applyFailureOverlay(
        to project: ProjectTasks,
        latestOutcomes: [RunOutcomeKey: RunOutcome]
    ) -> ProjectTasks {
        // Cheap out: no outcomes recorded at all, nothing can overlay.
        guard !latestOutcomes.isEmpty else { return project }

        func overlay(_ task: Task) -> Task {
            guard task.status == .inProgress else { return task }
            let key = RunOutcomeKey(projectPath: project.projectPath, taskID: task.id)
            guard let outcome = latestOutcomes[key],
                  Self.failingClassifications.contains(outcome.classification) else {
                return task
            }
            // Liveness/recency guard (#080): suppress a STALE failing outcome —
            // one whose timestamp PREDATES the plan file's last edit. A terminal
            // execution (which the app cannot observe directly) keeps the task
            // pinned at in-progress and never writes the outcome log, but it does
            // continually rewrite the plan file, advancing its mtime past any old
            // app-run failure. So an outcome older than the file's mtime belongs
            // to a superseded run and must not light the alarm. Fails SAFE: when
            // either the file mtime or the outcome timestamp is unavailable, fall
            // through to showing the overlay so a genuine failure is never hidden.
            if let fileModified = task.modified,
               let outcomeDate = outcome.timestampDate,
               outcomeDate.timeIntervalSinceReferenceDate < fileModified {
                return task
            }
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
                isBlocked: task.isBlocked,
                isCompletedDir: task.isCompletedDir,
                isBacklogged: task.isBacklogged,
                failure: TaskFailure(
                    classification: outcome.classification,
                    errorMessage: outcome.errorMessage,
                    stopReason: outcome.stopReason,
                    timestamp: outcome.timestamp
                ),
                modified: task.modified
            )
        }

        return ProjectTasks(
            projectPath: project.projectPath,
            projectName: project.projectName,
            lastSeen: project.lastSeen,
            tasks: project.tasks.map(overlay),
            counts: project.counts,
            activeTasks: project.activeTasks.map(overlay),
            backloggedTasks: project.backloggedTasks,
            gitBranch: project.gitBranch,
            gitIsDirty: project.gitIsDirty
        )
    }

    /// The `RunOutcome.Classification` cases that count as a run FAILURE for the
    /// #079 overlay: everything except `completed`. A task whose latest outcome is
    /// one of these AND is still at in-progress surfaces a failure badge.
    private static let failingClassifications: Set<RunOutcome.Classification> = [
        .truncated, .stranded, .error, .crashed,
    ]

    /// The full output of one `performReload` pass (#066): the projects to
    /// publish, the rebuilt change-gate cache to install, and which project paths
    /// were actually re-parsed this pass. Bundled into a single value so the
    /// background parse can hand everything back across the main-thread hop
    /// atomically, under one generation guard.
    private struct ReloadResult {
        let projects: [ProjectTasks]
        let cache: [String: CachedParse]
        let parsedPaths: [String]
        let outcomeCache: OutcomeCache
    }

    /// Asynchronous reload for the timer-driven poll: identical to `reload()` in
    /// outcome, but the (potentially UI-hitching) parse pass runs OFF the main
    /// thread so a focused text editor never stalls on a poll tick. Only the
    /// prior-git snapshot is taken on the main thread; the `performReload` parse
    /// pass is dispatched to a background queue, and its result is applied back on
    /// the main thread, where the observable `projects` is assigned, the async git
    /// second pass is kicked off, and `onDidReload?()` fires.
    ///
    /// `onDidReload?()` MUST fire AFTER the main-thread `projects` assignment so
    /// #051 capture-spinner reconciliation still sees the freshly-repopulated
    /// `projects` (same ordering as synchronous `reload()`).
    ///
    /// Out-of-order guard (#059): each call bumps `reloadGeneration` and captures
    /// that value. On the main-thread hop, BEFORE assigning `projects`, it drops
    /// the result entirely (no `projects` assignment, no git second pass, no
    /// `onDidReload?()`) if a newer reload — synchronous or async — has since
    /// started (`captured != reloadGeneration`). This prevents a slow poll's stale
    /// parse from clobbering a newer `linkProject`/initial load.
    ///
    /// GCD (not structured concurrency) is used deliberately, mirroring the git
    /// second pass below: `PlansStore` is a non-`Sendable`, main-thread-only
    /// reference type, and GCD lets us hop background→main without crossing a
    /// Swift-concurrency Sendability boundary on `self`. `self` is captured
    /// `nonisolated(unsafe)`; it is only ever touched on the main thread (the
    /// background closure captures only value-type snapshots — the
    /// `priorGitInfo` dictionary — and never reads `self`). The capture is strong
    /// because the store is app-lifetime (same rationale as the poll timer), so
    /// there is no meaningful retain cycle to break.
    private func reloadAsync() {
        // Bump + capture this reload's generation (#059). A newer synchronous
        // `reload()` or a later `reloadAsync()` will bump past this value, marking
        // our pending result stale by the time it hops back to main.
        reloadGeneration += 1
        let generation = reloadGeneration

        // Snapshot prior git info on the main thread (reads the observable
        // `projects`), same carry-over rationale as `reload()` (#024).
        let priorGitInfo = Dictionary(
            projects.map { ($0.projectPath, ($0.gitBranch, $0.gitIsDirty)) },
            uniquingKeysWith: { first, _ in first }
        )

        // Snapshot the change-gate cache on the main thread too (#066). It is a
        // dictionary of immutable values, so the background pass reads only this
        // detached copy and never touches `self.parseCache`; the rebuilt cache is
        // installed back on main under the #059 generation guard.
        let cacheSnapshot = parseCache

        // Snapshot the run-outcomes cache on main too (#079): a value of
        // immutable fields, so the background pass reads only this detached copy
        // and never touches `self.outcomeCache`; the rebuilt cache is installed
        // back on main under the #059 generation guard, same as the parse cache.
        let outcomeCacheSnapshot = outcomeCache

        nonisolated(unsafe) let unsafeSelf = self
        DispatchQueue.global(qos: .userInitiated).async {
            let result = unsafeSelf.performReload(
                priorGitInfo: priorGitInfo,
                cache: cacheSnapshot,
                outcomeCache: outcomeCacheSnapshot
            )
            DispatchQueue.main.async {
                unsafeSelf.applyReloadResult(result, generation: generation)
            }
        }
    }

    /// The main-thread tail of an async reload (#059): the guarded assignment of
    /// the freshly-parsed `projects` plus the follow-on git second pass and
    /// `onDidReload?()`. Extracted so the real `reloadAsync` closure and the
    /// test-only applier exercise the SAME guard logic. MUST run on the main
    /// thread (mutates the observable `projects` and reads `reloadGeneration`).
    ///
    /// Drops the result if a newer reload has started since `generation` was
    /// captured (`generation != reloadGeneration`), returning BEFORE assigning
    /// `projects` — so a stale poll never clobbers a fresher `linkProject`/initial
    /// load nor fires its git second pass / `onDidReload?()`. Otherwise assigns
    /// `projects` FIRST, then kicks the async git second pass and fires
    /// `onDidReload?()`, preserving the synchronous `reload()` ordering (#051).
    private func applyReloadResult(_ result: ReloadResult, generation: Int) {
        guard generation == reloadGeneration else { return }
        publishProjects(result.projects)
        // Install the rebuilt change-gate cache (#066) inside the SAME guard that
        // protects `projects`, so a dropped stale result leaves the cache
        // untouched too — the two can never drift apart.
        parseCache = result.cache
        // Install the rebuilt run-outcomes cache (#079) under the SAME guard, so a
        // dropped stale result leaves it untouched too.
        outcomeCache = result.outcomeCache
        lastReloadParsedPaths = result.parsedPaths
        startGitSecondPass()
        onDidReload?()
    }

    // MARK: - Equality-gated publishing (#066 Step 4)

    /// Assigns `projects` ONLY when `newValue` actually differs from what is
    /// already published (#066 Step 4). This is the single write point for the
    /// observable `projects` on the reload path.
    ///
    /// Why the guard is necessary: `@Observable` reports a mutation on ANY
    /// assignment to a stored property, even one whose new value compares equal
    /// to the old. Before this gate, every 5s poll reassigned `projects` with a
    /// freshly-built-but-identical array, which invalidated every SwiftUI
    /// observer of the store — the project cards, `MenuBarView`, and (most
    /// expensively) `MenuBarLabel`, which re-bakes its menu-bar bitmap through
    /// `ImageRenderer` whenever `store.iconSpaceCounts` is re-read. Step 3 had
    /// already stopped the idle tick from re-PARSING; this stops it from
    /// re-RENDERING.
    ///
    /// Correctness rests entirely on `ProjectTasks: Equatable` comparing the
    /// whole value graph — see `Task.==`, which is hand-written (its
    /// `howProgress` tuple blocks synthesis) and deliberately compares every
    /// stored property. A missed field here would silently drop a real change
    /// from both surfaces, which is far worse than the energy cost.
    ///
    /// Returns nothing; `lastReloadDidPublishProjects` records the outcome for
    /// the test seam. MUST be called on the main thread (it may mutate the
    /// observable `projects`).
    private func publishProjects(_ newValue: [ProjectTasks]) {
        guard newValue != projects else {
            lastReloadDidPublishProjects = false
            return
        }
        projects = newValue
        lastReloadDidPublishProjects = true
        projectsPublishCount &+= 1
    }

    /// Whether the most recent reload actually PUBLISHED a new `projects` value
    /// (#066 Step 4), as opposed to finding it byte-for-byte identical and
    /// leaving the observable untouched. Exposed to tests via
    /// `lastReloadDidPublishProjectsForTesting`. `@ObservationIgnored` — reading
    /// it must never itself create an observation dependency.
    @ObservationIgnored private var lastReloadDidPublishProjects: Bool = false

    /// A monotonic count of how many times `projects` has actually been
    /// reassigned (#066 Step 4), across BOTH the reload path and the git
    /// second-pass merge. Lets a test prove that N idle ticks bumped it zero
    /// times. `@ObservationIgnored` — internal bookkeeping, not UI state.
    @ObservationIgnored private var projectsPublishCount: Int = 0

    // MARK: - Throttled git second pass (#066 Step 2)

    /// How long a project's git branch/dirty result is considered fresh enough to
    /// reuse without re-running `git` (#066 Step 2).
    ///
    /// Chosen as **30 seconds** — the short end of the ~30-60s freshness lag the
    /// task's Assumptions already accept. At the unchanged 5s poll interval this
    /// turns 12 ticks' worth of git work into 1, a ~83% cut in subprocess spawns
    /// (24 spawns every 5s → 24 every 30s; ~415k/day → ~69k/day), while keeping
    /// the worst-case staleness of a branch indicator to 30s. A longer window
    /// (60s) would only save a further ~8% of the original spawns while doubling
    /// the window in which the UI can show a wrong branch, so it is not worth it.
    ///
    /// The staleness ceiling is in practice much tighter than 30s for the case
    /// that actually matters: a branch change driven by this app (or by a plan
    /// moving through `.plans/`) also changes that project's parse signature, and
    /// a changed project bypasses the throttle entirely (see
    /// `gitPathsToQueryThisTick`). Only a branch switch made entirely outside the
    /// app, touching no `.plans/` file, waits out the full window.
    private static let gitThrottleInterval: TimeInterval = 30

    /// When each project path's git state was last QUERIED (#066 Step 2), keyed
    /// by project path. Rebuilt against the live registry on every pass, so a
    /// project that drops out of the registry loses its timestamp and cannot be
    /// throttled by a stale entry if it is re-registered later — it is queried
    /// immediately, exactly like a newly-registered project.
    ///
    /// `@ObservationIgnored` — internal throttle bookkeeping, not UI state. Main
    /// thread only: it is read and written solely inside `startGitSecondPass()`,
    /// which the reload paths call on the main thread. The background git work
    /// itself is untouched by this (#059 threading is unchanged).
    @ObservationIgnored private var gitQueryTimes: [String: Date] = [:]

    /// The project paths whose git state the most recent pass actually scheduled
    /// a query for (#066 Step 2). `[]` means a fully throttled tick spawned zero
    /// subprocesses. Exposed to tests via `lastGitPassQueriedPathsForTesting`.
    @ObservationIgnored private var lastGitPassQueriedPaths: [String] = []

    /// Decides which of the current projects need a live git query on this tick,
    /// and records the query time for those that do (#066 Step 2).
    ///
    /// A project is queried when ANY of these hold:
    /// 1. It has no recorded query time — newly registered (or re-registered), so
    ///    its branch is unknown and must be filled in immediately.
    /// 2. `gitThrottleInterval` has elapsed since its last query — the ceiling
    ///    that guarantees an externally-made branch switch still surfaces.
    /// 3. Its parse result changed on this very tick (it appears in
    ///    `lastReloadParsedPaths`) — a `.plans/` edit very often accompanies a
    ///    branch/dirty change (a plan moving to in-progress as a worktree is
    ///    created), so a changed project refreshes git without waiting out the
    ///    window. This is what keeps the common case feeling instant.
    ///
    /// Also prunes `gitQueryTimes` down to the live project paths, which is what
    /// makes de-registration drop the entry (see the property doc). Returns the
    /// paths to query, in `projects` order. MUST be called on the main thread.
    private func gitPathsToQueryThisTick() -> [String] {
        let currentTime = now()
        let changedPaths = Set(lastReloadParsedPaths)

        var refreshedTimes: [String: Date] = [:]
        var pathsToQuery: [String] = []

        for path in projects.map(\.projectPath) {
            let lastQueried = gitQueryTimes[path]
            let isStale = lastQueried.map {
                currentTime.timeIntervalSince($0) >= Self.gitThrottleInterval
            } ?? true

            if isStale || changedPaths.contains(path) {
                pathsToQuery.append(path)
                refreshedTimes[path] = currentTime
            } else {
                // Carrying the ORIGINAL timestamp forward (not `currentTime`) is
                // what makes the window an absolute ceiling: repeatedly skipping
                // a project can never push its next query further out.
                refreshedTimes[path] = lastQueried
            }
        }

        gitQueryTimes = refreshedTimes
        return pathsToQuery
    }

    /// Kicks off the #024 async git second pass against the current `projects`:
    /// gathers live git state OFF the main thread so the blocking `git`
    /// subprocesses never stall the UI, then merges it back on the main thread via
    /// `applyGitInfo`. See `reload()` for the full rationale (this is the same
    /// pass, extracted so both the synchronous and async reload paths can share
    /// it). MUST be called on the main thread (it reads the observable
    /// `projects`).
    ///
    /// Throttled (#066 Step 2): only the subset of projects returned by
    /// `gitPathsToQueryThisTick()` is queried, so a fully idle tick spawns zero
    /// subprocesses instead of two per project. Threading is deliberately
    /// unchanged — the same background dispatch, the same `GitResult`
    /// merge-by-path in `applyGitInfo` — the pass simply carries fewer results,
    /// and projects absent from it keep their last-known git fields (carried over
    /// by `performReload`) rather than being reset.
    private func startGitSecondPass() {
        let paths = gitPathsToQueryThisTick()
        lastGitPassQueriedPaths = paths

        // Nothing survived the throttle: skip the background dispatch entirely so
        // an idle tick costs zero queue hops as well as zero subprocesses.
        guard !paths.isEmpty else { return }

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
    ///
    /// Equality-gated (#066 Step 4): the merged array is built into a LOCAL copy
    /// and handed to `publishProjects`, which assigns the observable only when
    /// the result actually differs. On an idle tick the branch and dirty flag are
    /// unchanged, so this pass — which runs every 5s regardless — would otherwise
    /// have re-published identical data and defeated the parse-path gate a beat
    /// later.
    private func applyGitInfo(_ results: [GitResult]) {
        var merged = projects
        for result in results {
            guard let index = merged.firstIndex(where: { $0.projectPath == result.path }) else {
                continue
            }
            let existing = merged[index]
            merged[index] = ProjectTasks(
                projectPath: existing.projectPath,
                projectName: existing.projectName,
                lastSeen: existing.lastSeen,
                tasks: existing.tasks,
                counts: existing.counts,
                activeTasks: existing.activeTasks,
                backloggedTasks: existing.backloggedTasks,
                gitBranch: result.branch,
                gitIsDirty: result.dirty
            )
        }
        publishProjects(merged)
    }

    /// Begins live refresh: performs an immediate SYNCHRONOUS `reload()`
    /// (preserving the one-shot launch semantics — `projects` is populated
    /// synchronously before this returns) and then schedules a repeating
    /// main-run-loop `Timer` that calls the ASYNC `reloadAsync()` every `interval`
    /// seconds. Only the poll goes off-main (#059) so a focused text editor never
    /// hitches on a poll tick; the initial load stays synchronous. Any existing
    /// timer is invalidated first, so calling this repeatedly is safe.
    func startPolling(interval: TimeInterval = 5) {
        stopPolling()
        reload()
        // `self` is captured strongly: the store is app-lifetime and owns the
        // timer, so there is no meaningful retain cycle to break here.
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [self] _ in
            reloadAsync()
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

    /// Test-only hook: exposes the private, pure `performReload(priorGitInfo:)` so
    /// tests can prove it is thread-agnostic (same result whether invoked on the
    /// calling thread or a background queue) and that the git carry-over survives.
    /// Keeps the production method `private`.
    func performReloadForTesting(
        priorGitInfo: [String: (String?, Bool?)]
    ) -> [ProjectTasks] {
        // An empty cache means the change gate (#066) always misses, so this hook
        // exercises the full parse path exactly as it did before the gate landed.
        // An empty outcome cache with `mtime: nil` forces a fresh log read (#079).
        performReload(
            priorGitInfo: priorGitInfo,
            cache: [:],
            outcomeCache: OutcomeCache(mtime: nil, latestByTask: [:])
        ).projects
    }

    /// Test-only hook: exposes the private, pure `applyFailureOverlay` (#080) so
    /// tests can exercise the liveness-guard fallback branches in isolation —
    /// notably the `task.modified == nil` case, which a filesystem fixture cannot
    /// produce (a real file always carries an mtime). Keeps the production method
    /// `private`.
    static func applyFailureOverlayForTesting(
        to project: ProjectTasks,
        latestOutcomes: [RunOutcomeKey: RunOutcome]
    ) -> ProjectTasks {
        applyFailureOverlay(to: project, latestOutcomes: latestOutcomes)
    }

    /// Test-only hook: the project paths actually RE-PARSED by the most recent
    /// reload (#066). `[]` proves an idle tick did zero read/parse work; a
    /// non-empty array names exactly which projects the change gate let through.
    var lastReloadParsedPathsForTesting: [String] {
        lastReloadParsedPaths
    }

    /// Test-only hook: the project paths whose git state the most recent git
    /// second pass actually scheduled a query for (#066 Step 2). `[]` proves a
    /// throttled tick spawned zero `/usr/bin/git` subprocesses; a non-empty array
    /// names exactly which projects the throttle let through.
    var lastGitPassQueriedPathsForTesting: [String] {
        lastGitPassQueriedPaths
    }

    /// Test-only hook: whether the most recent reload (or git merge) actually
    /// reassigned the observable `projects` (#066 Step 4). `false` proves the
    /// equality gate suppressed the publish, so no SwiftUI observer — including
    /// `MenuBarLabel`'s `ImageRenderer` re-bake — was invalidated on that tick.
    var lastReloadDidPublishProjectsForTesting: Bool {
        lastReloadDidPublishProjects
    }

    /// Test-only hook: the monotonic count of actual `projects` reassignments
    /// (#066 Step 4). A test can snapshot it, drive N idle ticks, and assert the
    /// value is unchanged.
    var projectsPublishCountForTesting: Int {
        projectsPublishCount
    }

    /// Test-only hook: drives the REAL main-thread git merge (`applyGitInfo`)
    /// with caller-supplied results, so the equality gate on the git second pass
    /// can be exercised without spawning `git` subprocesses. MUST be called on
    /// the main thread.
    func applyGitInfoForTesting(_ results: [(path: String, branch: String?, dirty: Bool?)]) {
        applyGitInfo(results.map { GitResult(path: $0.path, branch: $0.branch, dirty: $0.dirty) })
    }

    /// Test-only hook: the current monotonic reload generation (#059), so tests
    /// can capture a value, drive a newer reload, and prove the guard drops the
    /// stale result.
    var reloadGenerationForTesting: Int {
        reloadGeneration
    }

    /// Test-only hook: drives the REAL guarded main-thread tail of an async reload
    /// (`applyReloadResult(_:generation:)`) with a caller-supplied captured
    /// generation, so the generation guard can be exercised deterministically
    /// without racing a real background dispatch. MUST be called on the main
    /// thread (it delegates to the main-thread-only applier).
    func applyReloadResultForTesting(_ projects: [ProjectTasks], generation: Int) {
        // Tests drive this with a bare projects array; the change-gate cache is
        // irrelevant to the generation guard being exercised, so an empty cache
        // is supplied. Passing `parsedPaths: []` mirrors "nothing was re-parsed",
        // which is accurate for a caller-supplied result.
        applyReloadResult(
            ReloadResult(
                projects: projects,
                cache: [:],
                parsedPaths: [],
                outcomeCache: OutcomeCache(mtime: nil, latestByTask: [:])
            ),
            generation: generation
        )
    }
}
