import XCTest
import CMTP
@testable import KindleDrive

/// Device operations against the in-memory transport. No USB access.
class DeviceOpsTestCase: XCTestCase {
    var t = FakeTransport()
    var storage: UInt32 { t.storageID }
    let status = TransferStatus()
    var temp: URL!

    override func setUpWithError() throws {
        kd_reset_transfer()
        DeviceOps.cleanupRetryDelay = 0
        t = FakeTransport()
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("KindleDriveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDown() {
        kd_reset_transfer()
        try? FileManager.default.removeItem(at: temp)
    }
    /// Creates a local file (in a sub-folder so that several files can share one name).
    func localFile(_ name: String, in folder: String = "a", _ contents: String = "0123456789") throws -> URL {
        let dir = temp.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
    func entry(_ id: UInt32) -> Entry {
        let n = t.nodes[id]!
        return Entry(id: id, name: n.name, size: UInt64(n.data.count), modified: n.modified, folder: n.folder)
    }
    func names(in parent: UInt32 = 0) -> [String] { t.children(of: parent).map(\.name) }
    func message(_ error: Error?) -> String { error?.localizedDescription ?? "" }
}

final class CleanupRuleTests: DeviceOpsTestCase {
    private func action(_ id: UInt32, data: Bool, lookup: (name: String, parent: UInt32)? = nil, listed: Bool = true,
                        sent: String = "Book.epub", dest: UInt32 = 7) -> CleanupAction {
        Device.cleanupAction(itemID: id, dataPhase: data, lookup: lookup, inDestination: listed, sentName: sent, destParent: dest)
    }
    func testCleanupActionTruthTable() {
        // Nothing was created.
        XCTAssertEqual(action(0, data: false), .nothingCreated)
        XCTAssertEqual(action(0, data: true), .nothingCreated)
        // Data phase started: the id is ours, whatever a lookup would say.
        XCTAssertEqual(action(55, data: true), .delete(55))
        XCTAssertEqual(action(0x3000, data: true, lookup: ("Other.epub", 9)), .delete(0x3000))
        // No data phase: only a matching name and parent, present in the destination, is ours.
        XCTAssertEqual(action(55, data: false, lookup: ("Book.epub", 7)), .delete(55))
        XCTAssertEqual(action(0x3000, data: false, lookup: ("Book.epub", 7)), .delete(0x3000))
        XCTAssertEqual(action(55, data: false, lookup: ("Book.epub", 7), listed: false), .leaveUnknown)
        XCTAssertEqual(action(55, data: false, lookup: ("Other.epub", 7)), .leaveNotOurs)
        XCTAssertEqual(action(55, data: false, lookup: ("book.epub", 7)), .leaveNotOurs)
        XCTAssertEqual(action(55, data: false, lookup: ("Book.epub", 8)), .leaveNotOurs)
        XCTAssertEqual(action(0x3000, data: false, lookup: ("Precious.azw3", 7)), .leaveNotOurs)
        // The root is 0 for the app and 0 or 0xFFFFFFFF for the device.
        XCTAssertEqual(action(55, data: false, lookup: ("Book.epub", 0xFFFF_FFFF), dest: 0), .delete(55))
        XCTAssertEqual(action(55, data: false, lookup: ("Book.epub", 0), dest: 0), .delete(55))
        XCTAssertEqual(action(55, data: false, lookup: ("Book.epub", 7), dest: 0), .leaveNotOurs)
        // Unreadable: 0x3000 is only libmtp's object-format code; anything else is unknown.
        XCTAssertEqual(action(0x3000, data: false, lookup: nil), .leaveNotOurs)
        XCTAssertEqual(action(55, data: false, lookup: nil), .leaveUnknown)
        // 0xFFFFFFFF would mean "delete every object": never.
        XCTAssertEqual(action(0xFFFF_FFFF, data: true), .leaveUnknown)
        XCTAssertEqual(action(0xFFFF_FFFF, data: false, lookup: ("Book.epub", 7)), .leaveUnknown)
    }
}

final class UploadTests: DeviceOpsTestCase {
    func testRejectedSendNeverDeletesTheObjectWithID0x3000() throws {
        // The original bug: libmtp leaves 0x3000 as the "item id" of a rejected upload.
        for sameFolder in [false, true] {
            t = FakeTransport()
            let dest = t.addFolder("documents")
            let precious = t.addFile("Precious.azw3", parent: sameFolder ? dest : t.addFolder("other"), id: 0x3000)
            t.sendFailure = { _ in .beforeData(itemID: 0x3000) }
            XCTAssertThrowsError(try DeviceOps.upload([try localFile("New.epub")], storage: storage, parent: dest, status: status, on: t)) {
                XCTAssertFalse(self.message($0).contains("incomplete copy"), self.message($0))
                XCTAssertTrue($0 is DriveError)
            }
            XCTAssertNotNil(t.nodes[precious])
            XCTAssertEqual(t.deleteCalls, [])
        }
    }
    func testRejectedSendLeavesUnreadableAndUnknownIDsAlone() throws {
        let dest = t.addFolder("documents")
        let precious = t.addFile("Precious.azw3", parent: dest, id: 0x3000)
        t.unreadable = [precious]
        t.sendFailure = { _ in .beforeData(itemID: 0x3000) }
        XCTAssertThrowsError(try DeviceOps.upload([try localFile("New.epub")], storage: storage, parent: dest, status: status, on: t)) {
            XCTAssertFalse(self.message($0).contains("incomplete copy"))
        }
        // An id that is not 0x3000 and cannot be read: nothing is deleted, the user is told.
        t.sendFailure = { _ in .beforeData(itemID: 4242) }
        XCTAssertThrowsError(try DeviceOps.upload([try localFile("New.epub")], storage: storage, parent: dest, status: status, on: t)) {
            XCTAssertTrue(self.message($0).contains("An incomplete copy of ‘New.epub’ may remain"), self.message($0))
        }
        // An id that reads back as somebody else's object.
        let other = t.addFile("Other.pdf", parent: dest)
        t.sendFailure = { _ in .beforeData(itemID: other) }
        XCTAssertThrowsError(try DeviceOps.upload([try localFile("New.epub")], storage: storage, parent: dest, status: status, on: t))
        XCTAssertEqual(t.deleteCalls, [])
        XCTAssertEqual(names(in: dest), ["Precious.azw3", "Other.pdf"])
    }
    func testNothingIsLookedUpOrDeletedWhenNoItemIDCameBack() throws {
        t.sendFailure = { _ in .beforeData(itemID: 0) }
        XCTAssertThrowsError(try DeviceOps.upload([try localFile("New.epub")], storage: storage, parent: 0, status: status, on: t))
        XCTAssertEqual(t.lookupCalls, [])
        XCTAssertEqual(t.deleteCalls, [])
    }
    func testFailedMidDataUploadRemovesThePartialCopy() throws {
        let keep = t.addFile("Keep.epub")
        t.sendFailure = { $0 == "Broken.epub" ? .midData : nil }
        let urls = [try localFile("First.epub"), try localFile("Broken.epub"), try localFile("Never.epub")]
        XCTAssertThrowsError(try DeviceOps.upload(urls, storage: storage, parent: 0, status: status, on: t)) {
            XCTAssertTrue(($0 as? DriveError)?.isTransport == true)
            XCTAssertFalse(self.message($0).contains("incomplete copy"))
        }
        XCTAssertEqual(names(), ["Keep.epub", "First.epub"])   // partial removed, batch stopped
        XCTAssertEqual(t.deleteCalls.count, 1)
        XCTAssertNotNil(t.nodes[keep])
        XCTAssertEqual(t.lookupCalls, [])                      // no lookup when the data phase started
    }
    func testCancelledUploadRemovesThePartialCopyAndThrowsCancelled() throws {
        t.sendFailure = { _ in kd_cancel(); return nil }       // the user cancels during the send
        XCTAssertThrowsError(try DeviceOps.upload([try localFile("Big.pdf")], storage: storage, parent: 0, status: status, on: t)) {
            XCTAssertNil(($0 as? Cancelled)?.note)
            XCTAssertEqual(($0 as? Cancelled)?.duringUpload, true)
        }
        XCTAssertEqual(names(), [])
    }
    func testCleanupStopsRetryingWhenTheKindleStoppedResponding() throws {
        t.sendFailure = { _ in self.t.alive = false; return .midData }   // the Kindle dies during the send
        XCTAssertThrowsError(try DeviceOps.upload([try localFile("A.epub")], storage: storage, parent: 0, status: status, on: t)) {
            XCTAssertTrue(self.message($0).contains("An incomplete copy of ‘A.epub’ may remain"), self.message($0))
        }
        XCTAssertEqual(t.deleteCalls.count, 1)   // no retries against a dead device
    }
    func testCleanupRetriesAndReportsACopyThatCannotBeRemoved() throws {
        t.sendFailure = { _ in .midData }
        // First attempt fails, second succeeds.
        var calls = 0
        t.deleteHook = { id in calls += 1; if calls == 1 { self.t.deleteFailsOnce.insert(id) } }
        XCTAssertThrowsError(try DeviceOps.upload([try localFile("A.epub")], storage: storage, parent: 0, status: status, on: t)) {
            XCTAssertFalse(self.message($0).contains("incomplete copy"))
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(names(), [])
        // The delete reports an error but the object is gone: that is a success.
        t.deleteHook = { id in self.t.deleteErrorsButRemoves.insert(id) }
        XCTAssertThrowsError(try DeviceOps.upload([try localFile("B.epub")], storage: storage, parent: 0, status: status, on: t)) {
            XCTAssertFalse(self.message($0).contains("incomplete copy"))
        }
        XCTAssertEqual(names(), [])
        // The delete keeps failing: three attempts, then the user is told, also after a cancel.
        calls = 0
        t.deleteHook = { id in calls += 1; self.t.deleteFails.insert(id) }
        XCTAssertThrowsError(try DeviceOps.upload([try localFile("C.epub")], storage: storage, parent: 0, status: status, on: t)) {
            XCTAssertTrue(self.message($0).contains("An incomplete copy of ‘C.epub’ may remain on the Kindle. Delete it before trying again."), self.message($0))
        }
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(names(), ["C.epub"])
        t.sendFailure = { _ in kd_cancel(); return nil }
        XCTAssertThrowsError(try DeviceOps.upload([try localFile("D.epub")], storage: storage, parent: 0, status: status, on: t)) {
            XCTAssertTrue(($0 as? Cancelled)?.note?.contains("incomplete copy of ‘D.epub’") == true, self.message($0))
        }
    }
    func testBatchNamesAvoidCollisionsAndTheDestinationIsListedOnce() throws {
        let dest = t.addFolder("documents")
        t.addFile("Book.epub", parent: dest)
        let urls = [try localFile("Book.epub", in: "a"), try localFile("book.EPUB", in: "b"), try localFile("Book.epub", in: "c"), try localFile("Other.pdf")]
        let summary = try DeviceOps.upload(urls, storage: storage, parent: dest, status: status, on: t)
        XCTAssertEqual(summary.uploaded, 4)
        XCTAssertEqual(summary.skipped, [])
        XCTAssertEqual(names(in: dest), ["Book.epub", "Book (2).epub", "book (3).EPUB", "Book (4).epub", "Other.pdf"])
        XCTAssertEqual(t.listCalls, [dest])
        XCTAssertEqual(t.childIDCalls, [])
        XCTAssertEqual(status.snapshot, TransferStatus.Snapshot(name: "Other.pdf", index: 4, total: 4))
        XCTAssertEqual(t.node(named: "Other.pdf", in: dest)?.data, Data("0123456789".utf8))
    }
    func testFolderUploadDoesNotListTheFoldersItCreates() throws {
        t.addFolder("Series")
        let folder = temp.appendingPathComponent("Series")
        _ = try localFile("One.epub", in: "Series")
        _ = try localFile("Two.epub", in: "Series/Extras")
        let summary = try DeviceOps.upload([folder], storage: storage, parent: 0, status: status, on: t)
        XCTAssertEqual(summary.uploaded, 2)
        XCTAssertEqual(names(), ["Series", "Series (2)"])
        let created = t.node(named: "Series (2)")!.id
        XCTAssertEqual(names(in: created), ["Extras", "One.epub"])
        XCTAssertEqual(names(in: t.node(named: "Extras", in: created)!.id), ["Two.epub"])
        XCTAssertEqual(t.listCalls, [0])
    }
    func testFolderUploadSkipsJunkAndLinksAndStoresNamesInNFC() throws {
        let folder = temp.appendingPathComponent("Drop")
        for name in ["Book.epub", ".DS_Store", "._Book.epub", ".localized", "a\\b.txt", String(repeating: "x", count: 250), "cafe\u{301}.txt", "zz-last.txt"] {
            _ = try localFile(name, in: "Drop")
        }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.epub"), withDestinationURL: folder.appendingPathComponent("Book.epub"))
        let decomposed = try localFile("re\u{301}sume\u{301}.txt", in: "b")
        XCTAssertEqual(decomposed.lastPathComponent.unicodeScalars.count, 12)   // really NFD
        // Dropped directly (Foundation already hides "._" files when it enumerates a folder).
        let appleDouble = try localFile("._Top.epub", in: "c")
        let summary = try DeviceOps.upload([folder, appleDouble, decomposed], storage: storage, parent: 0, status: status, on: t)
        XCTAssertEqual(summary.uploaded, 4)
        XCTAssertEqual(summary.skipped.count, 6, "\(summary.skipped)")
        for name in [".DS_Store", "._Top.epub", ".localized", "a\\b.txt", "xxxx", "link.epub"] {
            XCTAssertTrue(summary.skipped.contains(where: { $0.hasPrefix(name) }), name)
        }
        let drop = t.node(named: "Drop")!.id
        XCTAssertEqual(Set(names(in: drop)), ["Book.epub", "café.txt", "zz-last.txt"])   // the batch continued
        let stored = names(in: drop).map { Array($0.utf8) } + names().map { Array($0.utf8) }
        XCTAssertTrue(stored.contains(Array("caf\u{e9}.txt".utf8)))
        XCTAssertTrue(stored.contains(Array("r\u{e9}sum\u{e9}.txt".utf8)))
    }
    func testUploadStopsWhenTheKindleIsFull() throws {
        t.capacity = 5
        XCTAssertThrowsError(try DeviceOps.upload([try localFile("Book.epub")], storage: storage, parent: 0, status: status, on: t)) {
            XCTAssertEqual(self.message($0), "There is not enough free space on your Kindle.")
        }
        XCTAssertEqual(names(), [])
    }
    func testCancelBeforeAnItemStopsTheBatchWithCancelled() throws {
        kd_cancel()
        XCTAssertThrowsError(try DeviceOps.upload([try localFile("Book.epub")], storage: storage, parent: 0, status: status, on: t)) {
            XCTAssertEqual(($0 as? Cancelled)?.duringUpload, false)   // no file was in progress
        }
        XCTAssertEqual(names(), [])
    }
}

final class DeleteTests: DeviceOpsTestCase {
    func testAllSelectedItemsAreDeletedAndVerifiedWithOneParentListing() {
        let dest = t.addFolder("documents")
        let a = t.addFile("A.epub", parent: dest), b = t.addFile("B.epub", parent: dest)
        let folder = t.addFolder("Series", parent: dest)
        t.addFile("One.epub", parent: folder)
        let inner = t.addFolder("Extras", parent: folder)
        t.addFile("Two.epub", parent: inner)
        let keep = t.addFile("Keep.epub", parent: dest)
        let selected = [entry(a), entry(folder), entry(b)]
        let outcome = DeviceOps.delete(selected, storage: storage, parent: dest, status: status, on: t)
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.verified, selected)
        XCTAssertEqual(outcome.nestedDeleted, 0)
        XCTAssertEqual(names(in: dest), ["Keep.epub"])
        XCTAssertEqual(t.nodes.count, 2)                                  // documents + Keep.epub
        XCTAssertNotNil(t.nodes[keep])
        XCTAssertEqual(t.listCalls.filter { $0 == dest }.count, 1)
        XCTAssertEqual(t.listCalls.count, 3)                              // Series, Extras, then the parent
        XCTAssertEqual(status.snapshot.total, 3)
    }
    func testCancelInsideAFolderCountsNestedDeletionsAndLeavesTheRest() {
        let folder = t.addFolder("Series")
        for name in ["1", "2", "3"] { t.addFile(name, parent: folder) }
        let later = t.addFile("Later.epub")
        t.deleteHook = { _ in if self.t.deleteCalls.count == 1 { kd_cancel() } }   // cancel during the second delete
        let outcome = DeviceOps.delete([entry(folder), entry(later)], storage: storage, parent: 0, status: status, on: t)
        XCTAssertTrue(outcome.failure is Cancelled)
        XCTAssertEqual(outcome.verified, [])
        XCTAssertEqual(outcome.nestedDeleted, 2)
        XCTAssertEqual(names(in: folder), ["3"])
        XCTAssertEqual(names(), ["Series", "Later.epub"])
    }
    func testCancelBeforeTheBatchDeletesNothing() {
        let a = t.addFile("A.epub")
        kd_cancel()
        let outcome = DeviceOps.delete([entry(a)], storage: storage, parent: 0, status: status, on: t)
        XCTAssertTrue(outcome.failure is Cancelled)
        XCTAssertEqual(outcome.verified, [])
        XCTAssertEqual(t.deleteCalls, [])
    }
    func testFolderWithAnUnreadableChildIsLeftCompletelyUntouched() {
        let folder = t.addFolder("Series")
        let ids = ["1", "2", "3"].map { t.addFile($0, parent: folder) }
        t.unreadable = [ids[1]]
        let later = t.addFile("Later.epub")
        let outcome = DeviceOps.delete([entry(folder), entry(later)], storage: storage, parent: 0, status: status, on: t)
        XCTAssertTrue(message(outcome.failure).contains("‘Series’ contains items that could not be read; it was left in place."), message(outcome.failure))
        XCTAssertEqual(outcome.verified, [])
        XCTAssertEqual(outcome.nestedDeleted, 0)
        XCTAssertEqual(t.deleteCalls, [])
        XCTAssertEqual(t.nodes.count, 5)
    }
    func testFolderThatIsNotEmptyAfterwardsIsNotDeleted() {
        let folder = t.addFolder("Book.sdr")
        let child = t.addFile("sidecar.yjr", parent: folder)
        t.recreateAfterDelete = [child]                         // the Kindle writes it again
        let outcome = DeviceOps.delete([entry(folder)], storage: storage, parent: 0, status: status, on: t)
        XCTAssertTrue(message(outcome.failure).contains("‘Book.sdr’ still contains 1 item(s). Refresh and try again."), message(outcome.failure))
        XCTAssertEqual(outcome.verified, [])
        XCTAssertEqual(outcome.nestedDeleted, 1)
        XCTAssertNotNil(t.nodes[folder])
        XCTAssertFalse(t.deleteCalls.contains(folder))
    }
    func testDeleteThatReportsAnErrorButRemovedTheItemIsVerified() {
        let a = t.addFile("A.epub")
        t.deleteErrorsButRemoves = [a]
        let outcome = DeviceOps.delete([entry(a)], storage: storage, parent: 0, status: status, on: t)
        XCTAssertEqual(outcome.verified.map(\.id), [a])
        XCTAssertNil(outcome.failure)
    }
    func testDeleteThatReportsAnErrorStopsTheBatchEvenIfTheItemIsGone() {
        let a = t.addFile("A.epub"), b = t.addFile("B.epub")
        t.deleteErrorsButRemoves = [a]
        let outcome = DeviceOps.delete([entry(a), entry(b)], storage: storage, parent: 0, status: status, on: t)
        XCTAssertEqual(outcome.verified.map(\.id), [a])
        XCTAssertTrue(message(outcome.failure).contains("remaining 1 item(s) were not deleted"), message(outcome.failure))
        XCTAssertNotNil(t.nodes[b])
    }
    func testDeleteThatReportsSuccessButLeftTheItemIsNotVerified() {
        let a = t.addFile("A.epub"), b = t.addFile("B.epub")
        t.deleteSilentlyKeeps = [a]
        var outcome = DeviceOps.delete([entry(a), entry(b)], storage: storage, parent: 0, status: status, on: t)
        XCTAssertEqual(outcome.verified.map(\.name), ["B.epub"])
        XCTAssertTrue(message(outcome.failure).contains("still lists ‘A.epub’"), message(outcome.failure))
        // Still not verified when the leftover's metadata cannot be read: ids decide.
        t.unreadable = [a]
        let stale = Entry(id: a, name: "A.epub", size: 0, modified: Date(), folder: false)
        outcome = DeviceOps.delete([stale], storage: storage, parent: 0, status: status, on: t)
        XCTAssertEqual(outcome.verified, [])
        XCTAssertTrue(message(outcome.failure).contains("still lists ‘A.epub’"))
    }
    func testRecreatedSameNameItemIsNotVerified() {
        let a = t.addFile("log.tgz")
        t.recreateAfterDelete = [a]
        let outcome = DeviceOps.delete([entry(a)], storage: storage, parent: 0, status: status, on: t)
        XCTAssertEqual(outcome.verified, [])
        XCTAssertTrue(message(outcome.failure).contains("recreated"), message(outcome.failure))
    }
    func testNothingIsVerifiedWhenTheFinalListingFails() {
        let a = t.addFile("A.epub"), b = t.addFile("B.epub")
        t.failNextListing = true                                // files only: the first listing is the final one
        let outcome = DeviceOps.delete([entry(a), entry(b)], storage: storage, parent: 0, status: status, on: t)
        XCTAssertEqual(outcome.verified, [])
        XCTAssertTrue(message(outcome.failure).contains("could not be confirmed"), message(outcome.failure))
        XCTAssertTrue((outcome.failure as? DriveError)?.isTransport == true)
        XCTAssertEqual(t.nodes.count, 0)
    }
    func testErrorMidBatchKeepsEarlierVerifiedAndLaterUntouched() {
        let a = t.addFile("A.epub"), b = t.addFile("B.epub"), c = t.addFile("C.epub")
        t.deleteFails = [b]
        let outcome = DeviceOps.delete([entry(a), entry(b), entry(c)], storage: storage, parent: 0, status: status, on: t)
        XCTAssertEqual(outcome.verified.map(\.id), [a])
        XCTAssertTrue(message(outcome.failure).contains("refused"), message(outcome.failure))
        XCTAssertTrue(message(outcome.failure).contains("still lists ‘B.epub’"), message(outcome.failure))
        XCTAssertEqual(t.deleteCalls, [a, b])
        XCTAssertEqual(names(), ["B.epub", "C.epub"])
        XCTAssertEqual(t.listCalls, [0])
    }
    func testAnEntryWithTheRootIDIsNeverEmptiedOrDeleted() {
        t.addFile("A.epub")
        for id in [UInt32(0), UInt32.max] {
            let bogus = Entry(id: id, name: "bogus", size: 0, modified: Date(), folder: true)
            let outcome = DeviceOps.delete([bogus], storage: storage, parent: 0, status: status, on: t)
            XCTAssertNotNil(outcome.failure)
            XCTAssertEqual(outcome.verified, [])
        }
        XCTAssertEqual(t.deleteCalls, [])
        XCTAssertEqual(names(), ["A.epub"])
    }
}

final class ListingAndFolderTests: DeviceOpsTestCase {
    func testUnreadableChildIsCountedNotFatal() throws {
        let a = t.addFile("A.epub"); t.addFile("B.epub")
        t.unreadable = [a]
        let listing = try t.list(storage: storage, parent: 0)
        XCTAssertEqual(listing.unreadable, 1)
        XCTAssertEqual(listing.ids.count, 2)
        XCTAssertEqual(listing.entries.map(\.name), ["B.epub"])
    }
    func testTransportErrorMakesTheListingThrow() {
        t.addFile("A.epub")
        t.failNextListing = true
        XCTAssertThrowsError(try t.list(storage: storage, parent: 0)) { XCTAssertTrue(($0 as? DriveError)?.isTransport == true) }
    }
    func testCreateFolderAndRenameRejectCollisionsAndBadNames() throws {
        let a = t.addFile("Book.epub")
        XCTAssertThrowsError(try DeviceOps.createFolder("book.EPUB", storage: storage, parent: 0, on: t))
        XCTAssertThrowsError(try DeviceOps.createFolder("a/b", storage: storage, parent: 0, on: t))
        let id = try DeviceOps.createFolder("New", storage: storage, parent: 0, on: t)
        XCTAssertEqual(t.nodes[id]?.folder, true)
        XCTAssertThrowsError(try DeviceOps.rename(entry(id), to: "BOOK.epub", storage: storage, parent: 0, on: t))
        try DeviceOps.rename(entry(a), to: "book.epub", storage: storage, parent: 0, on: t)   // case change of itself
        try DeviceOps.rename(entry(id), to: "Renamed", storage: storage, parent: 0, on: t)
        XCTAssertEqual(names(), ["book.epub", "Renamed"])
    }
    func testConnectReportsTheDeviceAndDistinguishesNoDevice() throws {
        let connection = try DeviceOps.connect(on: FakeTransport.sample())
        XCTAssertEqual(connection.storages.count, 1)
        XCTAssertFalse(connection.deviceInfo.isEmpty)
        XCTAssertLessThan(connection.storages[0].free, connection.storages[0].capacity)
        t.connectFailure = ConnectError(kind: .noDevice, message: "No Kindle was detected.")
        XCTAssertThrowsError(try DeviceOps.connect(on: t)) { XCTAssertEqual(($0 as? ConnectError)?.kind, .noDevice) }
    }
    func testAsyncDeviceWrapperRunsTheSameOperations() async throws {
        let device = Device(transport: FakeTransport.sample())
        let connection = try await device.connect()
        let root = try await device.list(connection.storages[0].id, 0)
        XCTAssertEqual(root.unreadable, 0)
        let fonts = try XCTUnwrap(root.entries.first { $0.name == "fonts" })
        let outcome = await device.delete([fonts], storage: connection.storages[0].id, parent: 0, status: TransferStatus())
        XCTAssertEqual(outcome.verified, [fonts])
        XCTAssertNil(outcome.failure)
        let alive = await device.isAlive()
        XCTAssertTrue(alive)
    }
}

final class DownloadTests: DeviceOpsTestCase {
    func testLocalNameRemovesSeparatorsAndControlCharacters() {
        XCTAssertEqual(Device.localName(for: "Book.epub"), "Book.epub")
        XCTAssertEqual(Device.localName(for: "../../etc/passwd"), ".._.._etc_passwd")
        XCTAssertEqual(Device.localName(for: "a/b:c\\d"), "a_b_c\\d")
        XCTAssertEqual(Device.localName(for: "a\u{0}b\nc\u{7f}"), "a_b_c_")
        XCTAssertEqual(Device.localName(for: ""), "Unnamed")
        XCTAssertEqual(Device.localName(for: "."), "Unnamed")
        XCTAssertEqual(Device.localName(for: ".."), "Unnamed")
        XCTAssertEqual(Device.localName(for: "/"), "_")
        XCTAssertEqual(Device.localName(for: "café 日本語 👨‍👩‍👧.epub"), "café 日本語 👨‍👩‍👧.epub")
        XCTAssertEqual(Device.localName(for: "Book.epub", among: ["book.epub", "book (2).epub"]), "Book (3).epub")
        XCTAssertEqual(Device.localName(for: "Notes", among: ["notes"]), "Notes (2)")
        XCTAssertEqual(Device.localName(for: ".metadata", among: [".metadata"]), ".metadata (2)")
    }
    func testLocalNameFitsLongNamesIn255BytesKeepingTheExtension() {
        let long = String(repeating: "日本語", count: 40) + ".epub"          // 365 bytes
        let first = Device.localName(for: long)
        XCTAssertLessThanOrEqual(first.utf8.count, 255)
        XCTAssertTrue(first.hasSuffix(".epub"))
        XCTAssertTrue(first.hasPrefix("日本語日本語"))
        let second = Device.localName(for: long, among: [first.lowercased()])
        XCTAssertLessThanOrEqual(second.utf8.count, 255)
        XCTAssertTrue(second.hasSuffix(" (2).epub"))
        XCTAssertNotEqual(first.lowercased(), second.lowercased())
        XCTAssertNotNil(String(data: Data(second.utf8), encoding: .utf8))
        XCTAssertFalse(second.unicodeScalars.contains("\u{FFFD}"))
        // Emoji sequences are cut whole, and a name without an extension still fits.
        let emoji = Device.localName(for: String(repeating: "👨‍👩‍👧", count: 30), among: [])
        XCTAssertLessThanOrEqual(emoji.utf8.count, 255)
        XCTAssertEqual(emoji, String(repeating: "👨‍👩‍👧", count: emoji.count))
        XCTAssertEqual(Device.localName(for: String(repeating: "x", count: 300) + ".pdf").utf8.count, 255)
    }
    func testDownloadWritesMode0644AndNeverOverwrites() throws {
        let book = t.addFile("Book.epub", data: Data("from the kindle".utf8))
        let existing = temp.appendingPathComponent("Book.epub")
        try Data("already on the Mac".utf8).write(to: existing)
        try DeviceOps.download([entry(book)], storage: storage, into: temp, status: status, on: t)
        XCTAssertEqual(try Data(contentsOf: existing), Data("already on the Mac".utf8))
        let saved = temp.appendingPathComponent("Book (2).epub")
        XCTAssertEqual(try Data(contentsOf: saved), Data("from the kindle".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o644)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path).sorted(), ["Book (2).epub", "Book.epub"])   // no partial left
    }
    func testDownloadKeepsHostileNamesInsideTheChosenFolder() throws {
        let folder = t.addFolder("../escape")
        t.addFile("/tmp/evil:name", parent: folder, data: Data("x".utf8))
        let into = temp.appendingPathComponent("into")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: false)
        try DeviceOps.download([entry(folder)], storage: storage, into: into, status: status, on: t)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: into.path), [".._escape"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: into.appendingPathComponent(".._escape").path), ["_tmp_evil_name"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), ["into"])
    }
    func testCancelledDownloadThrowsCancelledAndLeavesNothing() throws {
        let book = t.addFile("Book.epub")
        kd_cancel()
        XCTAssertThrowsError(try DeviceOps.download([entry(book)], storage: storage, into: temp, status: status, on: t)) { XCTAssertTrue($0 is Cancelled) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), [])
    }
}
