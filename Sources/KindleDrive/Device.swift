import Foundation
import CMTP

struct DriveError: LocalizedError {
    let message: String
    /// The USB link itself failed (I/O error or timeout): the Kindle may be gone.
    var isTransport = false
    init(message: String, isTransport: Bool = false) { self.message = message; self.isTransport = isTransport }
    var errorDescription: String? { message }
}
/// The user cancelled. `note` is set only when something needs their attention, for
/// example an incomplete copy that could not be removed.
struct Cancelled: LocalizedError {
    var note: String?
    /// An upload was stopped partway through a file. The tested Kindle then stops accepting
    /// new items until it is unplugged and plugged back in (README, Known limitations).
    var duringUpload = false
    var errorDescription: String? { "Cancelled. Completed files have been kept." + (note.map { " " + $0 } ?? "") }
}
struct ConnectError: LocalizedError {
    enum Kind: Sendable { case noDevice, busy, storage }
    let kind: Kind
    let message: String
    var errorDescription: String? { message }
}
struct Entry: Identifiable, Hashable, Sendable {
    let id: UInt32
    let name: String
    let size: UInt64
    let modified: Date
    let folder: Bool
}
struct Storage: Identifiable, Hashable, Sendable {
    let id: UInt32
    let name: String
    let capacity: UInt64
    let free: UInt64
}
struct Connection: Sendable { let name: String; let storages: [Storage]; let deviceInfo: String }
struct UploadSummary: Sendable {
    var uploaded = 0             // files sent
    var skipped: [String] = []   // "name — reason" for every item that was not copied
}
struct DeleteOutcome: Sendable {
    var verified: [Entry] = []   // selected items confirmed gone by a fresh device listing
    var nestedDeleted = 0        // items removed inside selected folders that are not in `verified`
    var failure: Error?          // why the batch stopped or could not be confirmed
}

/// What the worker is doing right now. Written by the worker, read by the UI.
final class TransferStatus: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable { var name = ""; var index = 0; var total = 0 }
    private let lock = NSLock()
    private var value = Snapshot()
    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    /// `total` = number of top-level items in the batch.
    func begin(total: Int) { lock.lock(); value = Snapshot(name: "", index: 0, total: total); lock.unlock() }
    /// `index` = 1-based position of the top-level item being worked on.
    func set(name: String, index: Int) { lock.lock(); value.name = name; value.index = index; lock.unlock() }
}

enum CleanupAction: Equatable {
    case nothingCreated      // the failed send created nothing
    case delete(UInt32)      // this id is the object the failed send created: remove it
    case leaveUnknown        // cannot tell; an incomplete copy may remain
    case leaveNotOurs        // the id is not something this send created: do not touch it
}

// Thin async wrapper: every device call hops to one serial queue. The work itself is
// in `DeviceOps`. Only the atomic progress/cancel functions of the C shim may be
// called from another thread.
final class Device: @unchecked Sendable {
    private let queue = DispatchQueue(label: "KindleDrive.USB", qos: .userInitiated)
    private let transport: Transport
    init(transport: Transport = MTPTransport()) { self.transport = transport }

    private func run<T: Sendable>(_ work: @escaping @Sendable (Transport) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work(self.transport) }) }
        }
    }
    func connect() async throws -> Connection { try await run { try DeviceOps.connect(on: $0) } }
    func disconnect() async throws { try await run { $0.close() } }
    func isAlive() async -> Bool { (try? await run { $0.isAlive() }) ?? false }
    func storages() async throws -> [Storage] { try await run { try $0.storages() } }
    func list(_ storage: UInt32, _ parent: UInt32) async throws -> Listing {
        try await run { try $0.list(storage: storage, parent: parent) }
    }
    func createFolder(_ name: String, _ storage: UInt32, _ parent: UInt32) async throws {
        try await run { _ = try DeviceOps.createFolder(name, storage: storage, parent: parent, on: $0) }
    }
    func rename(_ entry: Entry, to name: String, storage: UInt32, parent: UInt32) async throws {
        try await run { try DeviceOps.rename(entry, to: name, storage: storage, parent: parent, on: $0) }
    }
    func upload(_ urls: [URL], storage: UInt32, parent: UInt32, status: TransferStatus) async throws -> UploadSummary {
        try await run { try DeviceOps.upload(urls, storage: storage, parent: parent, status: status, on: $0) }
    }
    func download(_ entries: [Entry], storage: UInt32, into directory: URL, status: TransferStatus) async throws {
        try await run { try DeviceOps.download(entries, storage: storage, into: directory, status: status, on: $0) }
    }
    /// `entries` must be siblings inside `parent`. Never throws: see `DeleteOutcome`.
    func delete(_ entries: [Entry], storage: UInt32, parent: UInt32, status: TransferStatus) async -> DeleteOutcome {
        do { return try await run { DeviceOps.delete(entries, storage: storage, parent: parent, status: status, on: $0) } }
        catch { return DeleteOutcome(failure: error) }   // unreachable: the work does not throw
    }

    // MARK: Pure helpers

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") &&
        !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && name.utf8.count <= 240
    }
    static func requireName(_ name: String) throws {
        guard validName(name) else { throw DriveError(message: "Use a name of 1–240 bytes without slashes or control characters.") }
    }
    static func unique(_ name: String, among names: Set<String>) -> String {
        if !names.contains(name.lowercased()) { return name }
        let u = URL(fileURLWithPath: name)
        let ext = u.pathExtension
        let base = ext.isEmpty ? name : u.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let candidate = "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            if !names.contains(candidate.lowercased()) { return candidate }; n += 1
        }
    }
    static func deletionIssue(_ entry: Entry, remaining: [Entry]) -> String? {
        if remaining.contains(where: { $0.id == entry.id }) {
            return "The Kindle still lists ‘\(entry.name)’ after the delete request. Deletion was not confirmed. Refresh and try again."
        }
        if remaining.contains(where: { $0.name == entry.name }) {
            return "A new item named ‘\(entry.name)’ appeared after deletion. The Kindle may have recreated it. Refresh before trying again."
        }
        return nil
    }
    /// A safe name for a Kindle item saved on the Mac: no path separators or control
    /// characters, never `.`/`..`, not in `names` (lower-cased names already in the
    /// folder), and at most 255 UTF-8 bytes including the " (n)" suffix and the extension.
    static func localName(for name: String, among names: Set<String> = []) -> String {
        var scalars = String.UnicodeScalarView()
        for u in name.unicodeScalars {
            scalars.append(u == "/" || u == ":" || u.properties.generalCategory == .control ? "_" : u)
        }
        var clean = String(scalars)
        if clean.isEmpty || clean == "." || clean == ".." { clean = "Unnamed" }
        var base = clean, ext = ""
        if let dot = clean.lastIndex(of: "."), dot != clean.startIndex {
            let tail = String(clean[dot...])
            if tail.utf8.count > 1 && tail.utf8.count <= 33 { base = String(clean[..<dot]); ext = tail }
        }
        var n = 1
        while true {
            let suffix = (n == 1 ? "" : " (\(n))") + ext
            var fitted = base
            while fitted.utf8.count + suffix.utf8.count > 255 { fitted.removeLast() }   // whole Characters
            let candidate = fitted + suffix
            if !names.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }
    static func isJunk(_ name: String) -> Bool { name == ".DS_Store" || name == ".localized" || name.hasPrefix("._") }

    /// Decides what may be removed after a failed send. This is the only rule by which an
    /// upload may delete anything.
    /// - `itemID`, `dataPhase`: from `SendResult`.
    /// - `lookup`: the device's metadata for `itemID` (consulted only when `dataPhase` is false).
    /// - `inDestination`: `itemID` is in a fresh id listing of the destination folder
    ///   (consulted only when the lookup matches).
    static func cleanupAction(itemID: UInt32, dataPhase: Bool, lookup: (name: String, parent: UInt32)?,
                              inDestination: Bool, sentName: String, destParent: UInt32) -> CleanupAction {
        if itemID == 0 { return .nothingCreated }
        // Not an object handle: in MTP, DeleteObject(0xFFFFFFFF) means "delete everything".
        if itemID == UInt32.max { return .leaveUnknown }
        // The progress callback only runs after the device has created the object, so the
        // id is the one this send was given.
        if dataPhase { return .delete(itemID) }
        // No data was sent. The id may be the new object, or just a value libmtp left
        // behind (0x3000, the object-format code, when the device rejected the request).
        guard let lookup else { return itemID == 0x3000 ? .leaveNotOurs : .leaveUnknown }
        func root(_ id: UInt32) -> UInt32 { id == UInt32.max ? 0 : id }
        guard lookup.name == sentName, root(lookup.parent) == root(destParent) else { return .leaveNotOurs }
        return inDestination ? .delete(itemID) : .leaveUnknown
    }
}

/// The device operations: synchronous functions over a `Transport`, called from one
/// thread at a time (the USB queue, the smoke test, or a unit test).
enum DeviceOps {
    /// Pause between attempts to remove an incomplete upload. Changed only by unit tests.
    nonisolated(unsafe) static var cleanupRetryDelay: TimeInterval = 0.2

    static func checkCancel() throws { if kd_cancelled() != 0 { throw Cancelled() } }

    static func connect(on t: Transport) throws -> Connection {
        let name = try t.open()
        do { return Connection(name: name, storages: try t.storages(), deviceInfo: t.deviceInfo()) }
        catch { t.close(); throw error }
    }
    static func createFolder(_ name: String, storage: UInt32, parent: UInt32, on t: Transport) throws -> UInt32 {
        try Device.requireName(name)
        let existing = try t.list(storage: storage, parent: parent).entries
        guard !existing.contains(where: { $0.name.lowercased() == name.lowercased() }) else { throw DriveError(message: "That name already exists in this folder.") }
        return try t.createFolder(name: name, storage: storage, parent: parent)
    }
    static func rename(_ entry: Entry, to name: String, storage: UInt32, parent: UInt32, on t: Transport) throws {
        try Device.requireName(name)
        let existing = try t.list(storage: storage, parent: parent).entries
        guard !existing.contains(where: { $0.id != entry.id && $0.name.lowercased() == name.lowercased() }) else { throw DriveError(message: "That name already exists.") }
        try t.rename(id: entry.id, to: name)
    }

    // MARK: Upload

    static func upload(_ urls: [URL], storage: UInt32, parent: UInt32, status: TransferStatus, on t: Transport) throws -> UploadSummary {
        var summary = UploadSummary()
        status.begin(total: urls.count)
        // One listing of the destination; the name set is then kept up to date locally.
        var names = Set(try t.list(storage: storage, parent: parent).entries.map { $0.name.lowercased() })
        for (index, url) in urls.enumerated() {
            try uploadItem(url, storage, parent, &names, &summary, status, index + 1, t)
        }
        return summary
    }
    private static func uploadItem(_ url: URL, _ storage: UInt32, _ parent: UInt32, _ names: inout Set<String>,
                                   _ summary: inout UploadSummary, _ status: TransferStatus, _ index: Int, _ t: Transport) throws {
        try checkCancel()
        let original = url.lastPathComponent
        status.set(name: original, index: index)
        func skip(_ reason: String) { summary.skipped.append("\(original) — \(reason)") }
        if Device.isJunk(original) { return skip("macOS metadata file") }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey]) else { return skip("could not be read") }
        if values.isSymbolicLink == true { return skip("symbolic link") }
        guard values.isDirectory == true || values.isRegularFile == true else { return skip("not a regular file or folder") }
        let normalised = original.precomposedStringWithCanonicalMapping   // NFC
        guard Device.validName(normalised) else { return skip("name cannot be used on the Kindle") }
        let name = Device.unique(normalised, among: names)
        guard Device.validName(name) else { return skip("name is too long") }
        if values.isDirectory == true {
            guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return skip("could not be read") }
            names.insert(name.lowercased())
            let id = try t.createFolder(name: name, storage: storage, parent: parent)
            var childNames = Set<String>()   // a folder we just created is empty
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try uploadItem(child, storage, id, &childNames, &summary, status, index, t)
            }
        } else {
            let size = UInt64(values.fileSize ?? 0)
            guard size < 4 * 1024 * 1024 * 1024 else { return skip("4 GB or larger") }
            guard FileManager.default.isReadableFile(atPath: url.path) else { return skip("could not be read") }
            if let s = try t.storages().first(where: { $0.id == storage }), s.free < size {
                throw DriveError(message: "There is not enough free space on your Kindle.")
            }
            names.insert(name.lowercased())
            let result = t.send(path: url.path, name: name, size: size, storage: storage, parent: parent)
            guard result.status != 0 else { summary.uploaded += 1; return }
            let cancelled = kd_cancelled() != 0
            let failure = t.lastFailure()   // read before the cleanup calls replace it
            let note = cleanUpFailedSend(result, name: name, storage: storage, parent: parent, on: t)
            // libmtp cancels only from the progress callback, i.e. during the data phase.
            if cancelled { throw Cancelled(note: note, duringUpload: result.dataPhase) }
            throw DriveError(message: failure.message + (note.map { " " + $0 } ?? ""), isTransport: failure.isTransport)
        }
    }
    /// Removes what a failed send left behind, if and only if `Device.cleanupAction` says
    /// the id is ours. Returns a note for the user when an incomplete copy may remain.
    static func cleanUpFailedSend(_ result: SendResult, name: String, storage: UInt32, parent: UInt32, on t: Transport) -> String? {
        var lookup: (name: String, parent: UInt32)? = nil
        var inDestination = false
        if result.itemID != 0 && !result.dataPhase {
            lookup = t.lookup(id: result.itemID)
            if lookup != nil { inDestination = ((try? t.childIDs(storage: storage, parent: parent)) ?? []).contains(result.itemID) }
        }
        let mayRemain = "An incomplete copy of ‘\(name)’ may remain on the Kindle. Delete it before trying again."
        switch Device.cleanupAction(itemID: result.itemID, dataPhase: result.dataPhase, lookup: lookup,
                                    inDestination: inDestination, sentName: name, destParent: parent) {
        case .nothingCreated, .leaveNotOurs: return nil
        case .leaveUnknown: return mayRemain
        case .delete(let id):
            for attempt in 0..<3 {
                if attempt > 0 { Thread.sleep(forTimeInterval: cleanupRetryDelay) }
                if (try? t.delete(id: id)) != nil { return nil }
                // A Kindle that stopped responding will not answer a retry either: each try
                // would only wait out USB timeouts.
                if t.lastFailure().isTransport && !t.isAlive() { return mayRemain }
                // The delete reported an error; it still counts if the object is gone.
                if let ids = try? t.childIDs(storage: storage, parent: parent), !ids.contains(id) { return nil }
            }
            return mayRemain
        }
    }

    // MARK: Download

    static func download(_ entries: [Entry], storage: UInt32, into directory: URL, status: TransferStatus, on t: Transport) throws {
        status.begin(total: entries.count)
        for (index, entry) in entries.enumerated() {
            try downloadItem(entry, storage, directory, status, index + 1, t)
        }
    }
    private static func downloadItem(_ entry: Entry, _ storage: UInt32, _ directory: URL, _ status: TransferStatus, _ index: Int, _ t: Transport) throws {
        try checkCancel()
        status.set(name: entry.name, index: index)
        let fm = FileManager.default
        let names = Set(try fm.contentsOfDirectory(atPath: directory.path).map { $0.lowercased() })
        let target = directory.appendingPathComponent(Device.localName(for: entry.name, among: names))
        if entry.folder {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            for child in try t.list(storage: storage, parent: entry.id).entries {
                try downloadItem(child, storage, target, status, index, t)
            }
        } else {
            // Download beside the destination, then commit it atomically only on success.
            let partial = directory.appendingPathComponent(".kindledrive-\(UUID().uuidString).partial")
            defer { try? fm.removeItem(at: partial) }
            do { try t.receive(id: entry.id, toPath: partial.path) }
            catch { try checkCancel(); throw error }
            let attrs = try fm.attributesOfItem(atPath: partial.path)
            guard (attrs[.size] as? NSNumber)?.uint64Value == entry.size else { throw DriveError(message: "Download size did not match. The incomplete copy was removed.") }
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: partial.path)   // libmtp creates it 0740
            try fm.moveItem(at: partial, to: target)   // fails rather than overwrite
        }
    }

    // MARK: Delete

    /// Deletes `entries` (siblings inside `parent`), stops at the first error or cancel,
    /// and always finishes with one fresh listing of `parent` to classify what was done.
    /// The only ids ever deleted are those of `entries` and of children listed, during
    /// this call, inside folders being deleted.
    static func delete(_ entries: [Entry], storage: UInt32, parent: UInt32, status: TransferStatus, on t: Transport) -> DeleteOutcome {
        var outcome = DeleteOutcome()
        var issued: [Entry] = []            // entries for which a delete request was sent
        var nested: [UInt32: Int] = [:]     // per entry: items removed inside it
        var failure: Error?
        var failedDelete: Entry?            // the entry whose own delete request reported an error
        var processed = 0
        status.begin(total: entries.count)
        for (index, entry) in entries.enumerated() {
            if kd_cancelled() != 0 { failure = Cancelled(); break }
            status.set(name: entry.name, index: index + 1)
            processed += 1
            do {
                guard entry.id != 0, entry.id != UInt32.max else { throw DriveError(message: "‘\(entry.name)’ cannot be deleted.") }
                if entry.folder {
                    var count = 0
                    defer { nested[entry.id] = count }
                    try emptyFolder(entry.id, entry.name, storage, &count, t)
                }
                issued.append(entry)
                do { try t.delete(id: entry.id) } catch { failedDelete = entry; throw error }
            } catch { failure = error; break }
        }
        do {
            let listing = try t.list(storage: storage, parent: parent)
            let ids = Set(listing.ids)
            var issue: String?
            for entry in issued {
                // Present by id (readable or not) → not deleted; else the same-name check.
                let problem = ids.contains(entry.id) ? Device.deletionIssue(entry, remaining: [entry])
                                                     : Device.deletionIssue(entry, remaining: listing.entries)
                if let problem { issue = issue ?? problem } else { outcome.verified.append(entry) }
            }
            if let failed = failedDelete, outcome.verified.contains(failed) {
                // The request reported an error but the item is gone: do not report a failed delete.
                let left = entries.count - processed
                let transport = (failure as? DriveError)?.isTransport ?? false
                failure = left == 0 ? nil : DriveError(message: "The Kindle reported an error after deleting ‘\(failed.name)’. The remaining \(left) item(s) were not deleted. Refresh and try again.", isTransport: transport)
            }
            if let issue { failure = combine(failure, issue, transport: false) }
        } catch {
            outcome.verified = []
            failure = combine(failure, "The deletions could not be confirmed because the folder could not be read. Refresh to see what remains.",
                              transport: (error as? DriveError)?.isTransport ?? false)
        }
        let verified = Set(outcome.verified.map(\.id))
        outcome.nestedDeleted = nested.filter { !verified.contains($0.key) }.values.reduce(0, +)
        outcome.failure = failure
        return outcome
    }
    /// Deletes everything inside a folder, then confirms with the device that it is empty.
    /// The folder itself is not deleted here.
    private static func emptyFolder(_ id: UInt32, _ name: String, _ storage: UInt32, _ count: inout Int, _ t: Transport) throws {
        // Parent 0 is the storage root; never treat it as a folder to empty.
        guard id != 0, id != UInt32.max else { throw DriveError(message: "‘\(name)’ cannot be deleted.") }
        let listing = try t.list(storage: storage, parent: id)
        guard listing.unreadable == 0 else { throw DriveError(message: "‘\(name)’ contains items that could not be read; it was left in place.") }
        for child in listing.entries {
            try checkCancel()
            if child.folder { try emptyFolder(child.id, child.name, storage, &count, t) }
            try t.delete(id: child.id)
            count += 1
        }
        let left = try t.childIDs(storage: storage, parent: id)
        guard left.isEmpty else { throw DriveError(message: "‘\(name)’ still contains \(left.count) item(s). Refresh and try again.") }
    }
    /// Adds `text` to an earlier failure, keeping `Cancelled` recognisable as such.
    private static func combine(_ earlier: Error?, _ text: String, transport: Bool) -> Error {
        switch earlier {
        case nil: return DriveError(message: text, isTransport: transport)
        case let cancelled as Cancelled: return Cancelled(note: [cancelled.note, text].compactMap { $0 }.joined(separator: " "), duringUpload: cancelled.duringUpload)
        case let e as DriveError: return DriveError(message: e.message + " " + text, isTransport: e.isTransport || transport)
        case let e?: return DriveError(message: e.localizedDescription + " " + text, isTransport: transport)
        }
    }
}
