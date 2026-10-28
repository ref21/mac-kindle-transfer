import XCTest
@testable import KindleDrive

final class DeviceTests: XCTestCase {
    func testUnsafeDeviceNamesCannotEscapeDownloadFolder() {
        for name in ["", ".", "..", "../book.epub", "/tmp/book", "a\\b", "a\u{0}b", "a\nb", String(repeating: "x", count: 241)] {
            XCTAssertFalse(Device.validName(name), name)
        }
        for name in ["Book.epub", "café 日本語.epub", ".metadata", "My Books"] { XCTAssertTrue(Device.validName(name)) }
    }
    func testCollisionKeepsExtensionAndFindsUnusedName() {
        XCTAssertEqual(Device.unique("Book.epub", among: ["book.epub", "book (2).epub"]), "Book (3).epub")
        XCTAssertEqual(Device.unique("Books", among: ["books"]), "Books (2)")
        XCTAssertEqual(Device.unique("new.pdf", among: ["other.pdf"]), "new.pdf")
    }
    func testSortingUsesNumericSizeAndRealDatesInBothDirections() {
        let entries = [
            Entry(id: 1, name: "Book 10", size: 20, modified: Date(timeIntervalSince1970: 300), folder: true),
            Entry(id: 2, name: "Book 2", size: 100, modified: Date(timeIntervalSince1970: 100), folder: false),
            Entry(id: 3, name: "Alpha", size: 3, modified: Date(timeIntervalSince1970: 200), folder: true)
        ]
        XCTAssertEqual(entries.sorted(using: KeyPathComparator(\Entry.name, comparator: .localizedStandard)).map(\.id), [3,2,1])
        XCTAssertEqual(entries.sorted(using: KeyPathComparator(\Entry.name, comparator: .localizedStandard, order: .reverse)).map(\.id), [1,2,3])
        XCTAssertEqual(entries.sorted(using: KeyPathComparator(\Entry.size)).map(\.id), [3,1,2])
        XCTAssertEqual(entries.sorted(using: KeyPathComparator(\Entry.size, order: .reverse)).map(\.id), [2,1,3])
        XCTAssertEqual(entries.sorted(using: KeyPathComparator(\Entry.modified)).map(\.id), [2,3,1])
        XCTAssertEqual(entries.sorted(using: KeyPathComparator(\Entry.modified, order: .reverse)).map(\.id), [1,3,2])
    }
    func testDeletionVerificationDetectsRemainingAndRecreatedObjects() {
        let entry = Entry(id: 1, name: "log.tgz", size: 0, modified: Date(), folder: false)
        let recreated = Entry(id: 2, name: entry.name, size: 0, modified: Date(), folder: false)
        XCTAssertNil(Device.deletionIssue(entry, remaining: []))
        XCTAssertNotNil(Device.deletionIssue(entry, remaining: [entry]))
        XCTAssertTrue(Device.deletionIssue(entry, remaining: [recreated])?.contains("recreated") == true)
        XCTAssertNil(Device.deletionIssue(entry, remaining: [Entry(id: 3, name: "other.tgz", size: 0, modified: Date(), folder: false)]))
    }
}
