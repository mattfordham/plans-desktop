import SwiftUI

/// The label shown in the menu bar's icon space (Surface A's `MenuBarExtra`
/// label). Renders the app's `list.bullet` icon followed by a compact,
/// colored-glyph + count summary of work in motion across all projects —
/// in-progress ▶, review ★, in-review ◉ — driven by `store.iconSpaceCounts`
/// (which leads with actively-running work and omits zero-count statuses).
///
/// IMPORTANT (platform limitation): macOS renders a `MenuBarExtra` *label* as a
/// monochrome TEMPLATE image, stripping any `foregroundStyle`/color from the
/// label content (SF Symbols and colored `Text` alike). To preserve the status
/// hues, this view pre-renders the whole colored content (icon + glyph/count
/// HStack) to a bitmap with `ImageRenderer`, then displays it with
/// `.renderingMode(.original)` so macOS does NOT treat it as a template and the
/// colors survive. Rendering everything as a single image also prevents the
/// per-element clipping that was dropping later entries (e.g. the ★ review
/// count) from the label.
///
/// When `iconSpaceCounts` is empty (nothing in progress / review / in-review),
/// only the bare icon is shown. The summary live-updates with the store's 5s
/// poll: `body` reads `store.iconSpaceCounts` (via the content view) on every
/// change, which re-runs the render — `ImageRenderer` itself is not reactive,
/// but `body` re-running re-creates the renderer with fresh content.
struct MenuBarLabel: View {
    @Environment(PlansStore.self) private var store
    // Reading the SwiftUI `\.colorScheme` environment here (not just
    // `NSApp.effectiveAppearance` imperatively) makes `body` a tracked
    // dependency of the system appearance. Toggling dark/light re-runs `body`,
    // which re-creates the `ImageRenderer` with the new scheme so the bitmap is
    // re-baked for the current appearance. `ImageRenderer` is not reactive on
    // its own and bakes colors against whatever environment the content carries,
    // so we must inject this scheme into the rendered content (below).
    @Environment(\.colorScheme) private var colorScheme

    /// Point size for the rendered glyph/count text. The menu bar is ~22pt
    /// tall, so this keeps the content compact while matching system sizing.
    private static let fontSize = NSFont.systemFontSize

    var body: some View {
        // Reading `store.iconSpaceCounts` here (passed into `renderedImage`)
        // tracks the store dependency so `body` re-runs — re-rendering the
        // bitmap — on each 5s poll change. `colorScheme` is likewise read into
        // the render path so appearance changes re-render the bitmap.
        if let nsImage = renderedImage(for: store.iconSpaceCounts,
                                       failedCount: store.failedCount,
                                       colorScheme: colorScheme) {
            // `.renderingMode(.original)` stops macOS from re-tinting the bitmap
            // as a monochrome template, preserving the status colors.
            Image(nsImage: nsImage)
                .renderingMode(.original)
        } else {
            // Should not happen; fall back to the bare icon.
            Image(systemName: "list.bullet")
        }
    }

    /// Pre-renders the colored content (icon + glyph/count HStack) to a bitmap
    /// so the colors survive macOS's monochrome-template treatment of the menu
    /// bar label. Returns `nil` only if `ImageRenderer` fails to produce an
    /// image (not expected).
    ///
    /// `colorScheme` is injected into the rendered content's environment so the
    /// appearance-adaptive label color for the digits bakes correctly for the
    /// current light/dark appearance — the bitmap does not auto-adapt once
    /// rendered.
    private func renderedImage(
        for counts: [(status: TaskStatus, count: Int)],
        failedCount: Int,
        colorScheme: ColorScheme
    ) -> NSImage? {
        let content = MenuBarLabelContent(counts: counts,
                                          failedCount: failedCount,
                                          fontSize: Self.fontSize)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: content)
        // Crisp on Retina: render at the screen's backing scale.
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let nsImage = renderer.nsImage else { return nil }
        // Critical: `MenuBarExtra` re-tints any image flagged as a template to a
        // monochrome system color, which would strip our status hues. Explicitly
        // mark the rendered bitmap as NON-template so the colors are preserved.
        nsImage.isTemplate = false
        return nsImage
    }
}

/// The colored content rendered into the menu bar label bitmap. In the EMPTY
/// state (no counts) it shows only the bare `list.bullet` icon. When there are
/// counts it drops the leading icon and shows, per `iconSpaceCounts` entry, the
/// status's `glanceGlyph` in its `glanceColor` immediately followed by the
/// count, with light padding around the badges (no background). Extracted so it
/// can be fed to `ImageRenderer`.
///
/// Appearance handling: the digit color is an appearance-adaptive semantic
/// color, and the caller injects `\.colorScheme` so it bakes correctly into the
/// (otherwise static) bitmap. The `glanceColor` glyphs are fixed brand hues
/// meant to read vividly in both modes, so they stay as-is.
private struct MenuBarLabelContent: View {
    let counts: [(status: TaskStatus, count: Int)]
    /// The count of FAILED tasks across all projects (#079). Rendered as a
    /// trailing red alarm badge (`⊘N`) after the in-motion status badges, or on
    /// its own when there is no in-motion work. `0` suppresses it.
    let failedCount: Int
    let fontSize: CGFloat

    var body: some View {
        if counts.isEmpty && failedCount == 0 {
            // Empty state: only the bare icon.
            Image(systemName: "list.bullet")
                .font(.system(size: fontSize))
        } else {
            // 10pt between badge groups so ▶3 / ★2 / ◉1 read as clearly separate
            // units, with the glyph↔count spacing inside each group at 4.
            HStack(spacing: 10) {
                ForEach(counts, id: \.status) { entry in
                    HStack(spacing: 4) {
                        Text(entry.status.glanceGlyph)
                            .foregroundStyle(entry.status.glanceColor)
                        Text("\(entry.count)")
                            // Adaptive label color (resolved via the injected
                            // `\.colorScheme`) so digits read in both modes.
                            .foregroundStyle(Color(nsColor: .labelColor))
                    }
                    .font(.system(size: fontSize))
                }
                // #079: the failed badge, using the shared blocked/failure glyph
                // (`⊘`) in the failure color so it matches the failure indicator
                // used everywhere else in the app. Appended after the in-motion
                // status badges (or shown alone when nothing is in motion).
                if failedCount > 0 {
                    HStack(spacing: 4) {
                        Text(TaskStatusIndicator.blockedGlyph)
                            .foregroundStyle(TaskStatusIndicator.failureColor)
                        Text("\(failedCount)")
                            .foregroundStyle(Color(nsColor: .labelColor))
                    }
                    .font(.system(size: fontSize))
                }
            }
            // Padding gives the badges breathing room within the menu bar's
            // icon space (kept after removing the former pill background so the
            // badge spacing is unchanged).
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
        }
    }
}
