import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CMTP

@main struct KindleDriveApp: App {
    @StateObject private var model = BrowserModel()
    init() {
        if CommandLine.arguments.contains("--probe") || CommandLine.arguments.contains("--smoke-test") {
            SmokeTest.run(mutate: CommandLine.arguments.contains("--smoke-test"))
        }
        NSApplication.shared.setActivationPolicy(.regular)
    }
    var body: some Scene {
        WindowGroup("Kindle Drive") { BrowserView(model: model) }
            .defaultSize(width: 980, height: 640)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Add Files…", action: model.uploadPanel).keyboardShortcut("o").disabled(model.busy || model.connection == nil)
                    Button("New Folder…", action: model.newFolder).keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.busy || model.connection == nil)
                }
                CommandGroup(after: .pasteboard) {
                    Button("Select All", action: model.selectAll).keyboardShortcut("a").disabled(model.busy || model.connection == nil)
                }
                CommandMenu("Kindle") {
                    Button("Refresh", action: model.refresh).keyboardShortcut("r").disabled(model.busy || model.connection == nil)
                    Button("Save to Mac…", action: model.download).keyboardShortcut("s", modifiers: [.command, .shift]).disabled(model.busy || model.chosen.isEmpty)
                    Button("Rename…", action: model.rename).disabled(model.busy || model.chosen.count != 1)
                    Button("Delete…", action: model.delete).keyboardShortcut(.delete, modifiers: .command).disabled(model.busy || model.chosen.isEmpty)
                    Toggle("Show Hidden Files", isOn: $model.showHidden).keyboardShortcut(".", modifiers: [.command, .shift])
                }
            }
    }
}

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    @State private var dropTarget = false
    @State private var showHistory = false
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Image(systemName: "book.closed.fill").font(.system(size: 26)).foregroundStyle(.orange)
                    VStack(alignment: .leading) {
                        Text("Kindle Drive").font(.headline)
                        Text("Your books. Your USB cable.").font(.caption).foregroundStyle(.secondary)
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
                        Divider().padding(.vertical, 6)
                        sideButton("Documents", icon: "doc.text") { model.shortcut("documents") }
                        sideButton("Books", icon: "books.vertical") { model.shortcut("books") }
                        sideButton("KOReader", icon: "book") { model.shortcut("koreader") }
                    }.disabled(model.busy)
                }
                Spacer()
                Text("Files with matching names are kept as separate copies.").font(.caption).foregroundStyle(.secondary)
                if model.connection != nil {
                    Button("Disconnect", systemImage: "eject", action: model.disconnect).disabled(model.busy)
                } else {
                    Button("Connect Kindle", systemImage: "cable.connector", action: model.connect).buttonStyle(.borderedProminent).tint(.orange).disabled(model.busy)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 290)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Button { model.goTo(0) } label: { Image(systemName: "internaldrive") }.help("Storage root")
                    ForEach(Array(model.path.enumerated()), id: \.element.id) { index, entry in
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        Button(entry.name) { model.goTo(index + 1) }.lineLimit(1)
                    }
                    Spacer()
                    Text(model.selection.isEmpty ? "\(model.visible.count) items" : model.selectionSummary).font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.plain).padding(14).disabled(model.busy || model.connection == nil)
                Divider()
                if model.connection == nil {
                    ContentUnavailableView {
                        Label("A little room for your library", systemImage: "books.vertical")
                    } description: {
                        Text("Connect your Kindle by USB and enable file transfer.\nClose other Kindle or MTP apps before connecting.")
                    } actions: {
                        Button("Connect Kindle", action: model.connect).buttonStyle(.borderedProminent).tint(.orange).disabled(model.busy)
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
                HStack(spacing: 12) {
                    if model.busy { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.status).font(.caption).lineLimit(1)
                        if model.transferring { ProgressView(value: model.progress).tint(.orange).frame(maxWidth: 300) }
                    }
                    Spacer()
                    if model.transferring { Button("Cancel") { kd_cancel() }.controlSize(.small) }
                    Button { showHistory.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }.buttonStyle(.plain).help("Activity")
                        .popover(isPresented: $showHistory) {
                            ScrollView { VStack(alignment: .leading, spacing: 12) {
                                Text("Activity").font(.headline)
                                if model.history.isEmpty { Text("No activity yet.").foregroundStyle(.secondary) }
                                ForEach(Array(model.history.enumerated()), id: \.offset) { _, item in Text(item).font(.caption).textSelection(.enabled) }
                            }.padding().frame(width: 380, alignment: .leading) }.frame(maxHeight: 350)
                        }
                }.padding(12)
            }
            .navigationTitle(model.path.last?.name ?? "Kindle Drive")
            .searchable(text: $model.search, prompt: "Search this folder")
            .onChange(of: model.search) { model.trimSelection() }
            .onChange(of: model.showHidden) { model.trimSelection() }
            .toolbar {
                ToolbarItemGroup {
                    Button { model.goTo(max(0, model.path.count - 1)) } label: { Image(systemName: "arrow.up") }.help("Parent folder").disabled(model.path.isEmpty || model.busy)
                    Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }.help("Refresh").disabled(model.connection == nil || model.busy)
                    Button(action: model.newFolder) { Image(systemName: "folder.badge.plus") }.help("New folder").disabled(model.connection == nil || model.busy)
                    Button(action: model.download) { Image(systemName: "square.and.arrow.down") }.help("Save selected items to Mac").disabled(model.chosen.isEmpty || model.busy)
                    Button(action: model.delete) { Image(systemName: "trash") }.help("Delete selected items").disabled(model.chosen.isEmpty || model.busy)
                    Button(action: model.uploadPanel) { Label("Add Files", systemImage: "plus") }.disabled(model.connection == nil || model.busy)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 480)
        .alert("Couldn't complete the operation", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .task { model.connect(); NSApplication.shared.activate(ignoringOtherApps: true) }
    }
    func sideButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6) }.buttonStyle(.plain)
    }
}
func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) }
