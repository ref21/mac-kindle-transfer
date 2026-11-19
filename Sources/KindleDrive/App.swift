import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CMTP

@main struct KindleDriveApp: App {
    /// `--demo`: an in-memory Kindle. Decided once; the process then never uses USB.
    static let demo = CommandLine.arguments.contains("--demo")
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = KindleDriveApp.makeModel()
    init() {
        let arguments = CommandLine.arguments
        let hardware = arguments.contains("--probe") || arguments.contains("--smoke-test")
        if hardware && Self.demo {
            fputs("--demo cannot be combined with --probe or --smoke-test.\n", stderr); exit(64)
        }
        if hardware { SmokeTest.run(mutate: arguments.contains("--smoke-test")) }
        NSApplication.shared.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    /// The only place that chooses the transport.
    static func makeModel() -> BrowserModel {
        guard demo else { return BrowserModel(device: Device(transport: MTPTransport())) }
        let fake = FakeTransport.sample()
        fake.delay = 0.2            // per call, so the busy state and Cancel are visible
        fake.transferTime = 1.5     // per file copied
        return BrowserModel(device: Device(transport: fake), demo: true, progress: { fake.progress.value })
    }
    var body: some Scene {
        WindowGroup("Kindle Drive") { BrowserView(model: model).onAppear { appDelegate.model = model } }
            .defaultSize(width: 980, height: 640)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Add Files…", action: model.uploadPanel).keyboardShortcut("o").disabled(model.busy || model.connection == nil)
                    Button("New Folder…", action: model.newFolder).keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.busy || model.connection == nil)
                }
                CommandGroup(after: .pasteboard) {
                    // Kept until a check in --demo shows that the standard Edit ▸ Select All
                    // selects the table's rows. A text field with focus keeps Cmd-A.
                    Button("Select All", action: selectAll).keyboardShortcut("a")
                }
                CommandMenu("Kindle") {
                    Button("Refresh", action: model.refresh).keyboardShortcut("r").disabled(model.busy || model.connection == nil)
                    Button("Save to Mac…", action: model.download).keyboardShortcut("s", modifiers: [.command, .shift]).disabled(model.busy || model.chosen.isEmpty)
                    Button("Rename…", action: model.rename).disabled(model.busy || model.chosen.count != 1)
                    // No key shortcut: the Delete key works on the table (onDeleteCommand), and
                    // Cmd-Delete stays with a text field that has focus.
                    Button("Delete…", action: model.delete).disabled(model.busy || model.chosen.isEmpty)
                    Toggle("Show Hidden Files", isOn: $model.showHidden).keyboardShortcut(".", modifiers: [.command, .shift])
                }
            }
    }
    private func selectAll() {
        if let text = NSApp.keyWindow?.firstResponder as? NSText { text.selectAll(nil); return }
        guard !model.busy, model.connection != nil else { return }
        model.selectAll()
    }
}

/// Window-close and quit behaviour while an operation runs. Does nothing in its
/// initialiser: `--probe`/`--smoke-test` exit inside `App.init`.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: BrowserModel?
    private var quitPending = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(model?.busy ?? false)   // a running transfer keeps going; the Dock icon reopens the window
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.busy else { return .terminateNow }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "An operation is still running on your Kindle. Stop it and quit?"
        alert.addButton(withTitle: "Keep Running"); alert.addButton(withTitle: "Stop and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        guard model.busy else { return .terminateNow }   // it finished while the alert was open
        kd_cancel()
        quitPending = true
        model.whenIdle { [weak self] in self?.replyToQuit() }
        // A default-mode Timer does not fire while termination is pending; this does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated { self?.replyToQuit(timedOut: true) }
        }
        return .terminateLater
    }
    /// Safe to call more than once; only the first call while a quit is pending replies.
    /// Shows anything the user must act on first: the app's own alert would never appear
    /// because the app quits right after this reply.
    private func replyToQuit(timedOut: Bool = false) {
        guard quitPending else { return }
        quitPending = false
        var warning = model?.error
        if timedOut, model?.busy == true {
            warning = "The operation did not stop in time. If a file was being copied, an incomplete copy may remain on the Kindle. Check the folder after reconnecting."
        }
        if let warning {
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "Before Kindle Drive quits"
            alert.informativeText = warning
            alert.addButton(withTitle: "Quit")
            alert.runModal()
        }
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    @State private var dropTarget = false
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Image(systemName: "book.closed.fill").font(.system(size: 26)).foregroundStyle(.orange)
                    VStack(alignment: .leading) {
                        Text("Kindle Drive").font(.headline)
                        if model.demo {
                            Text("Demo — sample files, no USB").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        } else {
                            Text("Your books. Your USB cable.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.top, 18)
                VStack(alignment: .leading, spacing: 10) {
                    Text("DEVICE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Label(model.connection?.name ?? "No Kindle connected", systemImage: "externaldrive.fill").font(.subheadline)
                    if let s = model.storage {
                        ProgressView(value: Double(s.capacity - min(s.free, s.capacity)), total: Double(max(1,s.capacity))).tint(.orange)
                        Text("\(bytes(s.free)) free of \(bytes(s.capacity))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let connection = model.connection {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(connection.storages) { s in
                            sideButton(s.name, icon: "internaldrive") { model.chooseStorage(s.id) }
                        }
                        if !model.shortcuts.isEmpty {
                            Divider().padding(.vertical, 6)
                            ForEach(model.shortcuts) { folder in
                                sideButton(folder.name, icon: shortcutIcon(folder.name)) { model.shortcut(folder) }
                            }
                        }
                    }.disabled(model.busy)
                }
                Spacer()
                Text("Files with matching names are kept as separate copies.").font(.caption).foregroundStyle(.secondary)
                if model.connection != nil {
                    Button("Disconnect", systemImage: "eject", action: model.disconnect).disabled(model.busy)
                } else {
                    Button("Connect Kindle", systemImage: "cable.connector") { model.connect() }.buttonStyle(.borderedProminent).tint(.orange).disabled(model.busy)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 290)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Button { model.goTo(0) } label: { Label("Storage Root", systemImage: "internaldrive").labelStyle(.iconOnly) }.help("Storage root")
                    ForEach(Array(model.path.enumerated()), id: \.element.id) { index, entry in
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        Button(entry.name) { model.goTo(index + 1) }.lineLimit(1)
                    }
                    Spacer()
                    if let note = model.unreadableNote {
                        Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(model.itemCount).font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.plain).padding(14).disabled(model.busy || model.connection == nil)
                Divider()
                if model.connection == nil {
                    ContentUnavailableView {
                        Label("A little room for your library", systemImage: "books.vertical")
                    } description: {
                        Text("Connect your Kindle by USB and enable file transfer.\nClose other Kindle or MTP apps before connecting.")
                    } actions: {
                        Button("Connect Kindle") { model.connect() }.buttonStyle(.borderedProminent).tint(.orange).disabled(model.busy)
                    }.frame(maxHeight: .infinity)
                } else {
                    Table(model.visible, selection: $model.selection, sortOrder: $model.sortOrder) {
                        TableColumn("Name", value: \.name, comparator: .localizedStandard) { entry in
                            HStack(spacing: 9) {
                                Image(systemName: entry.folder ? "folder.fill" : "doc.text").foregroundStyle(entry.folder ? .orange : .secondary)
                                Text(entry.name).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.width(min: 220, ideal: 380)
                        TableColumn("Size", value: \.size) { entry in Text(entry.folder ? "—" : bytes(entry.size)).foregroundStyle(.secondary).monospacedDigit() }.width(90)
                        TableColumn("Modified", value: \.modified) { entry in Text(entry.modified.timeIntervalSince1970 > 0 ? entry.modified.formatted(date: .abbreviated, time: .omitted) : "—").foregroundStyle(.secondary) }.width(115)
                    }
                    .contextMenu(forSelectionType: UInt32.self) { ids in
                        Button("Open Folder") { if let f = model.files.first(where: { ids.contains($0.id) && $0.folder }) { model.navigate(to: f) } }.disabled(ids.count != 1 || !model.files.contains(where: { ids.contains($0.id) && $0.folder }))
                        Button("Save to Mac…") { model.selection = ids; model.download() }.disabled(ids.isEmpty)
                        Button("Rename…") { model.selection = ids; model.rename() }.disabled(ids.count != 1)
                        Divider()
                        Button("Delete…", role: .destructive) { model.selection = ids; model.delete() }.disabled(ids.isEmpty)
                    } primaryAction: { ids in
                        if let folder = model.files.first(where: { ids.contains($0.id) && $0.folder }), !model.busy { model.navigate(to: folder) }
                    }
                    .onDeleteCommand { if !model.busy { model.delete() } }
                    .disabled(model.busy)
                    .overlay { if model.visible.isEmpty { ContentUnavailableView(model.search.isEmpty ? "This folder is empty" : "No matching files", systemImage: "folder", description: Text("Drop files here or use Add Files." )).allowsHitTesting(false) } }
                    .overlay { if dropTarget { RoundedRectangle(cornerRadius: 12).stroke(.orange, style: StrokeStyle(lineWidth: 3, dash: [8])).padding(10).allowsHitTesting(false) } }
                    .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in
                        guard !model.busy else { return false }
                        Task { @MainActor in
                            var urls: [URL] = []
                            for provider in providers {
                                let url: URL? = await withCheckedContinuation { continuation in
                                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                                }
                                if let url { urls.append(url) }
                            }
                            model.upload(urls)
                        }
                        return true
                    }
                }
                Divider()
                StatusBar(model: model, monitor: model.monitor)
            }
            .navigationTitle((model.path.last?.name ?? "Kindle Drive") + (model.demo ? " — Demo" : ""))
            .searchable(text: $model.search, prompt: "Search this folder")
            .onChange(of: model.search) { model.trimSelection() }
            .onChange(of: model.showHidden) { model.trimSelection() }
            .toolbar {
                ToolbarItemGroup {
                    Button { model.goTo(max(0, model.path.count - 1)) } label: { Label("Parent Folder", systemImage: "arrow.up").labelStyle(.iconOnly) }.help("Parent folder").disabled(model.path.isEmpty || model.busy)
                    Button(action: model.refresh) { Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }.help("Refresh").disabled(model.connection == nil || model.busy)
                    Button(action: model.newFolder) { Label("New Folder", systemImage: "folder.badge.plus").labelStyle(.iconOnly) }.help("New folder").disabled(model.connection == nil || model.busy)
                    Button(action: model.download) { Label("Save to Mac", systemImage: "square.and.arrow.down").labelStyle(.iconOnly) }.help("Save selected items to Mac").disabled(model.chosen.isEmpty || model.busy)
                    Button(action: model.delete) { Label("Delete", systemImage: "trash").labelStyle(.iconOnly) }.help("Delete selected items").disabled(model.chosen.isEmpty || model.busy)
                    Button(action: model.uploadPanel) { Label("Add Files", systemImage: "plus") }.disabled(model.connection == nil || model.busy)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 480)
        .alert("Couldn't complete the operation", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .task {
            // Not again when the window is reopened while connected.
            if model.connection == nil { model.connect(automatic: true) }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
    func sideButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6) }.buttonStyle(.plain)
    }
    func shortcutIcon(_ name: String) -> String {
        switch name.lowercased() {
        case "documents": "doc.text"
        case "books": "books.vertical"
        case "audible": "headphones"
        case "fonts": "textformat"
        case "screenshots": "camera.viewfinder"
        default: "book"
        }
    }
}

/// The status line, progress and Activity. The only view that observes the transfer
/// monitor, so progress ticks re-render nothing else.
struct StatusBar: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var monitor: TransferMonitor
    @State private var showHistory = false
    var body: some View {
        HStack(spacing: 12) {
            if model.busy { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 4) {
                Text(monitor.item.isEmpty ? model.status : monitor.item).font(.caption).lineLimit(1)
                if monitor.mode == .copying { ProgressView(value: monitor.progress).tint(.orange).frame(maxWidth: 300) }
            }
            Spacer()
            if monitor.mode != .idle { Button("Cancel") { kd_cancel() }.controlSize(.small) }
            Button { showHistory.toggle() } label: { Label("Activity", systemImage: "clock.arrow.circlepath").labelStyle(.iconOnly) }.buttonStyle(.plain).help("Activity")
                .popover(isPresented: $showHistory) {
                    ScrollView { VStack(alignment: .leading, spacing: 12) {
                        Text("Activity").font(.headline)
                        if model.history.isEmpty { Text("No activity yet.").foregroundStyle(.secondary) }
                        ForEach(Array(model.history.enumerated()), id: \.offset) { _, item in Text(item).font(.caption).textSelection(.enabled) }
                    }.padding().frame(width: 380, alignment: .leading) }.frame(maxHeight: 350)
                }
        }.padding(12)
    }
}
func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) }
