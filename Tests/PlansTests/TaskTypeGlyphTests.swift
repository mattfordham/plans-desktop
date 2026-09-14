import XCTest
import SwiftUI
@testable import Plans

/// Tests for the type badge vocabulary on `TaskType`.
///
/// The emoji `glyph` and the `label` are taken VERBATIM from the §6 type table
/// so the desktop badges read identically to the plans-cc convention. The
/// `symbolName` SF Symbols, by contrast, are a curated desktop set (#076) used
/// by controls that must match the AppKit-native chrome — notably the per-card
/// type filter menu, which mirrors the `ProjectViewMode` toolbar select and so
/// needs symbols, not emoji. Each is pinned against its literal here so any
/// drift fails loudly, mirroring `TaskStatusGlanceTests`.
final class TaskTypeGlyphTests: XCTestCase {

    // MARK: - glyph / label (§6 type table — pinned strings)

    func testGlyphsMatchTypeTable() {
        XCTAssertEqual(TaskType.bug.glyph, "🐞")
        XCTAssertEqual(TaskType.feature.glyph, "✨")
        XCTAssertEqual(TaskType.refactor.glyph, "♻️")
        XCTAssertEqual(TaskType.chore.glyph, "🔧")
    }

    func testLabelsMatchTypeTable() {
        XCTAssertEqual(TaskType.bug.label, "bug")
        XCTAssertEqual(TaskType.feature.label, "feature")
        XCTAssertEqual(TaskType.refactor.label, "refactor")
        XCTAssertEqual(TaskType.chore.label, "chore")
    }

    // MARK: - symbolName (curated SF Symbols — pinned strings, #076)

    /// The SF Symbol per type, chosen to parallel the emoji `glyph` metaphors
    /// (ladybug/sparkles/recycle-arrows/wrench) so the two vocabularies read as
    /// the same set in different media.
    func testSymbolNamesMatchExpectedSFSymbols() {
        XCTAssertEqual(TaskType.bug.symbolName, "ladybug.fill")
        XCTAssertEqual(TaskType.feature.symbolName, "sparkles")
        XCTAssertEqual(TaskType.refactor.symbolName, "arrow.triangle.2.circlepath")
        XCTAssertEqual(TaskType.chore.symbolName, "wrench.fill")
    }

    /// Every type maps to a non-empty SF Symbol — totality guard (mirrors
    /// `testSymbolNameTotalAcrossAllCases` for `TaskStatus`).
    func testSymbolNameTotalAcrossAllCases() {
        for type in TaskType.allCases {
            XCTAssertFalse(type.symbolName.isEmpty, "empty symbolName for \(type)")
        }
    }

    /// The symbols are DISTINCT per type — a filter menu showing two identical
    /// icons would be unreadable.
    func testSymbolNamesAreDistinct() {
        let symbols = TaskType.allCases.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count, "duplicate symbolName across types")
    }
}
