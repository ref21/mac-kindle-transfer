import SwiftUI
import AppKit
import CMTP

@MainActor final class BrowserModel: ObservableObject {
    @Published var connection: Connection?
    @Published var storageID: UInt32 = 0
    @Published var path: [Entry] = []
    @Published var files: [Entry] = []
    @Published var selection = Set<UInt32>()
    @Published var sortOrder = [KeyPathComparator(\Entry.name, comparator: .localizedStandard)]
    @Published var search = ""
    @Published var showHidden = false
    @Published var busy = false
    @Published var transferring = false
    @Published var progress: Double = 0
    @Published var status = "Connect your Kindle to get started."
    @Published var error: String?
    @Published var history: [String] = []
    private let device = Device()
    private var timer: Timer?
    var parent: UInt32 { path.last?.id ?? 0 }
    var chosen: [Entry] { files.filter { selection.contains($0.id) } }
    var visible: [Entry] { files.filter { (showHidden || !$0.name.hasPrefix(".")) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }.sorted(using: sortOrder) }
    var selectionSummary: String { "\(chosen.count) selected (\(chosen.filter(\.folder).count) folders)" }
    func selectAll() { selection = Set(visible.map(\.id)) }
    func trimSelection() { selection.formIntersection(Set(visible.map(\.id))) }
    var storage: Storage? { connection?.storages.first { $0.id == storageID } }
    var location: String { "/" + path.map(\.name).joined(separator: "/") }
    func perform(_ label: String, transfer: Bool = false, _ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; transferring = transfer; status = label; progress = 0; kd_begin()
        if transfer {
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.progress = kd_progress() }
            }
        }
        Task {
            do { try await action(); status = "\(label) — done"; history.insert(status, at: 0) }
            catch { self.error = error.localizedDescription; status = "\(label) — stopped"; history.insert("\(status): \(error.localizedDescription)", at: 0) }
            timer?.invalidate(); timer = nil; busy = false; transferring = false
            if history.count > 50 { history = Array(history.prefix(50)) }
        }
    }
    func reload() async throws {
        files = try await device.list(storageID, parent)
        selection.formIntersection(Set(files.map(\.id)))
    }
    func connect() {
        perform("Connecting") {
            self.connection = try await self.device.connect()
            self.storageID = self.connection?.storages.first?.id ?? 0
            self.path = []; self.search = ""; try await self.reload()
        }
    }
    func disconnect() {
        perform("Disconnecting") {
            try await self.device.disconnect(); self.connection = nil; self.files = []; self.path = []; self.selection = []
        }
    }
    func refresh() { perform("Refreshing") { try await self.reload() } }
    func navigate(to folder: Entry) {
        guard folder.folder else { return }
        let old = path
        perform("Opening \(folder.name)") {
            self.path.append(folder); self.search = ""; self.selection = []
            do { try await self.reload() } catch { self.path = old; throw error }
        }
    }
    func goTo(_ depth: Int) {
        let old = path
        perform("Opening folder") {
            self.path = Array(self.path.prefix(depth)); self.search = ""; self.selection = []
            do { try await self.reload() } catch { self.path = old; throw error }
        }
    }
    func chooseStorage(_ id: UInt32) {
        perform("Opening storage") { self.storageID = id; self.path = []; self.selection = []; try await self.reload() }
    }
    func shortcut(_ name: String) {
        perform("Opening \(name)") {
            let root = try await self.device.list(self.storageID, 0)
            guard let folder = root.first(where: { $0.folder && $0.name.lowercased() == name.lowercased() }) else { throw DriveError(message: "The \(name) folder is not on this Kindle.") }
            self.path = [folder]; self.search = ""; self.selection = []; try await self.reload()
        }
    }
    func uploadPanel() {
        let panel = NSOpenPanel(); panel.title = "Add files or folders to Kindle"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Add to Kindle"
        if panel.runModal() == .OK { upload(panel.urls) }
    }
    func upload(_ urls: [URL]) {
        guard connection != nil, !urls.isEmpty else { return }
        perform("Adding \(urls.count) item(s) to \(location)", transfer: true) {
            do { try await self.device.upload(urls, storage: self.storageID, parent: self.parent) }
            catch { try? await self.reload(); throw error }
            try await self.reload()
        }
    }
    func download() {
        let entries = chosen; guard !entries.isEmpty else { return }
        let panel = NSOpenPanel(); panel.title = "Save Kindle files to a folder"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        perform("Saving \(entries.count) item(s) to Mac", transfer: true) {
            try await self.device.download(entries, storage: self.storageID, into: directory)
            NSWorkspace.shared.open(directory)
        }
    }
    func textPrompt(title: String, initial: String, button: String) -> String? {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 330, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: button); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }; return field.stringValue
    }
    func newFolder() {
        guard let name = textPrompt(title: "New folder", initial: "Untitled Folder", button: "Create") else { return }
        perform("Creating folder") { try await self.device.createFolder(name, self.storageID, self.parent); try await self.reload() }
    }
    func rename() {
        guard chosen.count == 1, let entry = chosen.first,
              let name = textPrompt(title: "Rename \(entry.name)", initial: entry.name, button: "Rename"), name != entry.name else { return }
        perform("Renaming") { try await self.device.rename(entry, to: name, storage: self.storageID, parent: self.parent); try await self.reload() }
    }
    func delete() {
        let entries = chosen; guard !entries.isEmpty else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Permanently delete \(entries.count == 1 ? entries[0].name : "\(entries.count) items")?"
        alert.informativeText = "Folders and everything inside them will be deleted from your Kindle. This cannot be undone."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete Permanently")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        perform("Deleting \(entries.count) item(s)", transfer: true) {
            do { try await self.device.delete(entries, storage: self.storageID)
                let timestamp = Date().formatted(date: .omitted, time: .standard)
                for entry in entries { self.history.insert("\(timestamp) Deleted and verified: \(self.location)/\(entry.name)", at: 0) }
            }
            catch { try? await self.reload(); throw error }
            try await self.reload()
        }
    }
}
