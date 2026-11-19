import Foundation
import CMTP

/// An in-memory Kindle: used by the unit tests and by the `--demo` launch mode. It never
/// touches USB. Names are case-insensitive within a folder, as the real device is
/// assumed to be. The `fail…`/`…Hook` members inject failures for tests.
final class FakeTransport: Transport {
    struct Node {
        let id: UInt32
        var name: String
        var parent: UInt32      // 0 = storage root
        var folder: Bool
        var data = Data()
        var modified = Date(timeIntervalSince1970: 1_750_000_000)
    }
    enum SendFailure { case beforeData(itemID: UInt32), midData }

    let storageID: UInt32 = 0x0001_0001
    var modelName = "Kindle (demo)"
    var capacity: UInt64 = 8_000_000_000
    private(set) var nodes: [UInt32: Node] = [:]
    private var order: [UInt32] = []    // listing order = creation order
    private var nextID: UInt32 = 100
    private var failure = DriveError(message: "The demo Kindle could not complete the operation.")

    // Failure injection.
    var connectFailure: ConnectError?
    var alive = true
    var unreadable = Set<UInt32>()                       // metadata of these ids cannot be read
    var sendFailure: ((String) -> SendFailure?)?         // by name being sent
    var deleteFails = Set<UInt32>()                      // delete reports an error, object stays
    var deleteFailsOnce = Set<UInt32>()                  // as above, first attempt only
    var deleteErrorsButRemoves = Set<UInt32>()           // delete reports an error, object is removed
    var deleteSilentlyKeeps = Set<UInt32>()              // delete reports success, object stays
    var recreateAfterDelete = Set<UInt32>()              // a same-named object with a new id appears
    var failNextListing = false                          // next childIDs/list throws a transport error
    var delay: TimeInterval = 0                          // per call
    var deleteHook: ((UInt32) -> Void)?                  // called before each delete

    // Call records.
    private(set) var listCalls: [UInt32] = []            // parents passed to list()
    private(set) var childIDCalls: [UInt32] = []         // parents passed to childIDs() directly
    private(set) var deleteCalls: [UInt32] = []
    private(set) var lookupCalls: [UInt32] = []

    // MARK: Building the tree

    @discardableResult func addFolder(_ name: String, parent: UInt32 = 0, id: UInt32? = nil) -> UInt32 {
        insert(Node(id: id ?? newID(), name: name, parent: parent, folder: true))
    }
    @discardableResult func addFile(_ name: String, parent: UInt32 = 0, data: Data = Data("demo".utf8), id: UInt32? = nil) -> UInt32 {
        insert(Node(id: id ?? newID(), name: name, parent: parent, folder: false, data: data))
    }
    func children(of parent: UInt32) -> [Node] { order.compactMap { nodes[$0] }.filter { $0.parent == parent } }
    func node(named name: String, in parent: UInt32 = 0) -> Node? { children(of: parent).first { $0.name == name } }

    /// A small realistic tree.
    static func sample() -> FakeTransport {
        let t = FakeTransport()
        let documents = t.addFolder("documents")
        t.addFile("Pride and Prejudice.azw3", parent: documents, data: Data(count: 612_000))
        t.addFile("The Time Machine.epub", parent: documents, data: Data(count: 284_000))
        t.addFile("Walden.pdf", parent: documents, data: Data(count: 1_930_000))
        let sidecar = t.addFolder("Pride and Prejudice.sdr", parent: documents)
        t.addFile("Pride and Prejudice.azw3f", parent: sidecar, data: Data(count: 2_100))
        let series = t.addFolder("Sherlock Holmes", parent: documents)
        t.addFile("A Study in Scarlet.azw3", parent: series, data: Data(count: 402_000))
        let fonts = t.addFolder("fonts")
        t.addFile("Readme.txt", parent: fonts, data: Data(count: 900))
        let screenshots = t.addFolder("screenshots")
        t.addFile("screenshot_2026_01_05T10_22_31.png", parent: screenshots, data: Data(count: 48_000))
        t.addFile(".metadata", data: Data(count: 120))
        return t
    }

    private func newID() -> UInt32 { defer { nextID += 1 }; return nextID }
    private func insert(_ node: Node) -> UInt32 { nodes[node.id] = node; order.append(node.id); return node.id }
    private func remove(_ id: UInt32) { nodes[id] = nil; order.removeAll { $0 == id } }
    private func pause() { if delay > 0 { Thread.sleep(forTimeInterval: delay) } }
    private func fail(_ message: String, transport: Bool = false) -> DriveError {
        failure = DriveError(message: message, isTransport: transport); return failure
    }
    private func taken(_ name: String, in parent: UInt32, except id: UInt32? = nil) -> Bool {
        children(of: parent).contains { $0.id != id && $0.name.lowercased() == name.lowercased() }
    }
    private var used: UInt64 { nodes.values.reduce(0) { $0 + UInt64($1.data.count) } }

    // MARK: Transport

    func open() throws -> String { pause(); if let connectFailure { throw connectFailure }; return modelName }
    func close() {}
    func isAlive() -> Bool { alive }
    func deviceInfo() -> String { "Demo device (no USB)" }
    func lastFailure() -> DriveError { failure }
    func storages() throws -> [Storage] {
        guard alive else { throw fail("The demo Kindle is not responding.", transport: true) }
        return [Storage(id: storageID, name: "Internal Storage", capacity: capacity, free: capacity - min(capacity, used))]
    }
    private func ids(_ parent: UInt32) throws -> [UInt32] {
        pause()
        if failNextListing || !alive { failNextListing = false; throw fail("PTP Layer error 02ff: could not get object handles.", transport: true) }
        guard parent == 0 || nodes[parent]?.folder == true else { throw fail("The folder no longer exists.") }
        return children(of: parent).map(\.id)
    }
    func childIDs(storage: UInt32, parent: UInt32) throws -> [UInt32] { childIDCalls.append(parent); return try ids(parent) }
    func list(storage: UInt32, parent: UInt32) throws -> Listing {
        listCalls.append(parent)
        let ids = try ids(parent)
        let entries = ids.filter { !unreadable.contains($0) }.compactMap { nodes[$0] }.map {
            Entry(id: $0.id, name: $0.name, size: UInt64($0.data.count), modified: $0.modified, folder: $0.folder)
        }
        return Listing(ids: ids, entries: entries)
    }
    func lookup(id: UInt32) -> (name: String, parent: UInt32)? {
        lookupCalls.append(id)
        guard !unreadable.contains(id), let node = nodes[id] else { return nil }
        return (node.name, node.parent)
    }
    func createFolder(name: String, storage: UInt32, parent: UInt32) throws -> UInt32 {
        pause()
        guard !taken(name, in: parent) else { throw fail("An item with that name already exists.") }
        return addFolder(name, parent: parent)
    }
    func send(path: String, name: String, size: UInt64, storage: UInt32, parent: UInt32) -> SendResult {
        pause()
        // 0x3000 mimics libmtp: a request the device rejects leaves the format code as the id.
        func rejected(_ message: String, itemID: UInt32 = 0x3000) -> SendResult {
            _ = fail(message); return SendResult(status: -1, itemID: itemID, dataPhase: false)
        }
        if case .beforeData(let itemID)? = sendFailure?(name) { return rejected("The Kindle rejected the file.", itemID: itemID) }
        guard let data = FileManager.default.contents(atPath: path) else { return rejected("Could not open source file.", itemID: 0) }
        guard !taken(name, in: parent) else { return rejected("An item with that name already exists.") }
        guard UInt64(data.count) <= capacity - min(capacity, used) else { return rejected("The Kindle is full.") }
        // The object exists from here on; a failure or cancel leaves a partial copy behind.
        let id = addFile(name, parent: parent, data: data.prefix(data.count / 2))
        if case .midData? = sendFailure?(name) {
            _ = fail("PTP Layer error 02ff: Could not send object.", transport: true)
            return SendResult(status: -1, itemID: id, dataPhase: true)
        }
        if kd_cancelled() != 0 {
            _ = fail("Cancelled transfer.")
            return SendResult(status: -1, itemID: id, dataPhase: true)
        }
        nodes[id]?.data = data
        return SendResult(status: 0, itemID: id, dataPhase: true)
    }
    func receive(id: UInt32, toPath: String) throws {
        pause()
        guard let node = nodes[id], !node.folder else { throw fail("The file no longer exists.") }
        if kd_cancelled() != 0 { throw fail("Cancelled transfer.") }
        // libmtp creates downloads with mode 0740.
        guard FileManager.default.createFile(atPath: toPath, contents: node.data, attributes: [.posixPermissions: 0o740]) else {
            throw fail("Could not create the local file.")
        }
    }
    func rename(id: UInt32, to name: String) throws {
        pause()
        guard let node = nodes[id] else { throw fail("The item no longer exists.") }
        guard !taken(name, in: node.parent, except: id) else { throw fail("An item with that name already exists.") }
        nodes[id]?.name = name
    }
    func delete(id: UInt32) throws {
        pause()
        deleteHook?(id)
        deleteCalls.append(id)
        if deleteFails.contains(id) || deleteFailsOnce.remove(id) != nil { throw fail("The Kindle refused to delete the item.") }
        guard let node = nodes[id] else { throw fail("The item no longer exists.") }
        guard children(of: id).isEmpty else { throw fail("The folder is not empty.") }
        if deleteSilentlyKeeps.contains(id) { return }
        remove(id)
        if recreateAfterDelete.contains(id) { _ = insert(Node(id: newID(), name: node.name, parent: node.parent, folder: node.folder)) }
        if deleteErrorsButRemoves.contains(id) { throw fail("The Kindle reported an error.") }
    }
}
