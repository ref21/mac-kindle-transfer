import SwiftUI
import AppKit
import CMTP

/// Progress of the running copy or delete. Kept out of `BrowserModel` so that only the
/// status bar re-renders while it changes; values are assigned only when they change.
@MainActor final class TransferMonitor: ObservableObject {
    enum Mode: Equatable { case idle, copying, deleting }
    @Published private(set) var mode = Mode.idle
    @Published private(set) var progress: Double = 0     // current file, 0…1 (copies only)
    @Published private(set) var item = ""                // e.g. "Copying ‘Book.azw3’ (3 of 20)"
    private let readProgress: () -> Double
    private var status: TransferStatus?
    private var timer: Timer?
    init(progress: @escaping () -> Double) { readProgress = progress }

    func start(_ mode: Mode, status: TransferStatus) {
        stop()
        self.mode = mode; self.status = status
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() {
        timer?.invalidate(); timer = nil; status = nil
        if mode != .idle { mode = .idle }
        if progress != 0 { progress = 0 }
        if !item.isEmpty { item = "" }
    }
    private func tick() {
        guard let status else { return }
        let s = status.snapshot
        let text = s.index == 0 ? "" : "\(mode == .deleting ? "Deleting" : "Copying") ‘\(s.name)’ (\(s.index) of \(s.total))"
        if text != item { item = text }
        guard mode == .copying else { return }
        let fraction = (min(max(readProgress(), 0), 1) * 100).rounded() / 100
        if fraction != progress { progress = fraction }
    }
}

/// Details an operation hands back to `perform` for its final status and Activity entry.
final class OperationContext {
    let status = TransferStatus()
    var doneNote: String?      // appended to "— done", e.g. "2 skipped"
    var cancelNote: String?    // appended to the cancel wording, e.g. what was deleted
}

@MainActor final class BrowserModel: ObservableObject {
    enum Kind { case plain, copy, delete }
    static let noKindleStatus = "No Kindle found. Connect it by USB, then click Connect Kindle."
    static let disconnectedStatus = "The Kindle was disconnected."
    static let epubNote = "Note: the Kindle's built-in reader can't open .epub files copied by USB. Convert them (for example to AZW3 or KFX) or use Send to Kindle; reader apps such as KOReader can open them."
    static let reconnectSteps = "click Disconnect, unplug the Kindle, plug it back in, then click Connect Kindle."
    /// Shown when an upload is stopped partway through a file (see `Cancelled.duringUpload`).
    static let afterCancelWarning = "The copy was stopped partway through a file. After this, the Kindle may not accept new files or folders until it is reconnected: \(reconnectSteps) Browsing, saving to your Mac and deleting still work."
    /// The same, when the app is quitting (Stop and Quit).
    static let quitAfterCancelWarning = "The copy was stopped partway through a file. Before you use the Kindle with Kindle Drive again, unplug it and plug it back in; until then it may not accept new files or folders."
    /// A later copy or new folder timed out after such a cancel.
    static let stalledAfterCancel = "The Kindle stopped accepting new files and folders after the cancelled copy. To fix this, \(reconnectSteps)"
    /// The same timeout with no cancel seen in this connection.
    static let notRespondingHint = "The Kindle did not respond in time, although it is still connected. If a copy was stopped partway through a file earlier, the Kindle needs to be reconnected: \(reconnectSteps)"
    static let shortcutNames = ["documents", "audible", "fonts", "screenshots", "books", "koreader"]
    static let historyLimit = 500

    @Published var connection: Connection?
    @Published var storageID: UInt32 = 0
    @Published var path: [Entry] = []
    @Published var files: [Entry] = []
    @Published var unreadable = 0                // children of this folder that could not be read
    @Published var rootFolders: [Entry] = []     // folders at the root of the current storage
    @Published var selection = Set<UInt32>()
    @Published var sortOrder = [KeyPathComparator(\Entry.name, comparator: .localizedStandard)]
    @Published var search = ""
    @Published var showHidden = false
    @Published var busy = false
    @Published var status = "Connect your Kindle to get started."
    @Published var error: String?
    @Published var history: [String] = []
    /// An upload was stopped partway through a file in this connection, so the Kindle may
    /// refuse new items until it is replugged. Cleared with the connection.
    @Published private(set) var cancelledMidUpload = false
    let device: Device
    let monitor: TransferMonitor
    let demo: Bool
    private var task: Task<Void, Never>?
    private var idleHandlers: [() -> Void] = []

    /// `device` is chosen once at launch: the real Kindle, or the in-memory one for `--demo`.
    init(device: Device = Device(), demo: Bool = false, progress: @escaping () -> Double = { kd_progress() }) {
        self.device = device; self.demo = demo
        monitor = TransferMonitor(progress: progress)
    }

    var parent: UInt32 { path.last?.id ?? 0 }
    var chosen: [Entry] { files.filter { selection.contains($0.id) } }
    var visible: [Entry] { files.filter { (showHidden || !$0.name.hasPrefix(".")) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }.sorted(using: sortOrder) }
    var selectionSummary: String {
        let count = chosen.count, folders = chosen.filter(\.folder).count
        return "\(count) \(count == 1 ? "item" : "items") selected" + (folders == 0 ? "" : " (\(folders) \(folders == 1 ? "folder" : "folders"))")
    }
    var itemCount: String {
        if !selection.isEmpty { return selectionSummary }
        let count = visible.count
        return "\(count) \(count == 1 ? "item" : "items")"
    }
    var unreadableNote: String? {
        unreadable == 0 ? nil : "\(unreadable) \(unreadable == 1 ? "item" : "items") on the Kindle could not be read"
    }
    /// Known root folders that exist on this Kindle, in a fixed order.
    var shortcuts: [Entry] {
        Self.shortcutNames.compactMap { name in rootFolders.first { $0.name.lowercased() == name } }
    }
    func selectAll() { selection = Set(visible.map(\.id)) }
    func trimSelection() { selection.formIntersection(Set(visible.map(\.id))) }
    var storage: Storage? { connection?.storages.first { $0.id == storageID } }
    var location: String { "/" + path.map(\.name).joined(separator: "/") }
    nonisolated static func itemPath(_ folders: [String], _ name: String) -> String { "/" + (folders + [name]).joined(separator: "/") }

    func record(_ line: String) {
        history.insert(line, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    // MARK: Running operations

    /// The only way to start a device operation: one at a time, while `busy`.
    /// `creates`: the operation makes new items on the Kindle (copy to it, new folder).
    func perform(_ label: String, kind: Kind = .plain, quietIfNoKindle: Bool = false, creates: Bool = false,
                 _ action: @escaping (OperationContext) async throws -> Void) {
        guard !busy else { return }
        busy = true; status = label; kd_reset_transfer()
        let context = OperationContext()
        switch kind {
        case .copy: monitor.start(.copying, status: context.status)
        case .delete: monitor.start(.deleting, status: context.status)
        case .plain: break
        }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: label)
        task = Task {
            defer {
                ProcessInfo.processInfo.endActivity(activity)
                monitor.stop(); busy = false; task = nil
                let handlers = idleHandlers; idleHandlers = []
                handlers.forEach { $0() }
            }
            do {
                try await action(context)
                status = "\(label) — done" + (context.doneNote.map { ", \($0)" } ?? "")
                record(status)
            } catch let cancelled as Cancelled {
                status = "\(label) — cancelled"
                let wording = kind == .delete ? "Stopped. Items already deleted stay deleted." : "Stopped. Files already copied were kept."
                record([status + ".", wording, context.cancelNote, cancelled.note].compactMap { $0 }.joined(separator: " "))
                if cancelled.duringUpload { cancelledMidUpload = true; record(Self.afterCancelWarning) }
                // Alert only when the user must act on something: an incomplete copy that
                // could not be removed, or a Kindle that may need reconnecting.
                let notes = [cancelled.note, cancelled.duringUpload ? Self.afterCancelWarning : nil].compactMap { $0 }
                if !notes.isEmpty { self.error = notes.joined(separator: "\n\n") }
            } catch let failure as ConnectError where quietIfNoKindle && failure.kind == .noDevice {
                status = Self.noKindleStatus
            } catch {
                await fail(label, error, creates: creates)
            }
        }
    }
    private func fail(_ label: String, _ error: Error, creates: Bool) async {
        let transport = connection != nil && (error as? DriveError)?.isTransport == true
        // Only a transport failure while connected can mean the Kindle is gone.
        if transport, !(await device.isAlive()) {
            let replug = cancelledMidUpload
            clearConnection()
            status = Self.disconnectedStatus
            record("\(label) — stopped: \(error.localizedDescription)")
            record(status)
            self.error = (replug ? "The Kindle stopped responding after the cancelled copy. Unplug it, plug it back in, then click Connect Kindle."
                                 : "The Kindle was disconnected. Connect it again, then click Connect Kindle.") + "\n\n\(error.localizedDescription)"
            // Releasing a dead device can block for a while; `busy` stays set until it is done.
            try? await device.disconnect()
            return
        }
        status = "\(label) — stopped"
        record("\(status): \(error.localizedDescription)")
        // Still connected but timed out: on the tested Kindle this follows a cancelled upload.
        if transport, creates {
            let advice = cancelledMidUpload ? Self.stalledAfterCancel : Self.notRespondingHint
            record(advice)
            self.error = advice + "\n\n" + error.localizedDescription
            return
        }
        self.error = error.localizedDescription
    }
    /// Runs `handler` once no operation is running (now, if none is).
    func whenIdle(_ handler: @escaping () -> Void) {
        if busy { idleHandlers.append(handler) } else { handler() }
    }
    /// Waits for the running operation, if any (for tests).
    func finished() async { await task?.value }

    private func clearConnection() {
        connection = nil; files = []; path = []; selection = []; rootFolders = []; unreadable = 0
        cancelledMidUpload = false
    }

    // MARK: Location

    /// Shows `newPath` on `storage`. The folder is listed first and nothing changes if that
    /// fails, so the table never shows one folder while `parent` points at another.
    func open(storage: UInt32, path newPath: [Entry]) async throws {
        let listing = try await device.list(storage, newPath.last?.id ?? 0)
        storageID = storage; path = newPath; search = ""; selection = []
        apply(listing)
    }
    func reload() async throws { apply(try await device.list(storageID, parent)) }
    private func apply(_ listing: Listing) {
        files = listing.entries; unreadable = listing.unreadable
        selection.formIntersection(Set(files.map(\.id)))
        if path.isEmpty { rootFolders = files.filter(\.folder) }
    }
    private func refreshStorages() async throws {
        guard let c = connection else { return }
        let storages = try await device.storages()
        connection = Connection(name: c.name, storages: storages, deviceInfo: c.deviceInfo)
    }
    /// After a change on the Kindle: the folder again, and free space.
    private func afterChange() async throws {
        try await reload()
        try? await refreshStorages()
    }
    /// After a failed change: show what is there now, unless the USB link itself failed.
    private func afterFailure(_ error: Error) async {
        if (error as? DriveError)?.isTransport != true { try? await afterChange() }
    }

    // MARK: Actions

    /// `automatic`: the connect at launch, which stays quiet when no Kindle is attached.
    func connect(automatic: Bool = false) {
        perform("Connecting", quietIfNoKindle: automatic) { _ in
            let c = try await self.device.connect()
            self.connection = c
            self.storageID = c.storages.first?.id ?? 0
            self.path = []; self.files = []; self.rootFolders = []; self.unreadable = 0; self.selection = []
            self.record("Connected to \(c.name) — \(c.deviceInfo)")
            try await self.open(storage: self.storageID, path: [])
        }
    }
    func disconnect() {
        perform("Disconnecting") { _ in
            try await self.device.disconnect(); self.clearConnection()
        }
    }
    func refresh() { perform("Refreshing") { _ in try await self.reload(); try await self.refreshStorages() } }
    func navigate(to folder: Entry) {
        guard folder.folder else { return }
        perform("Opening \(folder.name)") { _ in try await self.open(storage: self.storageID, path: self.path + [folder]) }
    }
    func goTo(_ depth: Int) {
        perform("Opening folder") { _ in try await self.open(storage: self.storageID, path: Array(self.path.prefix(depth))) }
    }
    func chooseStorage(_ id: UInt32) {
        perform("Opening storage") { _ in try await self.open(storage: id, path: []) }
    }
    func shortcut(_ folder: Entry) {
        perform("Opening \(folder.name)") { _ in try await self.open(storage: self.storageID, path: [folder]) }
    }
    func uploadPanel() {
        guard connection != nil, !busy else { return }
        let panel = NSOpenPanel(); panel.title = "Add files or folders to Kindle"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Add to Kindle"
        if panel.runModal() == .OK { upload(panel.urls) }
    }
    func upload(_ urls: [URL]) {
        guard connection != nil, !urls.isEmpty else { return }
        perform("Adding \(urls.count) item(s) to \(location)", kind: .copy, creates: true) { context in
            let summary: UploadSummary
            do { summary = try await self.device.upload(urls, storage: self.storageID, parent: self.parent, status: context.status) }
            catch { await self.afterFailure(error); throw error }
            if !summary.skipped.isEmpty {
                context.doneNote = "\(summary.skipped.count) skipped"
                for item in summary.skipped { self.record("Skipped: \(item)") }
            }
            if summary.uploaded > 0, Self.includesEPUB(urls, skipped: summary.skipped) { self.record(Self.epubNote) }
            try await self.afterChange()
        }
    }
    /// Whether any file that was offered for upload (folders searched) and not skipped is an `.epub`.
    nonisolated static func includesEPUB(_ urls: [URL], skipped: [String]) -> Bool {
        let skippedNames = Set(skipped.compactMap { $0.components(separatedBy: " — ").first })
        func isEPUB(_ url: URL) -> Bool {
            let name = url.lastPathComponent
            return url.pathExtension.lowercased() == "epub" && !Device.isJunk(name) && !skippedNames.contains(name)
        }
        for url in urls {
            if isEPUB(url) { return true }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true,
                  let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
            for case let child as URL in walk where isEPUB(child) { return true }
        }
        return false
    }
    func download() {
        let entries = chosen; guard !busy, !entries.isEmpty else { return }
        let panel = NSOpenPanel(); panel.title = "Save Kindle files to a folder"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        perform("Saving \(entries.count) item(s) to Mac", kind: .copy) { context in
            try await self.device.download(entries, storage: self.storageID, into: directory, status: context.status)
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
        guard connection != nil, !busy, let name = textPrompt(title: "New folder", initial: "Untitled Folder", button: "Create") else { return }
        createFolder(named: name)
    }
    func createFolder(named typed: String) {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        perform("Creating folder", creates: true) { _ in
            try await self.device.createFolder(name, self.storageID, self.parent); try await self.afterChange()
        }
    }
    func rename() {
        guard !busy, chosen.count == 1, let entry = chosen.first,
              let name = textPrompt(title: "Rename \(entry.name)", initial: entry.name, button: "Rename") else { return }
        rename(entry, to: name)
    }
    func rename(_ entry: Entry, to typed: String) {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != entry.name else { return }
        perform("Renaming") { _ in try await self.device.rename(entry, to: name, storage: self.storageID, parent: self.parent); try await self.reload() }
    }
    func delete() {
        let entries = chosen; guard !busy, !entries.isEmpty else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Permanently delete \(entries.count == 1 ? entries[0].name : "\(entries.count) items")?"
        alert.informativeText = "Folders and everything inside them will be deleted from your Kindle. This cannot be undone."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete Permanently")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        delete(entries)
    }
    /// Deletes `entries` (children of the current folder) without asking.
    func delete(_ entries: [Entry]) {
        guard connection != nil, !entries.isEmpty else { return }
        let folders = path.map(\.name)
        perform("Deleting \(entries.count) item(s)", kind: .delete) { context in
            let outcome = await self.device.delete(entries, storage: self.storageID, parent: self.parent, status: context.status)
            let time = Date().formatted(date: .omitted, time: .standard)
            for entry in outcome.verified { self.record("\(time) Deleted and verified: \(Self.itemPath(folders, entry.name))") }
            if outcome.nestedDeleted > 0 {
                self.record("\(time) Deleted \(outcome.nestedDeleted) item(s) inside folders that were not fully removed")
            }
            guard let failure = outcome.failure else { try await self.afterChange(); return }
            if failure is Cancelled {
                context.cancelNote = "\(outcome.verified.count) of \(entries.count) selected item(s) deleted" +
                    (outcome.nestedDeleted > 0 ? ", plus \(outcome.nestedDeleted) inside folders that were kept." : ".")
            }
            await self.afterFailure(failure)
            throw failure
        }
    }
}
