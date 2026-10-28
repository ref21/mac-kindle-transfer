import Foundation
import CMTP

struct DriveError: LocalizedError { let message: String; var errorDescription: String? { message } }
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
struct Connection: Sendable { let name: String; let storages: [Storage] }

// All libmtp calls run on this serial worker. Only the atomic progress/cancel
// functions may be called from another thread.
final class Device: @unchecked Sendable {
    private let queue = DispatchQueue(label: "KindleDrive.USB", qos: .userInitiated)
    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
    static func failure() -> DriveError {
        DriveError(message: kd_cancelled() != 0 ? "Cancelled. Completed files have been kept." : String(cString: kd_error()))
    }
    static func checked() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let d = kd_device() else { throw DriveError(message: "Connect your Kindle first.") }; return d
    }
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
    static func entries(_ storage: UInt32, _ parent: UInt32) throws -> [Entry] {
        let d = try checked(); LIBMTP_Clear_Errorstack(d)
        var node = LIBMTP_Get_Files_And_Folders(d, storage, parent == 0 ? UInt32.max : parent)
        var result: [Entry] = []
        while let p = node {
            let f = p.pointee; node = f.next
            result.append(Entry(id: f.item_id, name: f.filename.map { String(cString: $0) } ?? "Unnamed",
                                size: f.filesize, modified: Date(timeIntervalSince1970: Double(f.modificationdate)),
                                folder: f.filetype == LIBMTP_FILETYPE_FOLDER))
            LIBMTP_destroy_file_t(p)
        }
        if LIBMTP_Get_Errorstack(d) != nil { throw failure() }
        return result.sorted { a,b in a.folder != b.folder ? a.folder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
    func connect() async throws -> Connection {
        try await run {
            kd_begin()
            guard kd_connect() == 0 else { throw Self.failure() }
            let d = try Self.checked()
            let model = LIBMTP_Get_Modelname(d)
            let name = model.map { String(cString: $0) } ?? "Kindle"; free(model)
            var node = d.pointee.storage; var storages: [Storage] = []
            while let p = node {
                let s = p.pointee
                storages.append(Storage(id: s.id, name: s.StorageDescription.map { String(cString: $0) } ?? "Internal storage", capacity: s.MaxCapacity, free: s.FreeSpaceInBytes)); node = s.next
            }
            return Connection(name: name, storages: storages)
        }
    }
    func disconnect() async throws { try await run { kd_disconnect() } }
    func list(_ storage: UInt32, _ parent: UInt32) async throws -> [Entry] {
        try await run { try Self.entries(storage, parent) }
    }
    static func create(_ name: String, _ storage: UInt32, _ parent: UInt32) throws -> UInt32 {
        try requireName(name)
        let existing = try entries(storage, parent)
        guard !existing.contains(where: { $0.name.lowercased() == name.lowercased() }) else { throw DriveError(message: "That name already exists in this folder.") }
        let d = try checked()
        let id = name.withCString { LIBMTP_Create_Folder(d, UnsafeMutablePointer(mutating: $0), parent, storage) }
        guard id != 0 else { throw failure() }; return id
    }
    func createFolder(_ name: String, _ storage: UInt32, _ parent: UInt32) async throws {
        try await run { kd_begin(); _ = try Self.create(name, storage, parent) }
    }
    func rename(_ entry: Entry, to name: String, storage: UInt32, parent: UInt32) async throws {
        try await run {
            kd_begin(); try Self.requireName(name)
            let d = try Self.checked()
            guard !(try Self.entries(storage, parent)).contains(where: { $0.id != entry.id && $0.name.lowercased() == name.lowercased() }) else { throw DriveError(message: "That name already exists.") }
            guard let f = LIBMTP_Get_Filemetadata(d, entry.id) else { throw Self.failure() }
            defer { LIBMTP_destroy_file_t(f) }
            guard LIBMTP_Set_File_Name(d, f, name) == 0 else { throw Self.failure() }
        }
    }
    static func checkCancellation() throws { if kd_cancelled() != 0 { throw failure() } }
    static func uploadItem(_ url: URL, _ storage: UInt32, _ parent: UInt32) throws {
        try checkCancellation()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else { throw DriveError(message: "Symbolic links are not uploaded: \(url.lastPathComponent)") }
        let names = Set(try entries(storage, parent).map { $0.name.lowercased() })
        let name = unique(url.lastPathComponent, among: names); try requireName(name)
        if values.isDirectory == true {
            let id = try create(name, storage, parent)
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try uploadItem(child, storage, id)
            }
        } else {
            guard values.isRegularFile == true else { throw DriveError(message: "Only regular files and folders can be uploaded.") }
            let size = UInt64(values.fileSize ?? 0)
            let d = try checked()
            guard LIBMTP_Get_Storage(d, 0) == 0 else { throw failure() }
            var s = d.pointee.storage
            while let p = s { if p.pointee.id == storage && p.pointee.FreeSpaceInBytes < size { throw DriveError(message: "There is not enough free space on your Kindle.") }; s = p.pointee.next }
            var id: UInt32 = 0
            guard kd_upload(url.path, name, parent, storage, size, &id) == 0 else { throw failure() }
        }
    }
    func upload(_ urls: [URL], storage: UInt32, parent: UInt32) async throws {
        try await run { for url in urls { try Self.uploadItem(url, storage, parent) } }
    }
    static func downloadItem(_ entry: Entry, storage: UInt32, into directory: URL) throws {
        try checkCancellation(); try requireName(entry.name)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).map { $0.lowercased() })
        let target = directory.appendingPathComponent(unique(entry.name, among: names))
        if entry.folder {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            for child in try entries(storage, entry.id) { try downloadItem(child, storage: storage, into: target) }
        } else {
            // Download beside the destination, then commit it atomically only on success.
            let partial = directory.appendingPathComponent(".kindledrive-\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: partial) }
            guard kd_download(entry.id, partial.path) == 0 else { throw failure() }
            let attrs = try FileManager.default.attributesOfItem(atPath: partial.path)
            guard (attrs[.size] as? NSNumber)?.uint64Value == entry.size else { throw DriveError(message: "Download size did not match. The incomplete copy was removed.") }
            try FileManager.default.moveItem(at: partial, to: target)
        }
    }
    func download(_ entries: [Entry], storage: UInt32, into directory: URL) async throws {
        try await run { for entry in entries { try Self.downloadItem(entry, storage: storage, into: directory) } }
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
    static func deleteItem(_ entry: Entry, storage: UInt32) throws {
        try checkCancellation()
        let d = try checked()
        // Preserve the parent before deletion so verification queries the device,
        // rather than trusting the library's success response or local UI state.
        guard let metadata = LIBMTP_Get_Filemetadata(d, entry.id) else { throw failure() }
        let parent = metadata.pointee.parent_id
        let actualName = metadata.pointee.filename.map { String(cString: $0) }
        LIBMTP_destroy_file_t(metadata)
        guard actualName == entry.name else {
            throw DriveError(message: "‘\(entry.name)’ changed on the Kindle. Refresh the folder before deleting it.")
        }
        if entry.folder { for child in try entries(storage, entry.id) { try deleteItem(child, storage: storage) } }
        LIBMTP_Clear_Errorstack(d)
        guard LIBMTP_Delete_Object(d, entry.id) == 0 else { throw failure() }
        if let issue = deletionIssue(entry, remaining: try entries(storage, parent)) {
            throw DriveError(message: issue)
        }
    }
    func delete(_ entries: [Entry], storage: UInt32) async throws {
        try await run { for entry in entries { try Self.deleteItem(entry, storage: storage) } }
    }
}
