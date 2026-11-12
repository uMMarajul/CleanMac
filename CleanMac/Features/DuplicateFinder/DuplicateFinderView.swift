import AppKit
import QuickLook
import SwiftUI

struct DuplicateFinderView: View {
    @EnvironmentObject private var store: DuplicateStore
    @EnvironmentObject private var scan: ScanStore
    @EnvironmentObject private var permissions: PermissionManager

    @AppStorage("duplicateFolders") private var foldersText = ""
    @AppStorage("duplicateMinSize") private var minSize = 1_000_000

    @State private var selected = Set<String>()
    @State private var pending: [ScanItem]?
    @State private var preview: URL?
    @State private var editingFolders = false

    private var folders: [String] {
        foldersText.isEmpty
            ? DuplicateFinder.defaultFolders(home: scan.home).filter { FileManager.default.fileExists(atPath: $0) }
            : foldersText.split(separator: "\n").map(String.init)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let groups = store.groups, !groups.isEmpty {
                bottomBar(groups)
            }
        }
        // Keep the header at the top even when the content below is a short message.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .cleanupFlow(pending: $pending)
        .quickLookPreview($preview)
        .onChange(of: store.resultID) { resetSelection() }
        .onChange(of: scan.cleanupVersion) {
            store.dropMissing()
            selected = selected.filter { FileManager.default.fileExists(atPath: $0) }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Looks in: \(folders.map { URL(filePath: $0).lastPathComponent }.joined(separator: ", "))")
                    .lineLimit(1)
                Text("Exact copies only, compared by content. The Photos library is not checked; use the Duplicates album in Photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Folders…") { editingFolders = true }
                .popover(isPresented: $editingFolders) { folderEditor }
            Picker("Min size", selection: $minSize) {
                Text("Over 1 MB").tag(1_000_000)
                Text("Over 10 MB").tag(10_000_000)
                Text("Over 100 MB").tag(100_000_000)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            if store.scanning {
                Button("Cancel") { store.cancel() }
            } else {
                Button(store.groups == nil ? "Find Duplicates" : "Scan Again") {
                    store.start(folders: folders, minSize: Int64(minSize))
                }
                .buttonStyle(.borderedProminent)
                .disabled(folders.isEmpty)
            }
        }
        .padding()
    }

    private var content: some View {
        contentBody.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var contentBody: some View {
        if store.scanning {
            VStack(spacing: 10) {
                ProgressView()
                Text("Checked \(store.filesChecked.formatted()) files…").monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let groups = store.groups {
            if groups.isEmpty {
                ContentUnavailableView("No duplicates found", systemImage: "checkmark.circle",
                                       description: Text("No identical files over the minimum size in these folders."))
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.files) { file in
                                fileRow(file, in: group)
                            }
                        } header: {
                            Text("\(group.files.count) copies · \(formatBytes(group.size)) each · \(formatBytes(group.wasted)) extra")
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("Find duplicate files", systemImage: "doc.on.doc")
            } description: {
                Text("CleanMac compares file contents, not just names, and always keeps at least one copy of each file.")
            } actions: {
                Button("Find Duplicates") { store.start(folders: folders, minSize: Int64(minSize)) }
                    .disabled(folders.isEmpty)
            }
        }
    }

    private func fileRow(_ file: DuplicateFile, in group: DuplicateGroup) -> some View {
        let isSelected = selected.contains(file.path)
        let othersSelected = group.files.filter { $0.path != file.path && selected.contains($0.path) }.count
        // The last unselected copy cannot be selected: one copy always stays.
        let isLastKept = !isSelected && othersSelected == group.files.count - 1
        return HStack {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { on in
                    if on { selected.insert(file.path) } else { selected.remove(file.path) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(isLastKept)
            .help(isLastKept ? "At least one copy is always kept" : "Select to move to the Trash")
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(file.name)
                    if !isSelected {
                        Text("Keep")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Text(file.modified?.formatted(date: .abbreviated, time: .omitted) ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                preview = file.url
            } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .help("Quick Look")
        }
        .contextMenu {
            Button("Reveal in Finder") { revealInFinder([file.url]) }
        }
    }

    private func bottomBar(_ groups: [DuplicateGroup]) -> some View {
        let files = DuplicateFinder.removable(groups, selected: selected)
        let bytes = groups.reduce(Int64(0)) { total, group in
            total + Int64(group.files.filter { files.map(\.path).contains($0.path) }.count) * group.size
        }
        return HStack {
            Text("\(groups.count) groups · \(formatBytes(groups.reduce(0) { $0 + $1.wasted })) in extra copies")
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(files.count) selected · \(formatBytes(bytes))")
            Button("Move to Trash") {
                pending = groups.flatMap { group in
                    group.files.filter { file in files.contains { $0.path == file.path } }.map {
                        ScanItem(path: $0.path, size: group.size, fileCount: 1, modified: $0.modified, isFolder: false,
                                 category: StorageCategory.category(forPath: $0.path, home: scan.home))
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(files.isEmpty)
        }
        .padding()
        .background(.bar)
    }

    private var folderEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Folders to search").font(.headline)
            ForEach(folders, id: \.self) { folder in
                HStack {
                    Text(folder).font(.caption).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button {
                        foldersText = folders.filter { $0 != folder }.joined(separator: "\n")
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Add Folder…") { addFolder() }
                Button("Reset to Defaults") { foldersText = "" }
            }
            if !permissions.hasFullDiskAccess {
                Text("Without Full Disk Access, macOS may ask before CleanMac reads each folder.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .frame(width: 380)
    }

    // MARK: Helpers

    private func resetSelection() {
        selected = Set((store.groups ?? []).flatMap { group in
            let keep = DuplicateFinder.suggestedKeep(group, home: scan.home)
            return group.files.map(\.path).filter { $0 != keep }
        })
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        foldersText = Array(Set(folders + [url.path])).sorted().joined(separator: "\n")
    }
}
