# Plans

A native macOS app for viewing your [plans-cc](https://github.com/) tasks across
**every** project on your machine, at a glance.

plans-cc is a lightweight task-management system for Claude Code that stores
tasks as markdown files in a `.plans/` directory at the root of each project. If
you work across many projects, there's no single place to see what's in flight
everywhere — you have to `cd` into each repo individually. **Plans** fixes that.

## Two surfaces

- **Menu bar glance** — a menu bar item showing, per project, a compact
  breakdown of task counts by status. The 20,000-foot view of what's hot right
  now, everywhere, without opening a window.
- **Browser window** — a cross-project window for drilling into a project, plus
  a standalone detail window per plan showing its body and checklist.

## Requirements

- macOS 15 or later
- Swift 6.0 toolchain (Xcode 16+) to build from source

## Build & install

Clone the repo, then:

```bash
# Build and launch from the repo (binary symlinked; for local dev)
./build.sh

# Build and install Plans.app into /Applications (self-contained copy)
./install.sh
```

Install elsewhere with `DEST_DIR=~/Applications ./install.sh`.

Or use Swift Package Manager directly:

```bash
swift build -c release    # produces .build/release/Plans
swift test                # run the test suite
```

## How it works

Plans reads two data contracts produced by plans-cc:

1. **The registry** — the list of project roots you've registered.
2. **The task-file format** — the markdown task files under each project's
   `.plans/` directory.

It polls these on a short interval so both surfaces stay live as you work. See
[`desktop-app-spec.md`](desktop-app-spec.md) for the full specification and the
exact data contracts.

## Project layout

```
Sources/Plans/   # SwiftUI app source (views, store, parsers)
Tests/PlansTests/ # XCTest unit tests
Resources/       # Info.plist, app icon
Tools/           # Icon generation helper
build.sh         # Build + assemble + launch Plans.app
install.sh       # Build + install Plans.app into /Applications
```

Built with SwiftUI and Swift Package Manager — no external dependencies.
