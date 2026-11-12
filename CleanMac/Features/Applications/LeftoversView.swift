import AppKit
import SwiftData
import SwiftUI

/// Files left behind by apps that are no longer installed.
struct LeftoversView: View {
    @Query private var apps: [InstalledApp]
    @EnvironmentObject private var scan: ScanStore
    @Environment(\.dismiss) private var dismiss

    @State private var items: [OrphanItem]?
    @State private var selected = Set<String>()
    @State private var pending: [ScanItem]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Leftovers of Removed Apps").font(.title2.bold())
                Text("Library items named after apps that are not installed. Review each one: the app may be on another drive, or you may reinstall it.")
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            if let items {
                if items.isEmpty {
                    ContentUnavailableView("No leftovers found", systemImage: "checkmark.circle")
                } else {
                    list(items)
                }
            } else {
                ProgressView("Looking for leftovers…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                let chosen = (items ?? []).filter { selected.contains($0.path) }
                Text("\(chosen.count) selected · \(formatBytes(chosen.reduce(0) { $0 + $1.size }))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash…") {
                    pending = chosen.map {
                        ScanItem(path: $0.path, size: $0.size, fileCount: 0, modified: nil, isFolder: true,
                                 category: StorageCategory.category(forPath: $0.path, home: scan.home))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(chosen.isEmpty)
            }
            .padding()
        }
        .frame(width: 680, height: 560)
        .task { await load() }
        .cleanupFlow(pending: $pending)
        .onChange(of: scan.cleanupVersion) { Task { await load() } }
    }

    private func list(_ items: [OrphanItem]) -> some View {
        let byApp = Dictionary(grouping: items, by: \.bundleID)
            .sorted { $0.value.reduce(0) { $0 + $1.size } > $1.value.reduce(0) { $0 + $1.size } }
        return List {
            ForEach(byApp, id: \.key) { bundleID, files in
                Section {
                    ForEach(files) { file in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { selected.contains(file.path) },
                                set: { on in
                                    if on { selected.insert(file.path) } else { selected.remove(file.path) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(file.kind): \(file.url.lastPathComponent)")
                                Text(file.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            Spacer()
                            SafetyBadge(safety: .reviewRequired)
                            Text(formatBytes(file.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                        .contextMenu {
                            Button("Reveal in Finder") { revealInFinder([file.url]) }
                        }
                    }
                } header: {
                    HStack {
                        Text(bundleID)
                        if let related = files.first?.relatedApp {
                            Text("· same developer as \(related), which may still use it")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        let installed = apps.map { (bundleID: $0.bundleIdentifier, name: $0.name) }
            + NSWorkspace.shared.runningApplications.compactMap { app in
                app.bundleIdentifier.map { (bundleID: $0, name: app.localizedName ?? $0) }
            }
        let home = scan.home
        items = await Task.detached {
            OrphanFinder.find(home: home, installed: installed) { id in
                // LaunchServices knows apps anywhere: other drives, /System/Applications, …
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
            }
        }.value
        selected.formIntersection(Set((items ?? []).map(\.path)))
    }
}
