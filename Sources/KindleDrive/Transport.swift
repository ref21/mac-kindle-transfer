import Foundation
import CMTP

/// The children of one folder: `ids` come straight from the device; `entries` are the
/// children whose metadata could be read (unsorted, in device order).
struct Listing: Sendable {
    let ids: [UInt32]
    let entries: [Entry]
    var unreadable: Int { ids.count - entries.count }
}

/// Raw facts about one send. After a failure `itemID` is not proof that an object was
/// created — see `Device.cleanupAction`.
struct SendResult: Sendable {
    let status: Int32      // 0 = success
    let itemID: UInt32     // whatever the library left behind
    let dataPhase: Bool    // the data phase started, so the device had created the object
}

/// Device access. Convention: **parent 0 means the storage root.** All methods are
/// synchronous and must only ever be called from one thread at a time (the USB queue,
/// or the smoke test's thread).
protocol Transport: AnyObject {
    func open() throws -> String                       // model name; throws ConnectError
    func close()
    func isAlive() -> Bool
    func deviceInfo() -> String                        // e.g. "USB 1949:9981"
    func storages() throws -> [Storage]
    func childIDs(storage: UInt32, parent: UInt32) throws -> [UInt32]
    func list(storage: UInt32, parent: UInt32) throws -> Listing
    func lookup(id: UInt32) -> (name: String, parent: UInt32)?   // nil if unreadable
    func createFolder(name: String, storage: UInt32, parent: UInt32) throws -> UInt32
    func send(path: String, name: String, size: UInt64, storage: UInt32, parent: UInt32) -> SendResult
    func receive(id: UInt32, toPath: String) throws
    func rename(id: UInt32, to name: String) throws
    func delete(id: UInt32) throws
    func lastFailure() -> DriveError                   // why the last failed call failed
}

/// The real device, through libmtp and the C shim.
final class MTPTransport: Transport {
    private func device() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let d = kd_device() else { throw DriveError(message: "Connect your Kindle first.") }
        return d
    }
    func lastFailure() -> DriveError {
        DriveError(message: String(cString: kd_error()), isTransport: kd_last_error_is_transport() != 0)
    }
    func open() throws -> String {
        let code = kd_connect()
        guard code == KD_CONNECT_OK else {
            let kind: ConnectError.Kind = code == KD_CONNECT_NO_DEVICE ? .noDevice : code == KD_CONNECT_BUSY ? .busy : .storage
            throw ConnectError(kind: kind, message: String(cString: kd_error()))
        }
        let d = try device()
        let model = LIBMTP_Get_Modelname(d)
        defer { free(model) }
        return model.map { String(cString: $0) } ?? "Kindle"
    }
    func close() { kd_disconnect() }
    func isAlive() -> Bool { kd_alive() != 0 }
    func deviceInfo() -> String {
        var vendor: UInt16 = 0, product: UInt16 = 0
        kd_device_ids(&vendor, &product)
        return String(format: "USB %04x:%04x", vendor, product)
    }
    func storages() throws -> [Storage] {
        let d = try device(); LIBMTP_Clear_Errorstack(d)
        // A failed storage query is how a dead device shows itself (see kd_alive).
        guard LIBMTP_Get_Storage(d, 0) >= 0 else { throw DriveError(message: String(cString: kd_error()), isTransport: true) }
        var node = d.pointee.storage; var result: [Storage] = []
        while let p = node {
            let s = p.pointee
            result.append(Storage(id: s.id, name: s.StorageDescription.map { String(cString: $0) } ?? "Internal storage",
                                  capacity: s.MaxCapacity, free: s.FreeSpaceInBytes))
            node = s.next
        }
        return result
    }
    func childIDs(storage: UInt32, parent: UInt32) throws -> [UInt32] {
        let d = try device(); LIBMTP_Clear_Errorstack(d)
        // For GetObjectHandles the root is 0xFFFFFFFF; 0 would mean "every object".
        var out: UnsafeMutablePointer<UInt32>? = nil
        let count = LIBMTP_Get_Children(d, storage, parent == 0 ? UInt32.max : parent, &out)
        defer { free(out) }   // set (and owned by us) only when count > 0
        guard count >= 0 else { throw lastFailure() }
        guard count > 0, let out else { return [] }
        return Array(UnsafeBufferPointer(start: out, count: Int(count)))
    }
    func list(storage: UInt32, parent: UInt32) throws -> Listing {
        let ids = try childIDs(storage: storage, parent: parent)
        let d = try device()
        // Whatever happens, leave no benign entries behind for a later failure to report.
        defer { LIBMTP_Clear_Errorstack(d) }
        var entries: [Entry] = []
        for id in ids {
            guard let p = LIBMTP_Get_Filemetadata(d, id) else {
                // libmtp records no error for a failed metadata read, so the error stack
                // alone cannot tell "this object is unreadable" from "the device is gone".
                // Ask the device; only an unreadable object on a live device is skipped.
                if kd_last_error_is_transport() != 0 || kd_alive() == 0 {
                    throw DriveError(message: "The Kindle stopped responding while this folder was being read. Reconnect it and try again.", isTransport: true)
                }
                continue
            }
            let f = p.pointee
            entries.append(Entry(id: f.item_id, name: f.filename.map { String(cString: $0) } ?? "Unnamed",
                                 size: f.filesize, modified: Date(timeIntervalSince1970: Double(f.modificationdate)),
                                 folder: f.filetype == LIBMTP_FILETYPE_FOLDER))
            LIBMTP_destroy_file_t(p)
        }
        return Listing(ids: ids, entries: entries)
    }
    func lookup(id: UInt32) -> (name: String, parent: UInt32)? {
        guard let d = kd_device() else { return nil }
        defer { LIBMTP_Clear_Errorstack(d) }
        guard let p = LIBMTP_Get_Filemetadata(d, id) else { return nil }
        defer { LIBMTP_destroy_file_t(p) }
        guard let name = p.pointee.filename else { return nil }
        return (String(cString: name), p.pointee.parent_id)
    }
    func createFolder(name: String, storage: UInt32, parent: UInt32) throws -> UInt32 {
        let d = try device(); LIBMTP_Clear_Errorstack(d)
        let id = kd_create_folder(name, parent, storage)
        guard id != 0 else { throw lastFailure() }
        return id
    }
    func send(path: String, name: String, size: UInt64, storage: UInt32, parent: UInt32) -> SendResult {
        if let d = kd_device() { LIBMTP_Clear_Errorstack(d) }
        var itemID: UInt32 = 0; var dataPhase: Int32 = 0
        let status = kd_upload(path, name, parent, storage, size, &itemID, &dataPhase)
        return SendResult(status: status, itemID: itemID, dataPhase: dataPhase != 0)
    }
    func receive(id: UInt32, toPath: String) throws {
        let d = try device(); LIBMTP_Clear_Errorstack(d)
        guard kd_download(id, toPath) == 0 else { throw lastFailure() }
    }
    func rename(id: UInt32, to name: String) throws {
        let d = try device(); LIBMTP_Clear_Errorstack(d)
        // LIBMTP_Set_File_Name is correct for folders too (it maps the folder type itself).
        guard let f = LIBMTP_Get_Filemetadata(d, id) else { throw lastFailure() }
        defer { LIBMTP_destroy_file_t(f) }
        guard LIBMTP_Set_File_Name(d, f, name) == 0 else { throw lastFailure() }
    }
    /// The only place in the app that deletes an object from the Kindle.
    func delete(id: UInt32) throws {
        // 0 is not an object, and in MTP DeleteObject(0xFFFFFFFF) means "delete every object".
        guard id != 0, id != UInt32.max else { throw DriveError(message: "That item cannot be deleted.") }
        let d = try device(); LIBMTP_Clear_Errorstack(d)
        guard LIBMTP_Delete_Object(d, id) == 0 else { throw lastFailure() }
    }
}
