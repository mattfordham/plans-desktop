# Recapture README browser-window screenshot with action buttons

**ID:** 124
**Created:** 2026-11-18T13:13
**Type:** chore
**Status:** completed
**Completed:** 2026-11-18T00:00
**Branch:** chore/124-recapture-readme-browser-window

## What
Recapture the README browser-window screenshot (docs/images/browser-window.png) with an in-review plan selected so the Refine / Execute / Review / Complete… action buttons show. The current shot selects an in-progress plan (Acme Web #001), which by design shows no actions (#027). The mock in-review plan (e.g. Nimbus Api #001 "Rate limiting middleware") must carry a **Branch:** field, since Review and Complete… are gated on a branch (canReview/canComplete in PlanDetailView.swift). The previous demo registry was throwaway and is no longer registered, so the sanitized dataset must be recreated; consider saving it as a reusable script. Also refresh the plans-cc copy at ../plans/docs/images/desktop-browser.png.

## Why
The README's browser-window screenshot is the main picture of Surface B, but it shows an in-progress plan, which by design (#027) shows no header actions. So the app's main workflow buttons (Refine / Execute / Review / Complete…) never appear in the public docs. Keeping the demo dataset in a reusable, gitignored directory means the next screenshot refresh doesn't require rebuilding fictional data from scratch.

## How Summary
Build a sanitized demo dataset (the same fictional projects and tasks as the current screenshot) in a gitignored `demo/` directory, plus a script that temporarily swaps the real plans-cc registry for one pointing at those demo projects and then restores it. With the demo registry active, select the `in-review` Nimbus Api #001 (which carries a `**Branch:**` field so Review and Complete… are enabled), capture the window, and refresh both the desktop and plans-cc copies of the image.

**Files of note:**
- `.gitignore` — add `demo/` so the dataset and scripts stay out of the public repo
- `demo/make-demo.sh` — new (ignored); idempotently writes the fictional projects' `.plans/` trees
- `demo/swap-registry.sh` — new (ignored); `use` backs up and replaces `~/.claude/plans-cc/projects.json`, `restore` puts it back
- `docs/images/browser-window.png` — the recaptured screenshot
- `../plans/docs/images/desktop-browser.png` — plans-cc copy of the same image
- `Sources/Plans/PlanDetailView.swift` — reference only: `canExecuteReview` / `canReview` / `canComplete` gates (Complete… requires `in-review` + non-empty branch)

## How
- [x] Step 1: Add `demo/` to `.gitignore` and confirm `git status` doesn't list anything under it
- [x] Step 2: Write `demo/make-demo.sh`, which (re)creates `demo/projects/{Acme Web,Nimbus Api,Lighthouse Docs,Orchard,Pebble Cli}/.plans/` (a `config.json` plus `pending/` tasks) reproducing the 14 fictional tasks, IDs, types and statuses from the current screenshot. Give Nimbus Api #001 "Rate limiting middleware" `**Status:** in-review` and `**Branch:** plan/001-rate-limiting-middleware`, plus a realistic What/Why/How (some steps checked)/Verification body so the detail pane reads well. Use generic content only, no real names.
- [x] Step 3: Write `demo/swap-registry.sh use|restore`. `use` copies the real `~/.claude/plans-cc/projects.json` to `demo/projects.json.bak` (refusing if a backup already exists, so it can never overwrite one) and writes a registry listing only the demo project paths. `restore` moves the backup back. Print a clear reminder to restore.
- [x] 👁 Step 4: Run `make-demo.sh` and `swap-registry.sh use`, launch Plans (`./build.sh`), and select Nimbus Api #001 in All Plans. Confirm the detail header shows Refine, Execute, Review and Complete…, and that only fictional names appear anywhere in the window. Capture with `screencapture -o -l <windowid>` to `docs/images/browser-window.png`, then run `swap-registry.sh restore` and confirm the real registry is back. (Observation needed: the GUI state and the PNG.)
- [x] Step 5: Copy the new PNG to `../plans/docs/images/desktop-browser.png` (a separate repo, committed there on its own), and check that the README embed at `README.md:30` still resolves (and update its alt text if it now undersells the shot, e.g. mention the action buttons)

## Verification
- `docs/images/browser-window.png` shows an in-review plan whose header displays all four actions: Refine, Execute, Review, Complete…
- The PNG contains only fictional project names and task titles
- `~/.claude/plans-cc/projects.json` matches its pre-swap contents after `restore` (diff against the backup before deleting it)
- `git status` shows no files under `demo/`; only `.gitignore`, the PNG and (optionally) README alt text changed
- The plans-cc copy `../plans/docs/images/desktop-browser.png` matches the desktop image byte for byte

## Impact Scope

### Files to Modify
- [x] `.gitignore` — ignore `demo/`
- [x] `docs/images/browser-window.png` — recaptured screenshot
- [x] `../plans/docs/images/desktop-browser.png` — plans-cc copy
- [x] `README.md` — alt text tweak only, if warranted

### Related Files (may need updates)
- `demo/make-demo.sh`, `demo/swap-registry.sh` — new but gitignored (not committed)
- `Sources/Plans/RegistryReader.swift` — reads the registry only from `~/.claude/plans-cc/projects.json` with no override, which is why a temporary swap is needed

### Endpoints/UI Affected
- None in the app; docs image only

## Assumptions

### Initial (from elaboration)
_To be filled during elaboration_

### Discovered during execution
- [high] Demo project folders use the spaced display names (`demo/projects/Acme Web`, ...). **Why:** the app derives the project name via `lastPathComponent.titleized()`, which leaves "Acme Web" / "Nimbus Api" unchanged, so the sidebar matches the old screenshot.
- [high] All 14 tasks live in `pending/` (no completed tasks); the "Ready for review" rows use `**Status:** review` and the single "In review" row uses `in-review`. **Why:** the old screenshot shows 14 active plans (sidebar counts 4/4/3/2/1) with Review=3 split as 2 ready + 1 in review.
- [high] Each demo project is initialised as its own git repo on `main` (generic "Demo" identity), and Nimbus Api also gets a local `plan/001-rate-limiting-middleware` branch. **Why:** the demo lives inside the plans-desktop checkout, so without this any git lookup (card branch chip, review preflight) would fall through to the parent repo and show its branch.
- [high] `swap-registry.sh restore` copies the backup back, verifies byte-identity with `cmp`, and only then deletes the backup (kept on mismatch). **Why:** matches the Verification step "diff against the backup before deleting it", and the restore can never lose the only copy.
- [low] The browser's `selectedRowID` can be cleared between the user's GUI confirmation and the capture. **Why:** capture attempt 1 showed "No Plan Selected" even though the user had confirmed Nimbus Api #001 was selected. The selection isn't persisted, so it can be dropped, possibly by a refresh or a focus or click change. Confirm the selection immediately before capturing.
- [high] Capture attempt 1 actually failed because two copies of Plans were running at once, and the user had selected the plan in the other copy. With a single Plans process (the fresh build, PID 21050), filtering `CGWindowListCopyWindowInfo` by owner PID + window name "Plans" found the right window (id 108836), and the capture showed the selection. **Why:** before capturing, make sure only one Plans process is running and filter windows by PID, not by name alone.
- [low] Non-featured tasks get short but plausible bodies; review/in-progress ones carry a `**Branch:**`. **Why:** only Nimbus Api #001 is shown in the detail pane; the rest just need correct title/id/type/status.

## Changes
- `.gitignore`: added `demo/` (verified `git status` lists nothing under it; `--ignored` shows `!! demo/`).
- `demo/make-demo.sh` (ignored): idempotently wipes and rewrites `demo/projects/{Acme Web,Nimbus Api,Lighthouse Docs,Orchard,Pebble Cli}/.plans/` (config.json + pending/ tasks), reproducing the 14 fictional tasks from the previous screenshot. Nimbus Api #001 "Rate limiting middleware" is `in-review` with `**Branch:** plan/001-rate-limiting-middleware` and a full What/Why/How (3 of 4 steps checked)/Verification body. Each project is its own git repo on `main`.
- `demo/swap-registry.sh use|restore` (ignored): `use` refuses if `demo/projects.json.bak` exists (or a demo project is missing), backs up `~/.claude/plans-cc/projects.json`, and writes a version-1 registry with the 5 absolute demo paths, then prints a restore reminder; `restore` copies the backup back, `cmp`-verifies it and removes the backup.
- Step 4 prerequisites done: real registry had 20 entries (sha1 2c2d1b0f...) before swap; backup confirmed byte-identical; demo registry active; `./build.sh` launched the fresh build. Browser window id 108808 (the fresh build). Screenshot capture, registry restore and GUI verification still to do.
- Step 4 capture attempt 1 (HEAD dac02b8, branch unchanged before/after): `screencapture -o -l 108808` produced a 3416x2054 PNG, but the detail column showed "No Plan Selected". The selection had been lost after the user confirmed it, so no action buttons were visible. Only fictional names appeared. The bad PNG was moved to scratch and `docs/images/browser-window.png` was reverted to the committed version. The registry was NOT restored: the demo registry is still active (5 entries) and the backup `demo/projects.json.bak` is intact (sha1 2c2d1b0f...). Needed: reselect Nimbus Api #001, then recapture.
- Step 4 capture attempt 2 (HEAD dac02b8 on chore/124-recapture-readme-browser-window, unchanged before and after): single Plans process PID 21050, window id 108836. `screencapture -o -l 108836 docs/images/browser-window.png` gave a 3416x2054 PNG. Visual check passed: Nimbus Api #001 "Rate limiting middleware" (In review, 001 [feature]) is in the detail column with Refine, Execute, Review and Complete… visible, and only fictional names appear (Acme Web, Nimbus Api, Lighthouse Docs, Orchard, Pebble Cli). Ran `demo/swap-registry.sh restore`: the real registry is back (20 entries, sha1 2c2d1b0fea09de787a9e119a021bb5b399463520), it was cmp-verified, and the backup was removed.
- Step 5: copied the PNG to `../plans/docs/images/desktop-browser.png` (`cmp` identical; not committed in plans-cc). README embed still points at `docs/images/browser-window.png`. Alt text tweaked to "Plans browser window — cross-project task list with a selected in-review plan's detail, action buttons, and agent dock".

## Notes
- Risk while the demo registry is active: any other running Claude Code session that calls `plan-touch.js` re-adds its real project to `projects.json`, which would leak a real name into the shot. Close or idle other sessions during capture, and check the sidebar before shooting.
- Agreed in discussion: keep the demo dataset around for future refreshes, in a gitignored directory inside the repo.
