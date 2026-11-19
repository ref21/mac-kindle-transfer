import XCTest
import CMTP
@testable import KindleDrive

/// The model against the in-memory transport. No USB access, no panels or alerts
/// (the model's dialog-free entry points are used: `connect(automatic:)`, `upload(_:)`,
/// `delete(_:)`, `shortcut(_:)`, `chooseStorage(_:)`).
final class BrowserModelTests: XCTestCase {
    @MainActor private func make(_ fake: FakeTransport = .sample()) -> BrowserModel {
        kd_reset_transfer()
        return BrowserModel(device: Device(transport: fake), progress: { 0 })
    }
    @MainActor private func connected(_ fake: FakeTransport) async -> BrowserModel {
        let model = make(fake)
        model.connect(); await model.finished()
        XCTAssertNotNil(model.connection)
        return model
    }
    @MainActor private func open(_ name: String, _ model: BrowserModel) async {
        guard let folder = model.files.first(where: { $0.name == name }) else { return XCTFail("no \(name)") }
        model.navigate(to: folder); await model.finished()
        XCTAssertEqual(model.path.map(\.name), [name])
    }
    override func tearDown() { kd_reset_transfer() }

    @MainActor func testLaunchConnectIsQuietOnlyWhenNoKindleIsAttached() async {
        let fake = FakeTransport.sample()
        fake.connectFailure = ConnectError(kind: .noDevice, message: "No Kindle was detected.")
        let model = make(fake)
        model.connect(automatic: true); await model.finished()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.status, BrowserModel.noKindleStatus)
        XCTAssertNil(model.connection)
        XCTAssertFalse(model.busy)

        model.connect(); await model.finished()          // explicit Connect always alerts
        XCTAssertEqual(model.error, "No Kindle was detected.")

        model.error = nil
        fake.connectFailure = ConnectError(kind: .busy, message: "A Kindle was found but could not be opened.")
        model.connect(automatic: true); await model.finished()   // found but busy: the user must act
        XCTAssertEqual(model.error, "A Kindle was found but could not be opened.")
    }

    @MainActor func testCancelledDeleteIsNotAnError() async {
        let fake = FakeTransport.sample()
        let model = await connected(fake)
        await open("documents", model)
        let books = model.files.filter { !$0.folder }
        XCTAssertEqual(books.count, 3)
        fake.deleteHook = { _ in kd_cancel() }           // cancel while the first item is deleted
        model.delete(books); await model.finished()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.status, "Deleting 3 item(s) — cancelled")
        let entries = model.history.filter { $0.contains("— cancelled") }
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].contains("Stopped. Items already deleted stay deleted."), entries[0])
        XCTAssertTrue(entries[0].contains("1 of 3 selected item(s) deleted"), entries[0])
        XCTAssertFalse(model.history.joined().contains("Completed files have been kept"))
        XCTAssertTrue(model.history.contains { $0.hasSuffix("Deleted and verified: /documents/\(books[0].name)") })
        XCTAssertEqual(model.files.count, 4)             // reloaded after the cancel
    }

    @MainActor func testUploadCancelledMidFileWarnsThatTheKindleMayNeedReconnecting() async throws {
        let fake = FakeTransport.sample()
        let model = await connected(fake)
        let url = try localFiles(["Book.azw3": "data"])[0]
        fake.sendFailure = { _ in kd_cancel(); return nil }   // cancelled during the data phase
        model.upload([url]); await model.finished()
        XCTAssertEqual(model.error, BrowserModel.afterCancelWarning)
        XCTAssertTrue(model.cancelledMidUpload)
        XCTAssertEqual(model.status, "Adding 1 item(s) to / — cancelled")
        let entries = model.history.filter { $0.contains("— cancelled") }
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].contains("Stopped. Files already copied were kept."), entries[0])
        XCTAssertTrue(model.history.contains(BrowserModel.afterCancelWarning))
        XCTAssertNil(fake.node(named: "Book.azw3"))      // the partial copy was removed
    }

    @MainActor func testUploadCancelledBeforeAnyDataIsNotAnError() async throws {
        let fake = FakeTransport.sample()
        let model = await connected(fake)
        let urls = try localFiles(["A.azw3": "a", "B.azw3": "b"])
        // The cancel lands while B is being announced, before any of its data is sent.
        fake.sendFailure = { name in name == "B.azw3" ? { kd_cancel(); return .beforeData(itemID: 0) }() : nil }
        model.upload(urls); await model.finished()
        XCTAssertNil(model.error)
        XCTAssertFalse(model.cancelledMidUpload)
        XCTAssertEqual(model.status, "Adding 2 item(s) to / — cancelled")
        XCTAssertNotNil(fake.node(named: "A.azw3"))
    }

    @MainActor func testTimeoutAfterAMidFileCancelExplainsHowToRecover() async throws {
        let fake = FakeTransport.sample()
        let model = await connected(fake)
        let urls = try localFiles(["Book.azw3": "data", "Next.azw3": "next"])
        fake.sendFailure = { _ in kd_cancel(); return nil }
        model.upload([urls[0]]); await model.finished()
        model.error = nil

        fake.sendFailure = { _ in .timeout }
        model.upload([urls[1]]); await model.finished()
        let error = try XCTUnwrap(model.error)
        XCTAssertTrue(error.hasPrefix(BrowserModel.stalledAfterCancel), error)
        XCTAssertTrue(error.contains("PTP Layer error 02ff"), error)   // details kept
        XCTAssertNotNil(model.connection)                // still connected: not a disconnect
        XCTAssertTrue(model.history.contains(BrowserModel.stalledAfterCancel))

        // Disconnecting clears what the app knows; the next timeout gets the general hint.
        model.disconnect(); await model.finished()
        XCTAssertFalse(model.cancelledMidUpload)
        model.connect(); await model.finished()
        model.error = nil
        model.upload([urls[1]]); await model.finished()
        XCTAssertTrue(model.error?.hasPrefix(BrowserModel.notRespondingHint) == true, model.error ?? "nil")
    }

    @MainActor func testPartialDeleteLogsVerifiedItemsAndReportsTheFailure() async {
        let fake = FakeTransport.sample()
        let model = await connected(fake)
        let metadata = model.files.first { $0.name == ".metadata" }!
        let screenshots = model.files.first { $0.name == "screenshots" }!
        fake.deleteFails = [screenshots.id]              // its contents go, the folder stays
        model.delete([metadata, screenshots]); await model.finished()
        XCTAssertTrue(model.error?.hasPrefix("The Kindle refused to delete the item.") == true, model.error ?? "nil")
        XCTAssertTrue(model.history.contains { $0.hasSuffix("Deleted and verified: /.metadata") }, "\(model.history)")
        XCTAssertFalse(model.history.contains { $0.contains("//") })
        XCTAssertFalse(model.history.contains { $0.contains("verified: /screenshots") })
        XCTAssertTrue(model.history.contains { $0.hasSuffix("Deleted 1 item(s) inside folders that were not fully removed") })
        XCTAssertEqual(model.status, "Deleting 2 item(s) — stopped")
    }

    @MainActor func testFailedLocationChangeKeepsStorageAndPath() async {
        let fake = FakeTransport.sample()
        let model = await connected(fake)
        await open("documents", model)
        let storage = model.storageID, files = model.files.map(\.id)
        let fonts = model.shortcuts.first { $0.name == "fonts" }!

        fake.failNextListing = true
        model.chooseStorage(0x0002_0001); await model.finished()
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.error?.contains(BrowserModel.notRespondingHint) == true)   // listing: no reconnect advice
        model.error = nil
        XCTAssertEqual(model.storageID, storage)
        XCTAssertEqual(model.path.map(\.name), ["documents"])
        XCTAssertEqual(model.files.map(\.id), files)
        XCTAssertNotNil(model.connection)                // alive: not treated as a disconnect

        fake.failNextListing = true
        model.shortcut(fonts); await model.finished()
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.storageID, storage)
        XCTAssertEqual(model.path.map(\.name), ["documents"])
        XCTAssertEqual(model.files.map(\.id), files)

        model.shortcut(fonts); await model.finished()
        XCTAssertEqual(model.path.map(\.name), ["fonts"])
        XCTAssertEqual(model.files.map(\.name), ["Readme.txt"])
    }

    @MainActor func testShortcutsOnlyForKnownRootFoldersThatExist() async {
        let fake = FakeTransport.sample()
        let model = await connected(fake)
        XCTAssertEqual(model.shortcuts.map(\.name), ["documents", "fonts", "screenshots"])
        fake.addFolder("Books")
        fake.addFolder("Random")
        fake.addFile("koreader")                         // a file, not a folder
        fake.addFolder("audible", parent: model.shortcuts[0].id)   // not at the root
        model.refresh(); await model.finished()
        XCTAssertEqual(model.shortcuts.map(\.name), ["documents", "fonts", "screenshots", "Books"])
        let books = model.shortcuts.last!
        model.shortcut(books); await model.finished()
        XCTAssertEqual(model.path.map(\.id), [books.id])
        XCTAssertEqual(model.shortcuts.count, 4)         // kept while inside a folder
    }

    @MainActor func testUploadReportsSkippedItemsAndTheEPUBNoteOnce() async throws {
        let fake = FakeTransport.sample()
        let model = await connected(fake)
        await open("documents", model)
        let freeBefore = model.storage!.free
        let urls = try localFiles(["A.epub": "epub data", "B.EPUB": "more epub", ".DS_Store": "junk", "C.azw3": "azw3 data"])
        model.upload(urls); await model.finished()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.status, "Adding 4 item(s) to /documents — done, 1 skipped")
        XCTAssertTrue(model.history.contains("Skipped: .DS_Store — macOS metadata file"), "\(model.history)")
        XCTAssertEqual(model.history.filter { $0 == BrowserModel.epubNote }.count, 1)
        XCTAssertLessThan(model.storage!.free, freeBefore)   // free space re-read

        let other = try localFiles(["D.pdf": "pdf"], folder: "second")
        model.upload(other); await model.finished()
        XCTAssertEqual(model.status, "Adding 1 item(s) to /documents — done")
        XCTAssertEqual(model.history.filter { $0 == BrowserModel.epubNote }.count, 1)
    }

    func testEPUBDetectionLooksInsideFoldersAndIgnoresSkippedItems() throws {
        let urls = try localFiles(["x.epub": "e", "y.pdf": "p"], folder: "inner")
        let folder = urls[0].deletingLastPathComponent()
        XCTAssertTrue(BrowserModel.includesEPUB([folder], skipped: []))
        XCTAssertFalse(BrowserModel.includesEPUB([urls[1]], skipped: []))
        XCTAssertFalse(BrowserModel.includesEPUB(urls, skipped: ["x.epub — could not be read"]))
    }

    @MainActor func testDeadDeviceSwitchesToDisconnected() async {
        let fake = FakeTransport.sample()
        let model = await connected(fake)
        await open("documents", model)
        fake.alive = false
        model.refresh(); await model.finished()
        XCTAssertNil(model.connection)
        XCTAssertTrue(model.files.isEmpty); XCTAssertTrue(model.path.isEmpty); XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.status, BrowserModel.disconnectedStatus)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.busy)
    }

    @MainActor func testOtherErrorsDoNotDisconnect() async {
        let fake = FakeTransport.sample()
        let model = await connected(fake)
        model.createFolder(named: "documents"); await model.finished()
        XCTAssertEqual(model.error, "That name already exists in this folder.")
        XCTAssertNotNil(model.connection)
    }

    @MainActor func testTypedNamesAreTrimmedAndSelectionSummaryWording() async {
        let fake = FakeTransport.sample()
        let model = await connected(fake)
        model.createFolder(named: "  New Books \n"); await model.finished()
        XCTAssertNotNil(fake.node(named: "New Books"))
        let file = model.files.first { $0.name == ".metadata" }!
        model.rename(file, to: " notes.txt "); await model.finished()
        XCTAssertEqual(fake.nodes[file.id]?.name, "notes.txt")

        model.selection = [file.id]
        XCTAssertEqual(model.selectionSummary, "1 item selected")
        model.selection = Set(model.files.filter { $0.folder }.prefix(2).map(\.id)) .union([file.id])
        XCTAssertEqual(model.selectionSummary, "3 items selected (2 folders)")
        model.selection = Set(model.files.filter(\.folder).prefix(1).map(\.id))
        XCTAssertEqual(model.selectionSummary, "1 item selected (1 folder)")
    }

    @MainActor func testUnreadableItemsAreANoteNotAnError() async {
        let fake = FakeTransport.sample()
        let model = await connected(fake)
        let documents = model.files.first { $0.name == "documents" }!
        fake.unreadable = Set(fake.children(of: documents.id).prefix(2).map(\.id))
        model.navigate(to: documents); await model.finished()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.unreadableNote, "2 items on the Kindle could not be read")
        model.goTo(0); await model.finished()
        XCTAssertNil(model.unreadableNote)
    }

    @MainActor func testIdleHandlersRunWhenTheOperationEnds() async {
        let model = make()
        var calls = 0
        model.whenIdle { calls += 1 }
        XCTAssertEqual(calls, 1)                         // not busy: at once
        model.connect()
        model.whenIdle { calls += 1 }
        XCTAssertEqual(calls, 1)
        await model.finished()
        XCTAssertEqual(calls, 2)
    }

    @MainActor func testActivityIsCappedAt500() {
        let model = make()
        for i in 0..<600 { model.record("line \(i)") }
        XCTAssertEqual(model.history.count, 500)
        XCTAssertEqual(model.history.first, "line 599")
    }

    // MARK: Helpers

    private var temp: URL?
    private func localFiles(_ files: [String: String], folder: String = "upload") throws -> [URL] {
        let root = temp ?? FileManager.default.temporaryDirectory.appendingPathComponent("KindleDriveModelTests-\(UUID().uuidString)")
        temp = root
        let dir = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try files.keys.sorted().map { name in
            let url = dir.appendingPathComponent(name)
            try Data(files[name]!.utf8).write(to: url)
            return url
        }
    }
    override func tearDownWithError() throws {
        if let temp { try? FileManager.default.removeItem(at: temp) }
        temp = nil
    }
}
