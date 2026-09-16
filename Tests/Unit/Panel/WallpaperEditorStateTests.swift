import XCTest
@testable import MacWallpaperEngine

@MainActor
final class WallpaperEditorStateTests: XCTestCase {
    func testClearingOneFieldAndWallpaperPreservesOtherDrafts() {
        let state = WallpaperEditorState()
        let first = WallpaperEditorState.FieldKey(wallpaperID: "aurora", fieldID: "primary")
        let second = WallpaperEditorState.FieldKey(wallpaperID: "aurora", fieldID: "secondary")
        let other = WallpaperEditorState.FieldKey(wallpaperID: "forest", fieldID: "primary")
        state.setScalingText("1.25", key: first, locale: Locale(identifier: "en_US"))
        state.setScalingText("unfinished", key: second)
        state.setScalingText("2", key: other)
        state.setPropertyText("unsent", key: first)
        state.clearScaling(first)
        XCTAssertEqual(state.propertyTextDrafts[first], "unsent", "Property and display IDs are separate namespaces")
        XCTAssertEqual(state.scalingDrafts[second]?.text, "unfinished")
        XCTAssertTrue(state.hasInvalidScaling(wallpaperID: "aurora"))
        state.discard(wallpaperID: "aurora")
        XCTAssertFalse(state.hasPendingEdits(wallpaperID: "aurora"))
        XCTAssertEqual(state.scalingDrafts[other]?.text, "2")
    }

    func testLocaleParsingAndInvalidInputPreservation() {
        let state = WallpaperEditorState()
        let key = WallpaperEditorState.FieldKey(wallpaperID: "aurora", fieldID: "primary")
        state.setScalingText("1.25", key: key, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(state.scalingDrafts[key]?.value, 1.25)
        state.setScalingText("1,25", key: key, locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(state.scalingDrafts[key]?.value, 1.25)
        for invalid in ["", " ", "0", "-2", "NaN", "Infinity", "1abc"] {
            state.setScalingText(invalid, key: key, locale: Locale(identifier: "en_US"))
            XCTAssertEqual(state.scalingDrafts[key]?.text, invalid)
            XCTAssertNil(state.scalingDrafts[key]?.value)
            XCTAssertTrue(state.hasInvalidScaling(wallpaperID: "aurora"))
        }
    }

    func testOnlyRemovedFieldsLoseDraftsDuringReconciliation() {
        let state = WallpaperEditorState()
        let kept = WallpaperEditorState.FieldKey(wallpaperID: "aurora", fieldID: "kept")
        let changedType = WallpaperEditorState.FieldKey(wallpaperID: "aurora", fieldID: "changed")
        let other = WallpaperEditorState.FieldKey(wallpaperID: "forest", fieldID: "other")
        state.setPropertyText("editing", key: kept)
        state.setPropertyText("old text", key: changedType)
        state.setPropertyText("other editor", key: other)
        state.setScalingText("unfinished", key: kept)
        state.reconcile(wallpaperID: "aurora", textPropertyIDs: ["kept"])
        XCTAssertEqual(state.scalingDrafts[kept]?.text, "unfinished")
        XCTAssertTrue(state.hasInvalidScaling(wallpaperID: "aurora"))
        state.reconcile(wallpaperID: "aurora", displayIDs: [], textPropertyIDs: ["kept"])
        XCTAssertNil(state.scalingDrafts[kept])
        XCTAssertEqual(state.propertyTextDrafts[kept], "editing")
        XCTAssertNil(state.propertyTextDrafts[changedType])
        XCTAssertEqual(state.propertyTextDrafts[other], "other editor")
    }
}
