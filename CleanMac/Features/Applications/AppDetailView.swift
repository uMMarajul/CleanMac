import AppKit
import Charts
import SwiftData
import SwiftUI

/// One app: where its data lives, what is inside the big folders, and actions
/// (Clear Cache, Remove Logs, Uninstall). All removals go through `CleanupEngine`.
struct AppDetailView: View {
    let app: InstalledApp
    let appFolders: [URL]

    @Query private var allApps: [InstalledApp]
    @EnvironmentObject private var scan: ScanStore
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var files: [AssociatedFile]?
    @State private var selected = Set<String>()
    @State private var removeApp = true
    @State private var keepUserData = true
    @State private var pending: Action?
    @State private var working = false
    @State private var report: CleanupReport?
    @State private var expanded = Set<String>()
    @State private var insides: [String: [(name: String, size: Int64)]] = [:]

    enum Action: Identifiable {
        case uninstall, clearCache, removeLogs
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let files {
                List {
                    breakdownSection(files)
                    actionsSection(files)
                    applicationSection
                    leftoversSection(files)
                }
            } else {
                ProgressView("Finding \(app.name)'s files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 640)
        .task { await load() }
        .onChange(of: keepUserData) { _, keep in
            if let files { selected = AppInventory.defaultSelection(files, keepUserData: keep) }
        }
        .confirmationDialog(
            pending.map(confirmTitle) ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let action = pending {
                Button(action == .uninstall && removeApp && appRefusal == nil ? "Uninstall" : "Move to Trash", role: .destructive) {
                    run(action)
                }
            }
        } message: {
            Text("Everything goes to the Trash. You can put items back from Cleanup History.")
        }
        .sheet(isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            if let report {
                CleanupReportView(report: report) { finishReport() }
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.installationPath))
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.title2.bold())
                Text("\(app.version) · \(app.bundleIdentifier)")
                    .foregroundStyle(.secondary)
                Text("Last opened: \(app.lastOpenedDate?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatBytes(app.bundleSize + AppInventory.totalSize(files ?? [])))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("app and data").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func breakdownSection(_ files: [AssociatedFile]) -> some View {
        let slices = [(kind: "App", bytes: app.bundleSize)] + AppInventory.breakdown(files).filter { $0.bytes > 0 }
        return Section("Where the space goes") {
            Chart(slices, id: \.kind) { slice in
                BarMark(x: .value("Size", Double(slice.bytes)), y: .value("App", app.name))
                    .foregroundStyle(by: .value("Location", slice.kind))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 80)
            ForEach(slices, id: \.kind) { slice in
                HStack {
                    Text(slice.kind)
                    Spacer()
                    Text(formatBytes(slice.bytes)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    private func actionsSection(_ files: [AssociatedFile]) -> some View {
        let cache = items(for: .clearCache, in: files)
        let logs = items(for: .removeLogs, in: files)
        return Section {
            HStack {
                if cache.isEmpty && logs.isEmpty {
                    Text("No caches or logs to clear.").foregroundStyle(.secondary)
                }
                if !cache.isEmpty {
                    Button("Clear Cache (\(formatBytes(AppInventory.totalSize(cache))))") { pending = .clearCache }
                        .disabled(runningName != nil || working)
                }
                if !logs.isEmpty {
                    Button("Remove Logs (\(formatBytes(AppInventory.totalSize(logs))))") { pending = .removeLogs }
                        .disabled(runningName != nil || working)
                }
                Spacer()
            }
        } header: {
            Text("Quick actions")
        } footer: {
            Text(runningName.map { "Quit \($0) to clear its cache or logs." }
                 ?? "Clearing the cache keeps the app and your data. The app rebuilds its cache as you use it.")
        }
    }

    private var applicationSection: some View {
        Section("Application") {
            HStack {
                Toggle("", isOn: $removeApp)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(appRefusal != nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.url.lastPathComponent)
                    Text(appRefusal ?? app.installationPath)
                        .font(.caption)
                        .foregroundStyle(appRefusal == nil ? Color.secondary : Color.orange)
                }
                Spacer()
                Text(formatBytes(app.bundleSize)).monospacedDigit()
            }
        }
    }

    private func leftoversSection(_ files: [AssociatedFile]) -> some View {
        Section {
            if files.isEmpty {
                Text("No leftover files found.").foregroundStyle(.secondary)
            }
            ForEach(files) { file in
                if file.isFolder {
                    DisclosureGroup(isExpanded: Binding(
                        get: { expanded.contains(file.path) },
                        set: { open in
                            if open { expanded.insert(file.path) } else { expanded.remove(file.path) }
                        }
                    )) {
                        inside(file)
                    } label: {
                        fileRow(file)
                    }
                } else {
                    fileRow(file)
                }
            }
        } header: {
            HStack {
                Text("Data and leftovers (\(files.count))")
                Spacer()
                Toggle("Keep preferences and user data", isOn: $keepUserData)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        } footer: {
            Text("Only files matching \(app.name)'s exact bundle identifier or name are listed. Keychain passwords, documents and folders shared with other apps are never removed.")
        }
    }

    private func fileRow(_ file: AssociatedFile) -> some View {
        let note: String? = file.sharedWith.map { "Shared with \($0). Kept." }
            ?? (file.byNameOnly ? "Matched by name only. Check before removing." : nil)
        return HStack {
            Toggle("", isOn: Binding(
                get: { selected.contains(file.path) },
                set: { on in
                    if on { selected.insert(file.path) } else { selected.remove(file.path) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(file.sharedWith != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(file.kind): \(file.url.lastPathComponent)")
                Text(note ?? file.path)
                    .font(.caption)
                    .foregroundStyle(note == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            SafetyBadge(safety: file.safety)
            Text(formatBytes(file.size))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
        }
        .contextMenu {
            Button("Reveal in Finder") { revealInFinder([file.url]) }
        }
    }

    /// Largest entries inside a folder, measured when the row is expanded.
    @ViewBuilder
    private func inside(_ file: AssociatedFile) -> some View {
        if let entries = insides[file.path] {
            if entries.isEmpty {
                Text("Empty").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.name) { entry in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(entry.name).font(.callout)
                    Spacer()
                    Text(formatBytes(entry.size)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Reveal in Finder") { revealInFinder([file.url.appending(path: entry.name)]) }
                }
            }
        } else {
            ProgressView().controlSize(.small)
                .task {
                    let path = file.path
                    insides[path] = await Task.detached { AppInventory.largestChildren(of: path) }.value
                }
        }
    }

    private var footer: some View {
        HStack {
            if working {
                ProgressView().controlSize(.small)
                Text("Moving to Trash…").foregroundStyle(.secondary)
            } else {
                Text("\(formatBytes(uninstallBytes)) selected").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(removeApp && appRefusal == nil ? "Uninstall…" : "Remove Selected…") { pending = .uninstall }
                .buttonStyle(.borderedProminent)
                .disabled(working || (selectedLeftovers.isEmpty && !(removeApp && appRefusal == nil)))
        }
        .padding()
    }

    // MARK: Logic

    private var runningName: String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).first
            .map { $0.localizedName ?? app.name }
    }

    private var appRefusal: String? {
        let running = runningName.map { [(bundleID: app.bundleIdentifier, name: $0)] } ?? []
        return CleanupEngine.appRefusal(
            appPath: app.installationPath, bundleID: app.bundleIdentifier,
            appFolders: appFolders, runningApps: running
        )
    }

    private var selectedLeftovers: [AssociatedFile] {
        (files ?? []).filter { selected.contains($0.path) && $0.sharedWith == nil }
    }

    private var uninstallBytes: Int64 {
        AppInventory.totalSize(selectedLeftovers) + (removeApp && appRefusal == nil ? app.bundleSize : 0)
    }

    private func items(for action: Action, in files: [AssociatedFile]) -> [AssociatedFile] {
        switch action {
        case .uninstall: selectedLeftovers
        case .clearCache: files.filter { ["Caches", "App Cache"].contains($0.kind) && $0.safety == .safe }
        case .removeLogs: files.filter { $0.kind == "Logs" && $0.safety == .safe }
        }
    }

    private func confirmTitle(_ action: Action) -> String {
        let leftovers = items(for: action, in: files ?? [])
        let bytes = AppInventory.totalSize(leftovers)
        switch action {
        case .uninstall:
            return removeApp && appRefusal == nil
                ? "Uninstall \(app.name) and \(leftovers.count) leftover item\(leftovers.count == 1 ? "" : "s") (\(formatBytes(uninstallBytes)))?"
                : "Move \(leftovers.count) item\(leftovers.count == 1 ? "" : "s") (\(formatBytes(bytes))) to the Trash?"
        case .clearCache:
            return "Clear \(app.name)'s cache (\(formatBytes(bytes)))?"
        case .removeLogs:
            return "Remove \(app.name)'s logs (\(formatBytes(bytes)))?"
        }
    }

    private func load() async {
        let bundleID = app.bundleIdentifier
        let name = app.name
        let groups = app.appGroups
        let home = scan.home
        var found = await Task.detached {
            AppInventory.associatedFiles(bundleID: bundleID, name: name, groups: groups, home: home)
        }.value
        let others = allApps.map { (bundleID: $0.bundleIdentifier, name: $0.name, groups: $0.appGroups) }
        for index in found.indices where found[index].kind == "Group Container" {
            found[index].sharedWith = AppInventory.sharing(
                group: found[index].url.lastPathComponent, excluding: bundleID, apps: others
            )
        }
        files = found
        insides = [:]
        selected = AppInventory.defaultSelection(found, keepUserData: keepUserData)
        removeApp = appRefusal == nil
        app.associatedDataSize = AppInventory.totalSize(found)
    }

    private func run(_ action: Action) {
        let home = scan.home
        let removesApp = action == .uninstall && removeApp && appRefusal == nil
        let appItem = removesApp
            ? ScanItem(path: app.installationPath, size: app.bundleSize, fileCount: 0, modified: nil, isFolder: true, category: nil)
            : nil
        let leftovers = items(for: action, in: files ?? []).map {
            ScanItem(
                path: $0.path, size: $0.size, fileCount: 0, modified: nil, isFolder: $0.isFolder,
                category: StorageCategory.category(forPath: $0.path, home: home)
                    ?? (StorageCategory.supportCacheOwner(path: $0.path, home: home) != nil ? .applicationCaches : nil)
            )
        }
        let running = NSWorkspace.shared.runningApplications.compactMap { running in
            running.bundleIdentifier.map { (bundleID: $0, name: running.localizedName ?? $0) }
        }
        let operation = switch action {
        case .uninstall: removesApp ? "Uninstalled \(app.name)" : "Removed \(app.name) data"
        case .clearCache: "Cleared \(app.name) cache"
        case .removeLogs: "Removed \(app.name) logs"
        }
        let bundleID = app.bundleIdentifier
        let folders = appFolders
        working = true

        Task {
            let result = await CleanupEngine.uninstall(
                app: appItem, bundleID: bundleID, leftovers: leftovers,
                appFolders: folders, home: home, runningApps: running
            )
            for entry in result.cleaned {
                context.insert(CleanupRecord(
                    filePath: entry.trashPath ?? "",
                    originalLocation: entry.item.path,
                    deletedSize: entry.size,
                    operationType: operation,
                    category: entry.item.category?.rawValue
                ))
            }
            try? context.save()
            scan.applyCleanup(result.cleaned)
            working = false
            report = result
        }
    }

    /// After an uninstall the app is gone, so close; otherwise refresh the sizes.
    private func finishReport() {
        let uninstalled = report?.cleaned.contains { $0.item.path == app.installationPath } ?? false
        report = nil
        if uninstalled {
            context.delete(app)
            try? context.save()
            dismiss()
        } else {
            Task { await load() }
        }
    }
}
