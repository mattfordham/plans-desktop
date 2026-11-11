import SwiftUI
import OSLog

private let reviewLog = Logger(subsystem: "com.plans.desktop", category: "ReviewModal")

/// The guided-"Review" confirmation sheet (#083) — the dialog the Review action
/// opens to pick WHERE the interactive `plan-review` run inspects the work, then
/// launch it via `TaskRunner.review(...)` (the bundled process is the sole writer
/// of `.plans/` / git state, §2; this view only READS git for its preflight).
///
/// Modeled on `ExecuteModal`: the target project and task are FIXED
/// (`init(taskID:projectPath:task:siblings:)`), so there is no project picker. Its
/// only control is the review-location picker, preset from a PER-PROJECT default
/// stored in `UserDefaults` (keyed by project path — NEVER written to
/// `.plans/config.json`, which is plans-cc's contract, not ours).
///
/// Before launching it runs a READ-ONLY preflight on the MAIN checkout (via
/// `GitHelper.currentBranch` / `GitHelper.isDirty`, following the #024 `gitBranch`
/// read): a dirty main tree raises a "will ask to stash or commit" warning, and a
/// sibling task holding the main checkout (`mainCheckoutOccupant`) DISABLES the
/// `main` option. A `.main` review leaves main on the task branch until
/// `/plan-complete`, which the sheet notes.
///
/// Confirming launches `.review` with the chosen location and can save it as the
/// project default. Every decision the body renders comes from a pure/static
/// helper below so the logic is unit-testable without the view.
struct ReviewModal: View {
    /// The task being reviewed; fixed for this sheet's lifetime.
    let taskID: String

    /// The owning project's path; fixed for this sheet's lifetime. Also the
    /// per-project `UserDefaults` default key and the main-checkout preflight dir.
    let projectPath: String

    /// The underlying task, so the sheet can compute its `availableReviewLocations`
    /// and resolve the kept-worktree path for the `kept` review.
    let task: Task

    /// The project's OTHER tasks, used to detect a `mainCheckoutOccupant` that
    /// would hold the main checkout during a `main` review.
    let siblings: [Task]

    /// The guided-review launcher; its `.review` run drives `plan-review`.
    @Environment(TaskRunner.self) private var runner

    /// Dismisses the sheet (Cancel and post-launch).
    @Environment(\.dismiss) private var dismiss

    /// The currently-picked review location. Initialized on appear from the
    /// saved per-project default (when still available) or the first available
    /// location, via `initialLocation(saved:available:)`.
    @State private var location: ReviewLocation?

    /// Whether to persist the picked location as this project's default on launch.
    @State private var saveAsDefault = false

    /// The read-only main-checkout preflight result, filled in by `.task` off the
    /// main actor. `nil` until it completes (and if git is unavailable).
    @State private var preflight: ReviewPreflight?

    /// The available review locations for this task, in display order.
    private var availableLocations: [ReviewLocation] {
        PlanDetailView.availableReviewLocations(for: task)
    }

    /// The sibling (if any) whose branch the main checkout is actually on, per
    /// the preflight's git read — disables the `main` option when non-nil.
    private var mainOccupantTaskID: String? {
        PlanDetailView.mainCheckoutOccupant(current: task, siblings: siblings,
                                            mainBranch: preflight?.mainBranch)?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review #\(taskID)")
                .font(.headline)

            Text("Choose where to review this plan.")
                .font(.callout)
                .foregroundStyle(.secondary)

            // The location picker — one radio-style row per available location,
            // the `main` row disabled when a sibling holds the main checkout.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(availableLocations, id: \.rawValue) { loc in
                    locationRow(loc)
                }
            }

            // A dirty-main-tree warning: the review will ask to stash or commit.
            // Shown only for the `main` location (the only one that touches main).
            if location == .main,
               let warning = Self.dirtyTreeWarning(isDirty: preflight?.mainIsDirty) {
                noticeRow(symbol: "exclamationmark.triangle.fill", color: .orange, text: warning)
            }

            // The main-checkout note: a `main` review leaves main on the task
            // branch until `/plan-complete`.
            if let loc = location, let note = Self.mainCheckoutNote(for: loc) {
                noticeRow(symbol: "info.circle", color: .secondary, text: note)
            }

            Toggle("Remember this choice for \(projectName)", isOn: $saveAsDefault)
                .toggleStyle(.checkbox)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Review") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canStart)
            }
        }
        .padding(16)
        .frame(minWidth: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // Preset the picker from the saved default (if still available), else
            // the first available location — a pure decision.
            location = Self.initialLocation(
                saved: Self.savedDefaultLocation(projectPath: projectPath),
                available: availableLocations
            )
        }
        .task {
            // Read-only preflight on the MAIN checkout, off the main actor (the
            // GitHelper reads block). Mirrors the #024 store git read; mutates
            // nothing. Captured as plain values for the `@State` hop back.
            let path = projectPath
            let result = await _Concurrency.Task.detached { () -> ReviewPreflight in
                ReviewPreflight(
                    mainBranch: GitHelper.currentBranch(at: path),
                    mainIsDirty: GitHelper.isDirty(at: path)
                )
            }.value
            preflight = result
        }
    }

    /// The owning project's display name, for the "Remember this choice" label.
    private var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }

    /// Whether Start is enabled: a location must be picked AND it must not be the
    /// disabled `main` option.
    private var canStart: Bool {
        guard let location else { return false }
        return !Self.isLocationDisabled(location, mainOccupantTaskID: mainOccupantTaskID)
    }

    // MARK: - Rows

    /// One selectable location row. The `main` row is disabled (and shows WHY)
    /// when a sibling holds the main checkout.
    @ViewBuilder
    private func locationRow(_ loc: ReviewLocation) -> some View {
        let disabled = Self.isLocationDisabled(loc, mainOccupantTaskID: mainOccupantTaskID)
        Button {
            location = loc
        } label: {
            HStack(spacing: 8) {
                Image(systemName: location == loc ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(location == loc ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.locationLabel(loc))
                    if loc == .main, let reason = Self.mainDisabledReason(occupantTaskID: mainOccupantTaskID) {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(Self.locationSubtitle(loc))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    /// A small notice row (warning / info), used for the dirty-tree warning and
    /// the main-checkout note.
    private func noticeRow(symbol: String, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Submit

    /// Launches the `.review` run at the picked location (optionally saving it as
    /// the project default) and dismisses. The spawned process is the sole writer
    /// of `.plans/` / git (§2); this view only read git for its preflight.
    private func submit() {
        guard let location, canStart else { return }
        if saveAsDefault {
            Self.saveDefaultLocation(location, projectPath: projectPath)
        }
        reviewLog.notice("modal Review submitted: task=\(self.taskID, privacy: .public) location=\(location.rawValue, privacy: .public) saveDefault=\(self.saveAsDefault)")
        runner.review(projectPath: projectPath, taskID: taskID, location: location)
        dismiss()
    }

    // MARK: - Pure helpers (unit-tested)

    /// The `UserDefaults` key for `projectPath`'s saved review-location default.
    /// Namespaced and per-project so two projects keep independent defaults. The
    /// default lives in `UserDefaults`, NEVER in `.plans/config.json` (that file
    /// is plans-cc's contract). `nonisolated` so it (and the persistence helpers
    /// below) is callable from a plain test without hopping the main actor.
    nonisolated static func defaultLocationKey(projectPath: String) -> String {
        "reviewLocationDefault:" + projectPath
    }

    /// The saved review-location default for `projectPath`, or `nil` when none is
    /// stored or the stored raw value is not a known `ReviewLocation`.
    nonisolated static func savedDefaultLocation(projectPath: String,
                                                 defaults: UserDefaults = .standard) -> ReviewLocation? {
        guard let raw = defaults.string(forKey: defaultLocationKey(projectPath: projectPath)) else {
            return nil
        }
        return ReviewLocation(rawValue: raw)
    }

    /// Persists `location` as `projectPath`'s review-location default.
    nonisolated static func saveDefaultLocation(_ location: ReviewLocation, projectPath: String,
                                                defaults: UserDefaults = .standard) {
        defaults.set(location.rawValue, forKey: defaultLocationKey(projectPath: projectPath))
    }

    /// The initial picker selection: the `saved` default when it is still among
    /// the `available` locations, else the first available location (or `nil`
    /// when none are available). Pure so the preset rule is testable.
    nonisolated static func initialLocation(saved: ReviewLocation?,
                                            available: [ReviewLocation]) -> ReviewLocation? {
        if let saved, available.contains(saved) { return saved }
        return available.first
    }

    /// The dirty-main-tree warning, or `nil` when the main tree is clean
    /// (`false`) or its state is unknown (`nil`). Only a KNOWN-dirty tree warns —
    /// `nil` (git unavailable / not a repo) must never assert "dirty".
    nonisolated static func dirtyTreeWarning(isDirty: Bool?) -> String? {
        guard isDirty == true else { return nil }
        return "Main has uncommitted changes — the review will ask to stash or commit."
    }

    /// The reason the `main` option is disabled, naming the sibling task holding
    /// the main checkout, or `nil` when no sibling holds it.
    nonisolated static func mainDisabledReason(occupantTaskID: String?) -> String? {
        guard let occupantTaskID else { return nil }
        return "Main is held by #\(occupantTaskID)"
    }

    /// Whether `location` is disabled given a main-checkout occupant: only the
    /// `main` location, and only when an occupant is present.
    nonisolated static func isLocationDisabled(_ location: ReviewLocation,
                                               mainOccupantTaskID: String?) -> Bool {
        location == .main && mainOccupantTaskID != nil
    }

    /// The "leaves main on the task branch until /plan-complete" note, shown ONLY
    /// for the `main` location; `nil` for `kept` / `worktree`.
    nonisolated static func mainCheckoutNote(for location: ReviewLocation) -> String? {
        guard location == .main else { return nil }
        return "Reviewing on main leaves main on the task branch until /plan-complete."
    }

    /// The display label for a review location.
    nonisolated static func locationLabel(_ location: ReviewLocation) -> String {
        switch location {
        case .kept: return "Kept worktree"
        case .worktree: return "New review worktree"
        case .main: return "Main checkout"
        }
    }

    /// A one-line subtitle describing where each location reviews.
    nonisolated static func locationSubtitle(_ location: ReviewLocation) -> String {
        switch location {
        case .kept: return "Review the surviving execution worktree in place."
        case .worktree: return "Spin up a throwaway worktree off the task branch."
        case .main: return "Check out the task branch in the project's main checkout."
        }
    }
}

/// The read-only main-checkout preflight result (#083): the main checkout's
/// current branch and whether its working tree is dirty. Both are plain,
/// GitHelper-sourced reads — the app NEVER mutates git (§2). `nil` fields mean
/// "unknown" (git unavailable / not a repo), distinct from a known value.
struct ReviewPreflight: Equatable {
    let mainBranch: String?
    let mainIsDirty: Bool?
}
