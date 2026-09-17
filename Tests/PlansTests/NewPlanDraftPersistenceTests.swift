import XCTest
@testable import Plans

/// Tests for the debounced/coalescing draft-persistence path on `PlansStore`
/// (#052). The bug: every keystroke in the New Plan editor fired
/// `setDraft → captureDrafts.didSet`, which synchronously JSON-encodes the whole
/// draft dictionary and writes it to UserDefaults on the main thread — once per
/// character. These tests drive a debounced API (`setDraftDebounced` +
/// `flushPendingDraft`) that coalesces rapid updates into at most one
/// encode/write per typing pause while still persisting the final value.
///
/// Persistence is observed through the injected, isolated UserDefaults suite:
/// a fresh `PlansStore` over the same defaults reads only what has actually been
/// encoded+written, so an un-fired debounce leaves the prior value in defaults.
final class NewPlanDraftPersistenceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Builds an isolated, empty `UserDefaults` suite so persistence assertions
    /// never touch the real `.standard` defaults (mirrors `PlansStoreTests`).
    private func makeDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Writes an empty `projects.json` registry in the temp dir and returns a
    /// `RegistryReader` pointed at it (mirrors `PlansStoreTests.makeReader`).
    private func makeReader(projectPaths: [String]) throws -> RegistryReader {
        let entries = projectPaths
            .map { #"{ "path": "\#($0)", "lastSeen": "2026-06-04T14:41:00Z" }"# }
            .joined(separator: ",\n")
        let json = """
        {
          "version": 1,
          "projects": [
        \(entries)
          ]
        }
        """
        let registryURL = tempDir.appendingPathComponent("projects.json")
        try json.write(to: registryURL, atomically: true, encoding: .utf8)
        return RegistryReader(registryURL: registryURL)
    }

    // MARK: - Debounce coalescing

    /// Rapid successive debounced updates before the interval elapses must NOT
    /// each force an immediate encode/write: a fresh store over the same defaults
    /// (read before the debounce fires) sees NO persisted draft yet.
    func testRapidDebouncedUpdatesDoNotWriteUntilIntervalElapses() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()
        let store = PlansStore(registryReader: reader, defaults: defaults)

        // Several rapid keystroke-like updates, with a comfortably long interval
        // so the debounce cannot have fired by the time we assert below.
        for i in 0..<5 {
            store.setDraftDebounced(
                PlansStore.CaptureDraft(text: "draft-\(i)", execute: false, elaborate: false),
                for: "/proj",
                interval: 5.0
            )
        }

        // Nothing has been written to defaults yet: a fresh store sees no draft.
        let beforeFlush = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertNil(beforeFlush.draft(for: "/proj"))
    }

    /// After the debounce interval elapses, the FINAL draft value IS persisted
    /// and round-trips through a fresh store over the same defaults — and only
    /// the final value (intermediate updates were coalesced away).
    func testFinalDebouncedValuePersistsAfterIntervalElapses() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()
        let store = PlansStore(registryReader: reader, defaults: defaults)

        for i in 0..<5 {
            store.setDraftDebounced(
                PlansStore.CaptureDraft(text: "draft-\(i)", execute: false, elaborate: false),
                for: "/proj",
                interval: 0.05
            )
        }

        let expectation = expectation(description: "debounce fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Only the final value is persisted.
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        let restored = try XCTUnwrap(reloaded.draft(for: "/proj"))
        XCTAssertEqual(restored.text, "draft-4")
    }

    // MARK: - Synchronous flush

    /// `flushPendingDraft()` applies the pending debounced write immediately and
    /// the value round-trips through a fresh store — no waiting on the timer.
    func testFlushPendingDraftPersistsImmediately() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()
        let store = PlansStore(registryReader: reader, defaults: defaults)

        store.setDraftDebounced(
            PlansStore.CaptureDraft(text: "flushed", execute: true, elaborate: false),
            for: "/proj",
            interval: 5.0
        )
        store.flushPendingDraft()

        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        let restored = try XCTUnwrap(reloaded.draft(for: "/proj"))
        XCTAssertEqual(restored.text, "flushed")
        XCTAssertTrue(restored.execute)
    }

    /// `draft(for:)` reflects the latest pending (not-yet-flushed) value so the
    /// view never reads a stale draft between a keystroke and the debounce fire.
    func testDraftForReflectsPendingValueBeforeFlush() throws {
        let reader = try makeReader(projectPaths: [])
        let store = PlansStore(registryReader: reader, defaults: makeDefaults())

        store.setDraftDebounced(
            PlansStore.CaptureDraft(text: "pending", execute: false, elaborate: true),
            for: "/proj",
            interval: 5.0
        )

        let pending = try XCTUnwrap(store.draft(for: "/proj"))
        XCTAssertEqual(pending.text, "pending")
        XCTAssertTrue(pending.elaborate)
    }

    // MARK: - Cancel pending on clear

    /// A pending debounced write must be cancelled by `clearDraft` so a stale
    /// in-flight write can't resurrect a cleared draft after the timer fires.
    func testClearDraftCancelsPendingDebouncedWrite() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()
        let store = PlansStore(registryReader: reader, defaults: defaults)

        store.setDraftDebounced(
            PlansStore.CaptureDraft(text: "to-be-cleared", execute: false, elaborate: false),
            for: "/proj",
            interval: 0.05
        )
        store.clearDraft(for: "/proj")

        // Even after the debounce interval would have fired, nothing is persisted.
        let expectation = expectation(description: "interval elapses")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertNil(store.draft(for: "/proj"))
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertNil(reloaded.draft(for: "/proj"))
    }

    /// A pending debounced write is also cancelled by a synchronous `setDraft`
    /// so the immediate value wins and isn't later overwritten by a stale timer.
    func testSetDraftCancelsPendingDebouncedWrite() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()
        let store = PlansStore(registryReader: reader, defaults: defaults)

        store.setDraftDebounced(
            PlansStore.CaptureDraft(text: "stale", execute: false, elaborate: false),
            for: "/proj",
            interval: 0.05
        )
        store.setDraft(
            PlansStore.CaptureDraft(text: "authoritative", execute: false, elaborate: false),
            for: "/proj"
        )

        let expectation = expectation(description: "interval elapses")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        let restored = try XCTUnwrap(store.draft(for: "/proj"))
        XCTAssertEqual(restored.text, "authoritative")
    }

    /// Regression for #070: the New Plan sheet "remembers old text after
    /// submission". The view-level defect is that `submit()` clears the draft, but
    /// its `imageData = nil` fires `.onChange(of: imageData) → persistDraft()` on a
    /// LATER runloop turn — AFTER `clearDraft` already ran — re-arming a debounced
    /// write that still carries the old text. The sheet's `.onDisappear` then
    /// `flushPendingDraft()`s, committing that re-armed draft back into the store,
    /// so the next `loadDraft(for:)` restores stale text.
    ///
    /// This pins the store contract the view fix relies on: once a debounced write
    /// is re-armed AFTER `clearDraft`, a `flushPendingDraft()` DOES resurrect it —
    /// so the invariant the view guard must uphold is "do not re-arm a debounced
    /// write during the submit turn". The store itself has no way to distinguish a
    /// legitimate post-clear keystroke from the accidental submit-turn re-arm, so
    /// this test documents the resurrection as EXPECTED store behavior; the fix
    /// lives in `NewPlanModal` (the `isSubmitting` guard).
    func testFlushResurrectsDraftReArmedAfterClear() throws {
        let reader = try makeReader(projectPaths: [])
        let defaults = makeDefaults()
        let store = PlansStore(registryReader: reader, defaults: defaults)

        // 1. A debounced write for the draft the user is submitting.
        store.setDraftDebounced(
            PlansStore.CaptureDraft(text: "submitted text", execute: false, elaborate: false),
            for: "/proj",
            interval: 5.0
        )
        // 2. submit() drops the saved draft (cancels the pending write).
        store.clearDraft(for: "/proj")
        // 3. The accidental `.onChange`-driven re-arm on a later turn, still
        //    carrying the old text (this is exactly what the view guard suppresses).
        store.setDraftDebounced(
            PlansStore.CaptureDraft(text: "submitted text", execute: false, elaborate: false),
            for: "/proj",
            interval: 5.0
        )
        // 4. `.onDisappear` flushes the pending write.
        store.flushPendingDraft()

        // With the re-arm present, the store resurrects the stale draft — this is
        // the resurrection #070 must prevent AT THE VIEW LAYER. If a future store
        // change made the re-arm impossible to observe, this would be nil.
        XCTAssertEqual(store.draft(for: "/proj")?.text, "submitted text")
        let reloaded = PlansStore(registryReader: reader, defaults: defaults)
        XCTAssertEqual(reloaded.draft(for: "/proj")?.text, "submitted text")
    }

    // MARK: - Deep toggle Codable round-trip (#065)

    /// A draft with `deep: true` encodes and decodes back with the flag
    /// preserved — the "Deep" toggle survives dismiss/relaunch alongside the
    /// existing fields. Asserted with a direct `JSONEncoder`/`JSONDecoder`
    /// round-trip on `CaptureDraft` (the precise way to pin the Codable
    /// behavior), and `text` is checked too so the round-trip is proven real.
    func testDeepDraftRoundTripsPreservingDeepTrue() throws {
        let draft = PlansStore.CaptureDraft(
            text: "reasoned plan", execute: false, elaborate: true, deep: true
        )

        let encoded = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(PlansStore.CaptureDraft.self, from: encoded)

        XCTAssertTrue(decoded.deep)
        XCTAssertEqual(decoded.text, "reasoned plan")
        XCTAssertTrue(decoded.elaborate)
    }

    /// The critical backward-compat guarantee: an OLDER draft JSON saved before
    /// #065 (no `deep` key at all) must still decode cleanly, defaulting `deep`
    /// to false. The synthesized `Codable` uses the property-level default for
    /// the absent key rather than throwing, so pre-#065 persisted drafts survive
    /// an app upgrade. `imageData` (`Data?`) is optional and omitted here.
    func testOlderDraftWithoutDeepKeyDecodesAsDeepFalse() throws {
        let legacyJSON = #"{"text":"old draft","execute":false,"elaborate":true}"#

        let decoded = try JSONDecoder().decode(
            PlansStore.CaptureDraft.self, from: Data(legacyJSON.utf8)
        )

        XCTAssertFalse(decoded.deep)
        XCTAssertEqual(decoded.text, "old draft")
        XCTAssertTrue(decoded.elaborate)
    }

    // MARK: - Keep toggle Codable round-trip (#078)

    /// A draft with `keep: true` encodes and decodes back with the flag
    /// preserved — the "Keep" toggle survives dismiss/relaunch alongside the
    /// existing fields. Asserted with a direct `JSONEncoder`/`JSONDecoder`
    /// round-trip on `CaptureDraft` (the precise way to pin the Codable
    /// behavior), and `text` is checked too so the round-trip is proven real.
    func testKeepDraftRoundTripsPreservingKeepTrue() throws {
        let draft = PlansStore.CaptureDraft(
            text: "kept plan", execute: true, elaborate: false, keep: true
        )

        let encoded = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(PlansStore.CaptureDraft.self, from: encoded)

        XCTAssertTrue(decoded.keep)
        XCTAssertEqual(decoded.text, "kept plan")
        XCTAssertTrue(decoded.execute)
    }

    /// The critical backward-compat guarantee: an OLDER draft JSON saved before
    /// #078 (no `keep` key at all) must still decode cleanly, defaulting `keep`
    /// to false. The explicit `init(from:)` uses `decodeIfPresent` for the absent
    /// key rather than throwing, so pre-#078 persisted drafts survive an app
    /// upgrade. `imageData` (`Data?`) is optional and omitted here.
    func testOlderDraftWithoutKeepKeyDecodesAsKeepFalse() throws {
        let legacyJSON = #"{"text":"old draft","execute":true,"elaborate":false}"#

        let decoded = try JSONDecoder().decode(
            PlansStore.CaptureDraft.self, from: Data(legacyJSON.utf8)
        )

        XCTAssertFalse(decoded.keep)
        XCTAssertEqual(decoded.text, "old draft")
        XCTAssertTrue(decoded.execute)
    }

    // MARK: - Multiple image attachments Codable migration (#069)

    /// A draft encoded with the new `imageDatas` array round-trips: the ordered
    /// list of image byte-blobs survives a direct `JSONEncoder`/`JSONDecoder`
    /// pass with its elements and order preserved.
    func testMultipleImageDatasRoundTrip() throws {
        let a = Data([0x89, 0x50, 0x4E, 0x47])
        let b = Data([0x01, 0x02, 0x03])
        let draft = PlansStore.CaptureDraft(
            text: "two images", execute: false, elaborate: false, imageDatas: [a, b]
        )

        let encoded = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(PlansStore.CaptureDraft.self, from: encoded)

        XCTAssertEqual(decoded.imageDatas, [a, b])
        XCTAssertEqual(decoded.text, "two images")
    }

    /// The backward-compat guarantee: an OLDER draft JSON carrying a single
    /// scalar `imageData` key (saved before #069) must decode into a
    /// one-element `imageDatas` array, so a pre-#069 staged image survives an
    /// app upgrade.
    func testLegacySingleImageDataDecodesAsOneElementArray() throws {
        // Base64 of the four PNG-magic bytes 0x89 0x50 0x4E 0x47.
        let legacyBytes = Data([0x89, 0x50, 0x4E, 0x47])
        let base64 = legacyBytes.base64EncodedString()
        let legacyJSON = #"{"text":"old","execute":false,"elaborate":true,"imageData":"\#(base64)"}"#

        let decoded = try JSONDecoder().decode(
            PlansStore.CaptureDraft.self, from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(decoded.imageDatas, [legacyBytes])
        XCTAssertEqual(decoded.text, "old")
    }

    /// A draft JSON with NEITHER `imageDatas` nor legacy `imageData` decodes to
    /// an empty array (the property-level default), so pre-#048 drafts survive.
    func testDraftWithoutAnyImageKeyDecodesAsEmptyArray() throws {
        let legacyJSON = #"{"text":"old draft","execute":false,"elaborate":true}"#

        let decoded = try JSONDecoder().decode(
            PlansStore.CaptureDraft.self, from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(decoded.imageDatas, [])
        XCTAssertEqual(decoded.text, "old draft")
    }
}
