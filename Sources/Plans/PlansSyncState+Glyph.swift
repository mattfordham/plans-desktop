import SwiftUI

/// The one sync state a branch-mode project card shows, derived from the
/// `.plans` worktree's sync status plus the last sync outcome.
///
/// The marks and their order mirror the plans-cc dashboard's `plans:` header
/// line (`buildPlansLine` in `lib/render-dashboard.js`): a stuck rebase first,
/// then a missing upstream, then ahead `↑n` / behind `↓n`, else `✓`. The app
/// adds what only it can know — a sync running now, the last sync's conflict,
/// and a failed (often offline) sync — slotted into that order by severity.
/// The dashboard shows every mark at once; a card glyph has room for one, so
/// the most severe wins and the tooltip carries the rest.
enum PlansSyncState: Equatable {
    /// A sync for this project is running right now.
    case syncing
    /// The last sync hit a conflict it could not resolve; the helper aborted the
    /// rebase and auto-sync is backed off until a manual sync.
    case conflict
    /// A rebase was left in progress in the `.plans` worktree.
    case rebaseStuck
    /// The plans branch has no upstream, so there is nothing to sync with.
    case noUpstream
    /// The last sync failed (offline, unreachable remote, missing helper).
    case failed(String)
    /// Local commits not yet pushed and/or upstream commits not yet pulled.
    case aheadBehind(ahead: Int, behind: Int)
    case inSync

    /// The display state, or `nil` when the card shows no sync indicator: any
    /// project not in branch mode, or a branch-mode project whose status has not
    /// been queried yet.
    ///
    /// Priority (highest first): syncing → conflict / rebase stuck → no
    /// upstream → failed → ahead / behind → in sync. A `.locked` outcome only
    /// means another plans-cc commit held the lock, so it is not surfaced.
    static func resolve(
        mode: PlansStorageMode?,
        status: PlansSyncStatus?,
        lastOutcome: PlansGitHelper.SyncOutcome?,
        isSyncing: Bool
    ) -> PlansSyncState? {
        guard mode == .branch, let status else { return nil }
        if isSyncing { return .syncing }
        if status.rebaseStuck { return .rebaseStuck }
        if lastOutcome == .conflict { return .conflict }
        if !status.upstream { return .noUpstream }
        switch lastOutcome {
        case .failed(let message):
            return .failed(message)
        case .helperMissing:
            return .failed("plans-git helper not found at \(PlansGitHelper.defaultHelperPath)")
        case .synced, .locked, .conflict, nil:
            break
        }
        if status.ahead > 0 || status.behind > 0 {
            return .aheadBehind(ahead: status.ahead, behind: status.behind)
        }
        return .inSync
    }

    /// The dashboard-style text mark (`⚠ rebase stuck`, `↑2 ↓1`, `✓`, …).
    var mark: String {
        switch self {
        case .syncing: return "⟳ syncing"
        case .conflict: return "⚠ sync conflict"
        case .rebaseStuck: return "⚠ rebase stuck"
        case .noUpstream: return "⚠ no upstream"
        case .failed: return "⚠ sync failed"
        case .aheadBehind: return countText ?? "✓"
        case .inSync: return "✓"
        }
    }

    /// The `↑n ↓m` counts shown beside the symbol, which alone cannot carry
    /// them. `nil` for every other state.
    var countText: String? {
        guard case .aheadBehind(let ahead, let behind) = self else { return nil }
        var parts: [String] = []
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The SF Symbol for the card footer. Each state gets its own so the glyph
    /// reads without the tooltip.
    var symbolName: String {
        switch self {
        case .syncing: return "arrow.triangle.2.circlepath"
        case .conflict: return "arrow.triangle.merge"
        case .rebaseStuck: return "exclamationmark.triangle.fill"
        case .noUpstream: return "exclamationmark.triangle"
        case .failed: return "icloud.slash"
        case .aheadBehind: return "arrow.up.arrow.down"
        case .inSync: return "checkmark.icloud"
        }
    }

    /// The fill color, from the dashboard palette: `blocked` red for states
    /// that need a hand fix, `dirty` amber for ones that will resolve or just
    /// need attention, `clean` green when in sync, and the neutral `label` tan
    /// while syncing.
    var color: Color {
        switch self {
        case .syncing: return Color(hex: 0xa89984)
        case .conflict, .rebaseStuck: return Color(hex: 0xcc6666)
        case .noUpstream, .failed, .aheadBehind: return Color(hex: 0xfabd2f)
        case .inSync: return Color(hex: 0x8ec07c)
        }
    }

    /// The hover tooltip: a headline for `state`, then the last sync's warnings
    /// (without repeating a failure already in the headline) and any renumbers.
    static func tooltip(
        for state: PlansSyncState,
        status: PlansSyncStatus?,
        lastResult: PlansGitHelper.SyncResult?
    ) -> String {
        let branch = status?.branch ?? "plans"
        let remote = status?.remote ?? "origin"
        var lines: [String] = []
        var headlineWarning: String?

        switch state {
        case .syncing:
            lines.append("Syncing plans with \(remote)/\(branch)…")
        case .conflict:
            lines.append("Plans sync hit a conflict it could not resolve; the rebase was aborted and local plan commits kept.")
            lines.append("Auto-sync is paused for this project until you sync manually.")
        case .rebaseStuck:
            lines.append("A rebase is stuck in .plans. Resolve or abort it there (git -C .plans rebase --abort) before syncing.")
        case .noUpstream:
            lines.append("Plans branch \(branch) has no upstream, so there is nothing to sync.")
        case .failed(let message):
            headlineWarning = message
            lines.append("Plans sync failed: \(message)")
        case .aheadBehind(let ahead, let behind):
            var parts: [String] = []
            if ahead > 0 { parts.append("↑\(ahead) not yet pushed") }
            if behind > 0 { parts.append("↓\(behind) to pull (as of last fetch)") }
            lines.append("Plans branch \(branch) vs \(remote): " + parts.joined(separator: ", "))
        case .inSync:
            lines.append("Plans branch \(branch) is in sync with \(remote).")
        }

        if let lastResult {
            for warning in lastResult.warnings where warning != headlineWarning {
                lines.append("Warning: \(warning)")
            }
            for renumber in lastResult.renumbered {
                lines.append("Renumbered #\(renumber.from) → #\(renumber.to)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
