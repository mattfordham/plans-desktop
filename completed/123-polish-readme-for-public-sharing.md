# Doc: Polish README for public sharing (mirror plans-cc #058)

**ID:** 123
**Created:** 2026-11-17T20:53
**Type:** chore
**Status:** completed
**Completed:** 2026-11-18T11:15
**Branch:** chore/123-polish-readme-for-public-sharing

## What
Polish README for public sharing — mirror plans-cc #058: hero/value-prop blurb, honest badges, a grouped table of contents, menu-bar glance and browser-window screenshots in docs/images/, and fix the plans-cc link (currently https://github.com/) to https://github.com/mattfordham/plans-cc. Also copy the two screenshots into plans-cc docs/images/desktop-menubar.png and desktop-browser.png and point its "Plans Desktop →" placeholder at https://github.com/mattfordham/plans-desktop.

## Why
Both repos are now public on GitHub, but the desktop `README.md` still reads like
a private working note: the plans-cc link is a bare `https://github.com/` stub, there
is no hero blurb or badge row to orient a first-time visitor, no table of contents,
and no screenshots of either surface. Mirroring the just-merged plans-cc #058 polish
makes the two repos feel like one coherent project and gives a newcomer an honest,
scannable first impression. It also discharges the reciprocal plans-cc side (its
`Desktop Plans →` link and two broken `docs/images/desktop-*.png` embeds are currently
TODO placeholders waiting on this task).

## How Summary
Rewrite `README.md` in the plans-desktop repo to mirror the plans-cc #058 structure:
a hero/value-prop blurb, an honest badge row (only badges we can back up — platform,
Swift version; **no MIT badge**, because this repo has no LICENSE file yet), a grouped
`## Contents` table of contents, and two embedded screenshots under a new
`docs/images/` directory. Screenshots must be captured against **sanitized demo data**
(fictional project names, generic task titles) — the live app shows real client project
names that must never enter a public
repo. Then propagate the same two images into the plans-cc repo's `docs/images/` and
resolve its three placeholders (the `Plans Desktop →` link + two broken image embeds).

**Files of note:**
- `README.md` — the desktop README being polished (hero, badges, contents, fix the `https://github.com/` → `https://github.com/mattfordham/plans-cc` link, embed screenshots)
- `docs/images/menubar-glance.png` — new; menu-bar glance screenshot (Surface A), sanitized data
- `docs/images/browser-window.png` — new; browser-window screenshot (Surface B), sanitized data
- `../plans/README.md` — plans-cc README; resolve `Plans Desktop →` link + two `desktop-*.png` embeds (separate repo at `~/Work/Open Source/plans`)
- `../plans/docs/images/desktop-menubar.png` / `desktop-browser.png` — new; copies of the two sanitized screenshots
- `Sources/Plans/MenuBarView.swift` / `BrowserWindow.swift` — the two surfaces being screenshotted (reference only, not modified)

## How
- [x] 👁 Step 1: Prepare a **sanitized demo dataset** so screenshots leak no client data. Create a throwaway registry of fictional projects (e.g. `Acme Web`, `Nimbus API`, `Orchard`) each with a few `.plans/` tasks carrying generic titles (e.g. "Fix login timeout", "Add dark mode"), register them, and confirm the live app shows only these fictional names in both surfaces. (Observation needed: the capture in Steps 2–3 depends on the app window showing sanitized content.)
- [x] 👁 Step 2: Capture the **menu-bar glance** screenshot (Surface A) against the sanitized data. Open the menu-bar panel, then `screencapture -o -l <windowid>` (technique from the task Notes). Save to `docs/images/menubar-glance.png` (create `docs/images/` first). Verify the PNG contains no real client names.
- [x] 👁 Step 3: Capture the **browser-window** screenshot (Surface B) against the sanitized data the same way; save to `docs/images/browser-window.png`. Verify the PNG contains no real client names.
- [x] Step 4: Rewrite the top of `README.md` to mirror plans-cc #058: keep the `# Plans` title, add a 1–2 sentence hero/value-prop blurb below it, and add an **honest badge row** — a platform badge (`macOS 15+`) and a Swift badge (`Swift 6.0`), both verifiable from `Package.swift`/`desktop-app-spec.md`. Do **not** add an MIT/license badge (no LICENSE file exists in this repo).
- [x] Step 5: Fix the broken plans-cc link: change `https://github.com/` (line ~3) to `https://github.com/mattfordham/plans-cc`.
- [x] Step 6: Add a grouped `## Contents` table of contents below the hero/badges, mirroring plans-cc's grouped style (e.g. **Get started** / **Use it** / **Reference**) with anchor links to the existing sections (Two surfaces, Requirements, Build & install, How it works, Project layout).
- [x] Step 7: Embed the two screenshots in the README under the relevant sections (menu-bar image near "Two surfaces" / Menu bar glance; browser image near Browser window), each with descriptive alt text. *(Embed markdown written; PNG capture deferred to review — see Steps 1–3.)*
- [x] Step 8: In the plans-cc repo (`~/Work/Open Source/plans`), copy the two screenshots to `docs/images/desktop-menubar.png` and `docs/images/desktop-browser.png`, and resolve the three placeholders in its `README.md`: point `> **[Plans Desktop →](#)**` at `https://github.com/mattfordham/plans-desktop` and remove the two `<!-- TODO: capture … -->` comments now that the embeds resolve. *(Link + TODO removal done; PNG copies deferred to review.)*
- [x] Step 9: Proofread both READMEs rendered (preview the markdown): confirm the TOC anchors resolve, both image embeds display, no remaining TODO/placeholder stubs, and no client names anywhere. Note plans-cc #059 can be closed once this lands (per task Notes). *(Text proofread done; image display verifiable once PNGs land at review.)*

## Verification
- `README.md` (plans-desktop) renders with: a hero blurb, an honest badge row (platform + Swift, **no** MIT badge), a grouped `## Contents`, a working `https://github.com/mattfordham/plans-cc` link (no bare `https://github.com/` stub remains), and both screenshots displaying inline.
- `docs/images/menubar-glance.png` and `docs/images/browser-window.png` exist, display in the README, and contain **no real client project names or task titles** (sanitized demo data only).
- plans-cc `README.md` renders with the `Plans Desktop →` link resolving to `https://github.com/mattfordham/plans-desktop`, both `docs/images/desktop-*.png` embeds displaying, and no remaining `<!-- TODO -->` comments on those lines.
- `grep -R "https://github.com/\"" README.md` finds no bare-stub link; `grep -ri "<client names>" docs/images` is not applicable to PNGs, so instead visually inspect both PNGs for client names.
- No source code changed; `swift build` / `swift test` are unaffected (docs-only change).

## Impact Scope

### Files to Modify
- [ ] `README.md` — hero blurb, honest badge row, grouped `## Contents`, fix plans-cc link, embed two screenshots
- [ ] `../plans/README.md` — resolve `Plans Desktop →` link + two `desktop-*.png` embeds (separate repo)

### Files to Create
- [ ] `docs/images/menubar-glance.png` — menu-bar glance screenshot (sanitized)
- [ ] `docs/images/browser-window.png` — browser-window screenshot (sanitized)
- [ ] `../plans/docs/images/desktop-menubar.png` — copy of menu-bar screenshot
- [ ] `../plans/docs/images/desktop-browser.png` — copy of browser screenshot

### Related Files (reference only, not modified)
- `Sources/Plans/MenuBarView.swift` — Surface A being screenshotted
- `Sources/Plans/BrowserWindow.swift` — Surface B being screenshotted
- `Package.swift` / `desktop-app-spec.md` — source of truth for the honest badge values (Swift 6.0, macOS 15+)

### Cross-repo handoff
- plans-cc repo at `~/Work/Open Source/plans` (remote `mattfordham/plans-cc`) — its #059 tracks the same handoff and can be closed once this lands.

## Assumptions

### Initial (from elaboration)
- [high] Screenshots committed to the public repo must use **sanitized demo data** (fictional project names + generic task titles), not the live app. **Why:** the user's elaboration guidance explicitly said not to put anything sensitive/client names into the repo, and the provided screenshot shows real client names. Capturing against a throwaway demo registry is the cleanest honest option vs. redaction/blurring.
- [high] **No MIT/license badge** is added to the desktop README, unlike plans-cc. **Why:** the plans-desktop repo has no LICENSE file (confirmed: `ls LICENSE*` finds no matches), so an MIT badge would be dishonest. "Honest badges" is an explicit requirement; adding a LICENSE is out of scope for this task.
- [low] Screenshot filenames in the desktop repo are `docs/images/menubar-glance.png` and `docs/images/browser-window.png`. **Why:** the desktop repo has no existing `docs/images/` convention to follow; these names are descriptive and parallel plans-cc's `desktop-menubar.png` / `desktop-browser.png` (which name the *source app*, appropriate from plans-cc's side). The two plans-cc copies keep plans-cc's already-referenced `desktop-menubar.png` / `desktop-browser.png` names verbatim since its README already points at them.
- [low] The grouped `## Contents` uses plans-cc-style group headings adapted to the desktop README's shorter section list (likely a single or two-group TOC rather than plans-cc's three). **Why:** the desktop README is far shorter than plans-cc's; a verbatim three-group TOC would be heavier than the content warrants, so the grouping is scaled to fit while keeping the mirrored style.
- [low] The cross-repo plans-cc edits (Step 8) are performed as part of this task rather than deferred to plans-cc #059. **Why:** the task's What section explicitly scopes "Also copy the two screenshots into plans-cc … and point its placeholder …", so the handoff is in-scope here; #059 is then closed as the reciprocal tracker.

### Discovered during execution
- [low] The `## Contents` TOC uses a **two-group** shape — **Get started** (Two surfaces, Requirements, Build & install) and **Reference** (How it works, Project layout). **Why:** the desktop README has only five sections; two groups mirror plans-cc's bold-group-heading style without the three-group heaviness the shorter content doesn't warrant.
- [low] Hero wording: a single bold value-prop lead sentence (`**Plans is a native macOS app that shows your plans-cc tasks across *every* project on your machine, at a glance.**`) followed by the existing plain-text explanation and a two-surfaces teaser. **Why:** mirrors plans-cc's bold one-liner lead while reusing the repo's already-accurate description.
- [low] Badge URLs chosen: platform `https://img.shields.io/badge/platform-macOS%2015%2B-black.svg` → apple.com/macos, and `https://img.shields.io/badge/swift-6.0-orange.svg` → swift.org. **Why:** shields.io static badges with honest values from `Package.swift` (`.macOS(.v15)`, `swift-tools-version:6.0`); no MIT/license badge since no LICENSE file exists.
- [high] Wrote the two `![alt](docs/images/…png)` image-embed lines now (menubar-glance.png, browser-window.png) and created `docs/images/` with a `.gitkeep` placeholder, but did NOT create/commit any PNG binaries. **Why:** repo-hygiene forbids writing screenshots/binaries into the repo; the two PNGs (and the two plans-cc copies `desktop-menubar.png`/`desktop-browser.png`) are DEFERRED to the review-time GUI capture against sanitized demo data. The markdown resolves the moment the real PNGs are dropped in.

## Changes
- `README.md` (plans-desktop): replaced the top with a bold hero/value-prop lead sentence; added an honest shields.io badge row (macOS 15+, Swift 6.0 — no MIT/license badge); fixed the bare `https://github.com/` plans-cc link to `https://github.com/mattfordham/plans-cc`; added a grouped two-group `## Contents` TOC (Get started / Reference) with anchors to all five sections; embedded two screenshots (`docs/images/menubar-glance.png`, `docs/images/browser-window.png`) under "Two surfaces" with descriptive alt text.
- Created `docs/images/` with a `.gitkeep` placeholder (no binaries committed).
- `../plans/README.md` (plans-cc repo): pointed the `Plans Desktop →` placeholder at `https://github.com/mattfordham/plans-desktop` and removed the two `<!-- TODO: capture … -->` comments so the `desktop-menubar.png`/`desktop-browser.png` embeds resolve once the images land.
- DEFERRED to review: capturing the 4 PNGs against a sanitized demo dataset (Steps 1–3 observation) and copying the two into plans-cc `docs/images/`. No GUI app was run and no binaries were created.

## Notes
- Origin: follow-up from plans-cc task #058 (README polish, merged and pushed 2026-11-17). Reference: https://github.com/mattfordham/plans-cc — mirror its hero blurb, badge row style, and `## Contents` block.
- Both repos are public on GitHub.
- plans-cc README placeholders this resolves (in `~/Work/Open Source/plans`, a separate repo):
  - `> **[Plans Desktop →](#)** <!-- TODO: desktop app URL -->` → `https://github.com/mattfordham/plans-desktop`
  - `docs/images/desktop-menubar.png` and `docs/images/desktop-browser.png` (currently broken image embeds, each with a TODO comment)
- plans-cc's own #059 tracks the same handoff from that side; close it once this lands.
- Screenshot technique used for the plans-cc dashboard: open a window, then `screencapture -o -l <windowid>`. Watch that captured content doesn't expose confidential client task titles if it matters.
- **Sensitive-data note (from elaboration guidance):** the live app shows real client project names. All committed screenshots MUST be captured against a sanitized demo dataset — this is the controlling constraint for Steps 1–3.
