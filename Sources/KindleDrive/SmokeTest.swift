import Foundation
import CMTP

/// Hardware checks, run by the owner only: `--probe` is read-only; `--smoke-test` writes
/// only inside one uniquely named folder at the storage root and removes it afterwards.
/// Runs synchronously on the calling thread with the same functions the app uses.
enum SmokeTest {
    static func run(mutate: Bool) -> Never {
        let t = MTPTransport()
        let arguments = CommandLine.arguments
        do {
            let model = try t.open()
            let storages = try t.storages()
            guard let storage = storages.first?.id else { throw DriveError(message: "The Kindle reported no storage.") }
            print("Connected: \(model) — \(t.deviceInfo())")
            for s in storages { print("storage\t\(s.name)\t\(s.free) of \(s.capacity) bytes free") }
            print(t.canMove() ? "move\tsupported" : "move\tnot supported (MTP MoveObject missing)")
            let root = try t.list(storage: storage, parent: 0)
            print("Root: \(root.ids.count) ids / \(root.entries.count) readable")
            for e in root.entries { print("\(e.folder ? "folder" : "file")\t\(e.name)") }
            let documents = root.entries.first(where: { $0.folder && $0.name.lowercased() == "documents" })
            if let documents {
                let listing = try t.list(storage: storage, parent: documents.id)
                print("documents: \(listing.ids.count) ids / \(listing.entries.count) readable")
            }
            if arguments.contains("--dump") { kd_dump_device_info() }
            if mutate {
                // documents/ first: the round trip ends with a cancelled upload, which can
                // leave the Kindle refusing new items for the rest of the connection.
                if arguments.contains("--documents") {
                    guard let documents else { throw DriveError(message: "This Kindle has no documents folder.") }
                    try verifyDocumentsDeletion(t, storage, documents.id)
                }
                try roundTrip(t, storage)
            }
            t.close(); exit(0)
        } catch {
            fputs("ERROR: \(error.localizedDescription)\n", stderr); t.close(); exit(1)
        }
    }
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw DriveError(message: message) } }
    static func sameBytes(_ a: String, _ b: String) -> Bool { Array(a.utf8) == Array(b.utf8) }   // String == ignores NFC/NFD

    static func roundTrip(_ t: Transport, _ storage: UInt32) throws {
        let status = TransferStatus()
        let fm = FileManager.default
        kd_reset_transfer()
        let name = "KindleDrive-Test-\(UUID().uuidString)"
        let id = try DeviceOps.createFolder(name, storage: storage, parent: 0, on: t)
        let testFolder = Entry(id: id, name: name, size: 0, modified: Date(), folder: true)
        var removed = false
        defer { if !removed { kd_reset_transfer(); _ = DeviceOps.delete([testFolder], storage: storage, parent: 0, status: status, on: t) } }
        let local = fm.temporaryDirectory.appendingPathComponent(name)
        try fm.createDirectory(at: local, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: local) }

        // Upload and duplicate naming.
        let source = local.appendingPathComponent("sample.txt")
        let payload = Data("Kindle Drive round-trip verification.\nUnicode: café 日本語 📚\n".utf8)
        try payload.write(to: source)
        for _ in 0..<2 {
            let summary = try DeviceOps.upload([source], storage: storage, parent: id, status: status, on: t)
            try check(summary.uploaded == 1 && summary.skipped.isEmpty, "Upload was not reported as copied")
        }
        var listing = try t.list(storage: storage, parent: id)
        try check(listing.entries.count == 2 && Set(listing.entries.map(\.name)) == ["sample.txt", "sample (2).txt"], "Duplicate-name handling failed")

        // Rename a file and a folder through the app's rename.
        try DeviceOps.rename(listing.entries[0], to: "renamed.txt", storage: storage, parent: id, on: t)
        let nestedID = try DeviceOps.createFolder("Nested", storage: storage, parent: id, on: t)
        let nested = Entry(id: nestedID, name: "Nested", size: 0, modified: Date(), folder: true)
        try DeviceOps.rename(nested, to: "Nested Renamed", storage: storage, parent: id, on: t)

        // A decomposed (NFD) name must arrive precomposed (NFC).
        let decomposed = local.appendingPathComponent("cafe\u{301}.txt")
        try payload.write(to: decomposed)
        _ = try DeviceOps.upload([decomposed], storage: storage, parent: id, status: status, on: t)

        listing = try t.list(storage: storage, parent: id)
        try check(listing.unreadable == 0, "The test folder lists \(listing.ids.count) ids but only \(listing.entries.count) are readable")
        let names = listing.entries.map(\.name)
        try check(names.contains("renamed.txt"), "File rename failed")
        try check(names.contains("Nested Renamed") && !names.contains("Nested"), "Folder rename failed")
        try check(names.contains(where: { sameBytes($0, "caf\u{e9}.txt") }), "The decomposed name was not stored in NFC form")

        // Downloads: byte-for-byte, mode 0644.
        let dest = local.appendingPathComponent("downloads")
        try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        let files = listing.entries.filter { !$0.folder }
        try DeviceOps.download(files, storage: storage, into: dest, status: status, on: t)
        for entry in files {
            let path = dest.appendingPathComponent(entry.name).path
            try check(fm.contents(atPath: path) == payload, "Round-trip contents differ: \(entry.name)")
            let mode = (try fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
            try check(mode == 0o644, "Downloaded file mode is not 0644: \(entry.name)")
        }

        // Nested upload and recursive download.
        _ = try DeviceOps.upload([source], storage: storage, parent: nestedID, status: status, on: t)
        try DeviceOps.download([testFolder], storage: storage, into: dest, status: status, on: t)
        try check(fm.contents(atPath: dest.appendingPathComponent(name).appendingPathComponent("Nested Renamed/sample.txt").path) == payload, "Recursive download failed")

        // Move a file into a subfolder and back (before the cancel step, which can stop the
        // Kindle accepting new objects).
        let canMove = t.canMove()
        if canMove {
            func entry(_ name: String, in folder: UInt32) throws -> Entry {
                guard let e = try t.list(storage: storage, parent: folder).entries.first(where: { $0.name == name }) else {
                    throw DriveError(message: "‘\(name)’ is missing after a move.")
                }
                return e
            }
            func has(_ name: String, in folder: UInt32) throws -> Bool {
                try t.list(storage: storage, parent: folder).entries.contains { $0.name == name }
            }
            for (from, to, label) in [(id, nestedID, "into a subfolder"), (nestedID, id, "back")] {
                let outcome = DeviceOps.move([try entry("renamed.txt", in: from)], storage: storage, from: from, to: to, status: status, on: t)
                try check(outcome.failure == nil && outcome.moved.count == 1, "Move \(label) failed: \(outcome.failure?.localizedDescription ?? "not confirmed")")
                try check(try has("renamed.txt", in: to) && !(try has("renamed.txt", in: from)), "Move \(label) left the file in the wrong folder")
            }
            // A folder with contents, there and back.
            let targetID = try DeviceOps.createFolder("Move Target", storage: storage, parent: id, on: t)
            for (from, to, label) in [(id, targetID, "of a folder into a subfolder"), (targetID, id, "of a folder back")] {
                let outcome = DeviceOps.move([try entry("Nested Renamed", in: from)], storage: storage, from: from, to: to, status: status, on: t)
                try check(outcome.failure == nil && outcome.moved.count == 1, "Move \(label) failed: \(outcome.failure?.localizedDescription ?? "not confirmed")")
                let folder = try entry("Nested Renamed", in: to)   // the folder may have a new handle
                try check(!(try has("Nested Renamed", in: from)), "Move \(label) left the folder behind")
                let inside = try entry("sample.txt", in: folder.id)
                try check(inside.size == UInt64(payload.count), "Move \(label) changed the size of sample.txt inside the folder")
            }
            // A file to the storage root and back; the unique name cannot clash there.
            let rootName = "KindleDrive-Test-Move-\(UUID().uuidString).txt"
            try DeviceOps.rename(try entry("renamed.txt", in: id), to: rootName, storage: storage, parent: id, on: t)
            do {
                let toRoot = DeviceOps.move([try entry(rootName, in: id)], storage: storage, from: id, to: 0, status: status, on: t)
                try check(toRoot.failure == nil && toRoot.moved.count == 1, "Move to the top level failed: \(toRoot.failure?.localizedDescription ?? "not confirmed")")
                try check(try has(rootName, in: 0) && !(try has(rootName, in: id)), "Move to the top level left the file in the wrong folder")
                let back = DeviceOps.move([try entry(rootName, in: 0)], storage: storage, from: 0, to: id, status: status, on: t)
                try check(back.failure == nil && back.moved.count == 1, "Move back from the top level failed: \(back.failure?.localizedDescription ?? "not confirmed")")
                try check(try has(rootName, in: id) && !(try has(rootName, in: 0)), "Move back from the top level left the file in the wrong folder")
            } catch {
                throw DriveError(message: "\(error.localizedDescription) The test file ‘\(rootName)’ may be left at the top level of the Kindle's storage: delete it.")
            }
            print("move\tOK")
        } else {
            print("SKIP move: this Kindle does not support MTP MoveObject")
        }

        // Cancel in the middle of an upload: the incomplete copy must be removed.
        let big = local.appendingPathComponent("cancel-me.bin")
        try Data(count: 5 * 1024 * 1024).write(to: big)
        let before = Set(try t.childIDs(storage: storage, parent: id))
        kd_reset_transfer(); kd_cancel_at(0.2)
        var cancelNote: String?? = nil
        do { _ = try DeviceOps.upload([big], storage: storage, parent: id, status: status, on: t) }
        catch let cancelled as Cancelled { cancelNote = .some(cancelled.note) }
        kd_reset_transfer()
        guard let note = cancelNote else { throw DriveError(message: "The upload was not cancelled") }
        try check(note == nil, "Cancel cleanup reported: \(note ?? "")")
        try check(Set(try t.childIDs(storage: storage, parent: id)) == before, "A cancelled upload left an object behind")

        // Recursive, verified delete.
        let outcome = DeviceOps.delete([testFolder], storage: storage, parent: 0, status: status, on: t)
        removed = outcome.verified.count == 1
        if let failure = outcome.failure { throw failure }
        try check(removed && !(try t.childIDs(storage: storage, parent: 0)).contains(id), "Test folder cleanup failed")

        // The Kindle must still accept new items after the cancelled upload. On a Kindle
        // Paperwhite (2026-11-19) it accepted one immediately after the cancel but refused
        // later ones (about a minute's hang, then PTP 02ff) until it was replugged.
        let probeName = "KindleDrive-Test-AfterCancel-\(UUID().uuidString)"
        let start = Date()
        let probeID: UInt32
        do { probeID = try DeviceOps.createFolder(probeName, storage: storage, parent: 0, on: t) }
        catch {
            throw DriveError(message: "After a cancelled upload the Kindle refused to create a folder (\(String(format: "%.1f", Date().timeIntervalSince(start))) s): \(error.localizedDescription) Unplug and replug the Kindle before using it again.")
        }
        let probe = Entry(id: probeID, name: probeName, size: 0, modified: Date(), folder: true)
        let cleanup = DeviceOps.delete([probe], storage: storage, parent: 0, status: status, on: t)
        if let failure = cleanup.failure { throw failure }
        print("PASS: folder creation, upload, duplicate naming, file rename, folder rename, NFC names, complete listing (ids == readable), byte-for-byte downloads with mode 0644, nested folders, recursive download, \(canMove ? "move there and back (file, folder with contents, to root)" : "(move skipped: not supported)"), cancelled-upload cleanup, and verified recursive deletion.")
    }

    /// Opt-in (`--smoke-test --documents`): deletion inside the real documents folder,
    /// where some Kindles recreate files. Touches only its own uniquely named fixtures.
    static func verifyDocumentsDeletion(_ t: Transport, _ storage: UInt32, _ parent: UInt32) throws {
        let status = TransferStatus()
        let fm = FileManager.default
        let token = UUID().uuidString
        let fileNames = ["KindleDrive-Test-\(token).txt", "KindleDrive-Test-\(token).tgz", "KindleDrive-Test-Zero-\(token).tgz"]
        let folderName = "KindleDrive-Test-Folder-\(token)"
        let fixtures = Set(fileNames + [folderName])
        let local = fm.temporaryDirectory.appendingPathComponent("KindleDrive-Test-\(token)")
        try fm.createDirectory(at: local, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: local) }
        defer {
            kd_reset_transfer()
            if let remaining = try? t.list(storage: storage, parent: parent) {
                _ = DeviceOps.delete(remaining.entries.filter { fixtures.contains($0.name) }, storage: storage, parent: parent, status: status, on: t)
            }
        }
        kd_reset_transfer()
        var urls: [URL] = []
        for (index, name) in fileNames.enumerated() {
            let url = local.appendingPathComponent(name)
            try Data(repeating: 42, count: index == 2 ? 0 : 100).write(to: url)
            urls.append(url)
        }
        // One file at a time, so a failure names the file; keep going so one run shows
        // every type the Kindle refuses in documents/.
        var failed: [String] = []
        func send(_ url: URL, to folder: UInt32, label: String) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let start = Date()
            do {
                let summary = try DeviceOps.upload([url], storage: storage, parent: folder, status: status, on: t)
                let took = String(format: "%.1f", Date().timeIntervalSince(start))
                if summary.uploaded == 1 { print("documents upload OK (\(took) s): \(label) (\(size) bytes)") }
                else { failed.append(label); print("documents upload SKIPPED (\(took) s): \(label): \(summary.skipped.joined(separator: "; "))") }
            } catch {
                let took = String(format: "%.1f", Date().timeIntervalSince(start))
                failed.append(label)
                print("documents upload FAILED (\(took) s): \(label) (\(size) bytes): \(error.localizedDescription)")
            }
        }
        for url in urls { send(url, to: parent, label: "documents/\(url.lastPathComponent)") }
        let folderID = try DeviceOps.createFolder(folderName, storage: storage, parent: parent, on: t)
        let nested = try DeviceOps.createFolder("Nested", storage: storage, parent: folderID, on: t)
        send(urls[0], to: nested, label: "documents/\(folderName)/Nested/\(urls[0].lastPathComponent)")
        if !failed.isEmpty { throw DriveError(message: "Uploads into documents/ failed: \(failed.joined(separator: ", ")).") }
        let created = try t.list(storage: storage, parent: parent).entries.filter { fixtures.contains($0.name) }
        try check(created.count == fixtures.count, "Documents fixtures are missing.")
        let outcome = DeviceOps.delete(created, storage: storage, parent: parent, status: status, on: t)
        if let failure = outcome.failure { throw failure }
        try check(outcome.verified.count == created.count, "Not every documents fixture was verified as deleted.")
        for _ in 0..<3 {
            let remaining = try t.list(storage: storage, parent: parent)
            try check(!remaining.entries.contains(where: { fixtures.contains($0.name) }), "A deleted documents fixture reappeared.")
            Thread.sleep(forTimeInterval: 0.3)
        }
        print("PASS: deletion from documents of a text file, an archive, a zero-byte archive, and a nested folder; confirmed absent across repeated fresh listings.")
    }
}
