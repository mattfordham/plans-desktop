# Discussion Is Not Allowing Edits To Plans

**ID:** 115
**Created:** 2026-11-10T14:00
**Type:** bug
**Status:** completed
**Completed:** 2026-11-10T14:34
**Branch:** fix/115-discussion-is-not-allowing-edits-to-plans

## What
Discussion is not allowing edits to plans. It should.

A screenshot shows the per-plan Discussion panel refusing to apply an agreed change: the agent replies "this session is read-only by explicit instruction (the task I was given says not to apply any changes to any plan file; plan-discuss can normally apply edits, but this pass must not). So I can't write to the file here." The user had picked "Yes, Option A. Update the plan" but the turn ran through the read-only path, so the agent could only draft the diff instead of applying it.

![pasted image](file://~/Library/Application%20Support/Plans/attachments/543D4509-7C5C-468A-91C3-AFC2AAFD7C6A.png)

## Why
#114 ("Allow Plan Updates Via Discussion", completed 2026-11-10) added an opt-in "Apply changes" discuss action — but it gated the affordance to `pending`/`elaborated` statuses **only**. The plan in the screenshot (`1183-launch-website-fixes-and-production`) is **in-progress** (it shows executing Steps 9/10/11), so `canApplyViaDiscussion` returned false, the "Apply changes" button was never rendered, and the user's only option was the plain read-only Send. The agent then correctly reported it was on the read-only prompt and refused to write.

The reported expectation — "Discussion … should [allow edits to plans]" — is that a user discussing an **active** plan can turn the conversation into an applied edit, not just a drafted diff. The fix broadens the apply gate so discussion can apply changes on the states where a user is most likely reshaping a live plan (`in-progress`, `review`, `in-review`), while keeping the genuinely-unsafe states withheld. The write path, prompt swap, allowlist swap, and reload reconciliation that #114 built are all already correct — only the gating predicate is too narrow.

## How Summary
The entire write-capable discuss path already exists from #114: a `--apply` runner flag that swaps the read-only discuss prompt + allowlist for a write-capable pair, threaded Swift → Node runner, with a `store.reload()` on a clean applying turn. The ONLY reason an in-progress plan can't be edited via discussion is the pure predicate `PlanDetailView.canApplyViaDiscussion(status:isBlocked:isBacklogged:)`, which permits `pending`/`elaborated` only. This change widens that predicate to also permit `in-progress`/`review`/`in-review`, and updates its unit tests to lock in the new matrix. `completed` and `nil` stay withheld (a finished plan has nothing to reshape; an undecodable status is not known-safe), and the cross-cutting `isBlocked`/`isBacklogged` guards are unchanged. No runner, prompt, allowlist, argv, or reload code changes — those already work; the gate was simply too tight.

**Files of note:**
- `Sources/Plans/PlanDetailView.swift` — `canApplyViaDiscussion(status:isBlocked:isBacklogged:)` (~1339–1344): the single predicate to widen. Its doc comment (~1322–1338) also needs updating to describe the new permitted set and the narrowed withhold set. The `discussFooter` composer (~605) and `submitApplyDiscussion` (~703) already read this gate and need no change.
- `Tests/PlansTests/PlanDetailViewTests.swift` — `testCanApplyViaDiscussionOnlyForPendingAndElaborated` (~565), `testCanApplyViaDiscussionFalseWhenBlocked` (~591), `testCanApplyViaDiscussionFalseWhenBacklogged` (~603): the predicate's unit tests. The first test currently asserts `in-progress`/`review`/`in-review` are withheld — it must be rewritten (TDD red) to assert they are now permitted and only `completed`/`nil` are withheld.
- `Tools/work-task/run-task.ts` / `dist/run-task.js` — NO change needed. The apply prompt + write-capable allowlist already fire whenever `--apply` reaches the process; widening the Swift gate simply lets more plans send `--apply`.
- `Sources/Plans/ProjectDiscussionView.swift` — whole-project discuss; out of scope, stays read-only (unchanged, per #114's deliberate narrowing).

## How
- [x] Step 1: **(TDD, red)** Rewrite the apply-gate predicate tests in `Tests/PlansTests/PlanDetailViewTests.swift` to the new matrix. Rename/repurpose `testCanApplyViaDiscussionOnlyForPendingAndElaborated` to assert that `canApplyViaDiscussion` returns **true** for `.pending`, `.elaborated`, `.inProgress`, `.review`, `.inReview` (all with isBlocked/isBacklogged false), and **false** for `.completed` and `nil`. Keep `testCanApplyViaDiscussionFalseWhenBlocked` and `testCanApplyViaDiscussionFalseWhenBacklogged`, extending them to cover the newly-permitted statuses too (e.g. `.inProgress` blocked → false; `.inProgress` backlogged → false) so the cross-cutting guards still win. Run `swift test --filter PlanDetailViewTests` and confirm the rewritten assertions fail (red).
- [x] Step 2: **(green)** Widen `PlanDetailView.canApplyViaDiscussion(status:isBlocked:isBacklogged:)` in `Sources/Plans/PlanDetailView.swift`: keep the leading `guard !isBacklogged` and `guard !isBlocked` early-returns, then return true for `status == .pending || status == .elaborated || status == .inProgress || status == .review || status == .inReview` (equivalently: true for any non-nil status except `.completed`). Leave `completed` and `nil` returning false. Do not touch `canDiscuss`, `canBacklog`, or any other predicate.
- [x] Step 3: Update the `canApplyViaDiscussion` doc comment (~1322–1338) to match: it now permits the active/pre-execution statuses (`pending`/`elaborated`/`in-progress`/`review`/`in-review`) so a user can apply an agreed change to a live plan via discussion, and withholds only `completed` (nothing to reshape — use reopen), `nil` (undecodable, not known-safe), blocked, and backlogged plans. Note the safety rationale shift: an applying turn is still write-capable, but the mutation is a deliberate, explicit second control (not the default Send), and all writes route through `plan-discuss` scoped to the single selected plan — so permitting it on an active plan lets the user reshape work in flight rather than forcing a drop to the CLI.
- [ ] Step 4: Sanity-check the call sites that read the gate need no change: `discussFooter` (~605) renders the Apply button behind `canApply`, and `submitApplyDiscussion` (~703) re-guards with the same predicate — both automatically pick up the widened set. Confirm the whole-project `ProjectDiscussionView` still has no apply path (unchanged, read-only).
- [ ] Step 5: Run `swift build` then `swift test --filter PlanDetailViewTests` (and `swift test --filter TaskRunnerTests` as the apply-flag arg tests are adjacent) — confirm the rewritten gate tests pass green and no existing test regressed. No runner rebuild is needed (no `.ts` change), but verify no other test asserted the old pending/elaborated-only matrix.

## Verification
- `canApplyViaDiscussion` returns true for `pending`, `elaborated`, `in-progress`, `review`, and `in-review` (isBlocked/isBacklogged false), and false for `completed` and `nil`.
- A blocked or backlogged plan still never offers Apply, regardless of status (the cross-cutting guards still win for the newly-permitted statuses).
- `swift test --filter PlanDetailViewTests` passes, including the rewritten apply-gate matrix tests; no existing test regresses.
- In the running app, opening the per-plan Discussion on an **in-progress** plan now shows the "Apply changes" (`square.and.pencil`) control, and using it applies an agreed edit to the plan file (the detail column repaints after the turn), rather than the agent refusing with a read-only message.
- The whole-project Discuss sheet remains read-only (no apply control).

## Impact Scope

### Files to Modify
- [ ] `Sources/Plans/PlanDetailView.swift` — widen `canApplyViaDiscussion` to permit `in-progress`/`review`/`in-review` (plus existing `pending`/`elaborated`); update its doc comment.
- [ ] `Tests/PlansTests/PlanDetailViewTests.swift` — rewrite the apply-gate predicate tests to the new matrix; extend the blocked/backlogged tests to the newly-permitted statuses.

### Related Files (may need updates)
- `Sources/Plans/ProjectDiscussionView.swift` — verify it stays read-only (no apply path); no change intended.
- `Tools/work-task/run-task.ts` / `dist/run-task.js` — no change; the `--apply` prompt/allowlist already fire whenever the flag reaches the process.

### Endpoints/UI Affected
- Per-plan detail column discuss composer (Surface B) — the "Apply changes" control now appears for active plans (`in-progress`/`review`/`in-review`), not just `pending`/`elaborated`.
- Whole-project/backlog discuss sheet (#110) — unchanged, stays read-only.

## Assumptions

### Initial (from elaboration)
- [high] Root cause is the too-narrow `canApplyViaDiscussion` gate from #114, not the runner. **Why:** the screenshot plan is in-progress; #114 completed 2026-11-10 gating the Apply affordance to `pending`/`elaborated` only, so an in-progress plan never renders the Apply button and the read-only Send path produces exactly the "read-only by explicit instruction" refusal shown. The write path, prompt swap, and allowlist swap all already exist and work.
- [high] All writes continue to route through the existing Node runner / `plan-discuss` skill via the already-present `--apply` flag — no Swift-side `.plans/*.md` writer is added and no runner/prompt/allowlist change is made. **Why:** `run-task.ts` is the app's sole `.plans/` writer by firm convention; the apply prompt + write-capable allowlist already fire when `--apply` reaches the process, so widening the Swift gate is sufficient.
- [low] The widened permitted set is `pending`, `elaborated`, `in-progress`, `review`, `in-review`; `completed` and `nil` stay withheld. **Why:** skip-mode scope decision. The reported bug is specifically about an in-progress plan, and `review`/`in-review` are the same "actively being reshaped" category, so permitting all three directly satisfies "Discussion … should allow edits." `completed` is excluded because a finished plan has nothing to reshape (reopen is the path) and `nil` because an undecodable status is not known-safe — mirroring how `canApplyViaDiscussion` already treated `nil`. An alternative narrower fix (permit only `in-progress`) was rejected as leaving the same class of bug for `review`/`in-review`.
- [low] The `isBlocked`/`isBacklogged` cross-cutting guards are kept as leading early-returns and still win for every status. **Why:** skip-mode auto-pick preserving #114's safety reasoning — a blocked plan is waiting on its blocker and a backlogged plan is parked; neither should be rewritten by a single in-app click, regardless of lifecycle status.
- [low] The apply affordance stays an explicit, opt-in SECOND control (the `square.and.pencil` button / `submitApplyDiscussion`), unchanged from #114; the default Send/Return stays strictly read-only. **Why:** skip-mode auto-pick; the fix only widens *which plans* offer the deliberate Apply control, not how it is triggered, so the read-only default and the "a deliberate click is the human gate" pattern are preserved.
- [low] No `**Build:**` route is seeded: the project has no `design-system/` directory, so the des-build routing trigger does not apply. **Why:** this is a Swift app predicate change, not design-system component work.

### Discovered during execution
- [high] Implemented the widened return as an explicit `switch` over `TaskStatus?` (`case .pending, .elaborated, .inProgress, .review, .inReview: true` / `case .completed, nil: false`) rather than `status != nil && status != .completed`. **Why:** the segment prompt called the explicit enumerated form clearest; a `switch` is also exhaustive, so adding a future `TaskStatus` case would force a compile-time decision here instead of silently defaulting to permitted.
- [high] Renamed the repurposed test to `testCanApplyViaDiscussionPermittedForActiveStatuses` and made it loop over the five permitted statuses, asserting false separately for `.completed` and `nil`. Extended the blocked/backlogged tests to loop over all five permitted statuses. **Why:** matches the segment-prompt naming suggestion and proves the cross-cutting guards still win for the newly permitted statuses.

## Changes

### Apply gate widened (`Sources/Plans/PlanDetailView.swift`)
- `canApplyViaDiscussion(status:isBlocked:isBacklogged:)` now permits `.pending`, `.elaborated`, `.inProgress`, `.review`, and `.inReview` — previously only `.pending`/`.elaborated`. It still withholds `.completed` and `nil`, and the leading `isBacklogged`/`isBlocked` guards are unchanged (both still early-return false for any status). Implemented as an exhaustive `switch` over `TaskStatus?` so a future `TaskStatus` case forces a compile-time decision.
- Rewrote the doc comment above the predicate to describe the new permitted set (active + pre-execution statuses) and the narrowed withhold set (`completed`/`nil`/blocked/backlogged), removing the stale "never be reachable from an in-progress / in-review task" claim. The applying turn is still a deliberate, explicit second control routing through `plan-discuss` scoped to the single selected plan.
- No change to `discussFooter`, `submitApplyDiscussion`, the runner, prompts, allowlist, or argv — the write-capable `--apply` path from #114 already works; only the gate was too narrow.

### Tests (`Tests/PlansTests/PlanDetailViewTests.swift`)
- Renamed `testCanApplyViaDiscussionOnlyForPendingAndElaborated` → `testCanApplyViaDiscussionPermittedForActiveStatuses`: asserts true for `.pending`/`.elaborated`/`.inProgress`/`.review`/`.inReview`, false for `.completed` and `nil`.
- Extended `testCanApplyViaDiscussionFalseWhenBlocked` / `testCanApplyViaDiscussionFalseWhenBacklogged` to loop over all five permitted statuses, proving the cross-cutting guards still win.
- TDD: red confirmed (3 failures for in-progress/review/in-review) before the widening, then green — `swift test --filter PlanDetailViewTests` → 71 tests, 0 failures.
