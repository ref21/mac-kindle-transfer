import Foundation
import CMTP

enum SmokeTest {
    static func run(mutate: Bool) -> Never {
        do {
            guard kd_connect() == 0 else { throw Device.failure() }
            guard let d = kd_device(), let storage = d.pointee.storage?.pointee.id else { throw Device.failure() }
            let root = try Device.entries(storage, 0)
            print("Connected. Root contains \(root.count) items.")
            for e in root { print("\(e.folder ? "folder" : "file")\t\(e.name)") }
            if mutate {
                kd_begin()
                let name = "KindleDrive-Test-\(UUID().uuidString)"
                let id = try Device.create(name, storage, 0)
                let testFolder = Entry(id: id, name: name, size: 0, modified: Date(), folder: true)
                defer { kd_begin(); try? Device.deleteItem(testFolder, storage: storage) }
                let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: local) }
                let source = local.appendingPathComponent("sample.txt")
                let payload = Data("Kindle Drive round-trip verification.\nUnicode: café 日本語 📚\n".utf8)
                try payload.write(to: source)
                try Device.uploadItem(source, storage, id)
                try Device.uploadItem(source, storage, id)
                var files = try Device.entries(storage, id)
                guard files.count == 2, Set(files.map(\.name)) == ["sample.txt", "sample (2).txt"] else { throw DriveError(message: "Duplicate-name handling failed") }
                guard let file = LIBMTP_Get_Filemetadata(d, files[0].id) else { throw Device.failure() }
                let rename = LIBMTP_Set_File_Name(d, file, "renamed.txt"); LIBMTP_destroy_file_t(file)
                guard rename == 0 else { throw Device.failure() }
                files = try Device.entries(storage, id)
                let dest = local.appendingPathComponent("downloads")
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
                for entry in files { try Device.downloadItem(entry, storage: storage, into: dest) }
                for entry in files {
                    guard try Data(contentsOf: dest.appendingPathComponent(entry.name)) == payload else { throw DriveError(message: "Round-trip contents differ") }
                }
                let nested = try Device.create("Nested", storage, id)
                try Device.uploadItem(source, storage, nested)
                try Device.downloadItem(testFolder, storage: storage, into: dest)
                guard try Data(contentsOf: dest.appendingPathComponent(name).appendingPathComponent("Nested/sample.txt")) == payload else { throw DriveError(message: "Recursive download failed") }
                try Device.deleteItem(testFolder, storage: storage)
                guard !(try Device.entries(storage, 0)).contains(where: { $0.id == id }) else { throw DriveError(message: "Test folder cleanup failed") }
                print("PASS: folder creation, upload, duplicate protection, rename, byte-for-byte downloads, nested folders, recursive download, and verified deletion.")
                if let documents = root.first(where: { $0.folder && $0.name.lowercased() == "documents" }) {
                    try verifyDocumentsDeletion(storage: storage, parent: documents.id, local: local)
                }
            }
            kd_disconnect(); exit(0)
        } catch {
            fputs("ERROR: \(error.localizedDescription)\n", stderr); kd_disconnect(); exit(1)
        }
    }
    static func verifyDocumentsDeletion(storage: UInt32, parent: UInt32, local: URL) throws {
        let token = UUID().uuidString
        let names = ["KindleDrive-Test-\(token).txt", "KPPMainAppV2_KindleDrive-Test-\(token).tgz", "KindleDrive-Zero-\(token).tgz"]
        let folderName = "KindleDrive-Folder-Test-\(token)"
        let fixtures = Set(names + [folderName])
        defer {
            kd_begin()
            if let remaining = try? Device.entries(storage, parent) {
                for entry in remaining where fixtures.contains(entry.name) { try? Device.deleteItem(entry, storage: storage) }
            }
        }
        for (index, name) in names.enumerated() {
            let url = local.appendingPathComponent(name)
            try Data(repeating: 42, count: index == 2 ? 0 : 100).write(to: url)
            try Device.uploadItem(url, storage, parent)
        }
        let folderID = try Device.create(folderName, storage, parent)
        let nested = try Device.create("Nested", storage, folderID)
        try Device.uploadItem(local.appendingPathComponent(names[0]), storage, nested)
        let created = try Device.entries(storage, parent).filter { fixtures.contains($0.name) }
        guard created.count == fixtures.count else { throw DriveError(message: "Documents fixtures are missing.") }
        for entry in created { try Device.deleteItem(entry, storage: storage); print("Verified deleted from documents: \(entry.name)") }
        for _ in 0..<3 {
            let remaining = try Device.entries(storage, parent)
            guard !remaining.contains(where: { fixtures.contains($0.name) }) else { throw DriveError(message: "A deleted documents fixture reappeared.") }
            Thread.sleep(forTimeInterval: 0.3)
        }
        print("PASS: deletion from documents of text, crash-log-style archive, zero-byte archive, and nested folder; confirmed absent across repeated fresh listings.")
    }

}
