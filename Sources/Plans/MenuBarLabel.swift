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
        if let nsImage = renderedImage(for: store.iconSpaceCounts, colorScheme: colorScheme) {
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
    /// appearance-adaptive colors (label color for digits, the subtle pill
    /// background) bake correctly for the current light/dark appearance — the
    /// bitmap does not auto-adapt once rendered.
    private func renderedImage(
        for counts: [(status: TaskStatus, count: Int)],
        colorScheme: ColorScheme
    ) -> NSImage? {
        let content = MenuBarLabelContent(counts: counts, fontSize: Self.fontSize)
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
/// count, all sitting inside a subtle rounded pill background. Extracted so it
/// can be fed to `ImageRenderer`.
///
/// Appearance handling: the digit color and the pill background are
/// appearance-adaptive semantic colors, and the caller injects
/// `\.colorScheme` so they bake correctly into the (otherwise static) bitmap.
/// The `glanceColor` glyphs are fixed brand hues meant to read vividly in both
/// modes, so they stay as-is.
private struct MenuBarLabelContent: View {
    let counts: [(status: TaskStatus, count: Int)]
    let fontSize: CGFloat

    var body: some View {
        if counts.isEmpty {
            // Empty state: only the bare icon (no pill).
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
            }
            // Subtle rounded pill behind the badges. Padding gives the content
            // breathing room; the faint primary fill stays low-contrast and
            // follows the injected color scheme.
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
        }
    }
}
