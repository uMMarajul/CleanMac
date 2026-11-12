import AppKit
import SwiftData
import SwiftUI

struct ApplicationsView: View {
    @Query(sort: \InstalledApp.name) private var apps: [InstalledApp]
    @EnvironmentObject private var store: AppsStore
    @Environment(\.modelContext) private var context

    @AppStorage("extraAppFolders") private var extraFolders = ""
    @AppStorage("usageRecentDays") private var recentDays = 30
    @AppStorage("usageOccasionalDays") private var occasionalDays = 90
    @AppStorage("usageLongUnusedDays") private var longUnusedDays = 180

    @State private var usageFilter: AppUsage?
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\InstalledApp.totalSize, order: .reverse)]
    @State private var selection = Set<InstalledApp.ID>()
    @State private var detailApp: InstalledApp?
    @State private var showRules = false
    @State private var showLeftovers = false

    var body: some View {
        Group {
            if apps.isEmpty {
                ContentUnavailableView {
                    Label(store.scanning ? "Finding apps…" : "No apps scanned yet", systemImage: "square.grid.2x2")
                } description: {
                    Text("CleanMac lists the apps in your Applications folders with their size, leftover data and when you last used them.")
                } actions: {
                    if store.scanning {
                        ProgressView()
                    } else {
                        Button("Scan Applications") { rescan() }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    summary
                    table
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps")
        .toolbar {
            Picker("Usage", selection: $usageFilter) {
                Text("All Apps").tag(AppUsage?.none)
                ForEach(AppUsage.allCases) { Text($0.rawValue).tag(AppUsage?.some($0)) }
            }
            .pickerStyle(.menu)
            Button("Usage Rules…") { showRules = true }
                .popover(isPresented: $showRules) { rules }
            Button("Leftovers of Removed Apps…") { showLeftovers = true }
            Button("Add Folder…") { addFolder() }
            Button {
                rescan()
            } label: {
                if store.scanning { ProgressView().controlSize(.small) } else { Text("Rescan") }
            }
            .disabled(store.scanning)
        }
        .sheet(item: $detailApp) { app in
            AppDetailView(app: app, appFolders: store.folders(extra: extraFolders))
        }
        .sheet(isPresented: $showLeftovers) {
            LeftoversView()
        }
        .onReceive(NotificationCenter.default.publisher(for: ScreenshotMode.detailNotification)) { _ in
            detailApp = apps.filter { !$0.isProtected }.max { $0.totalSize < $1.totalSize }
        }
    }

    // MARK: Parts

    private var rows: [InstalledApp] {
        apps
            .filter { usageFilter == nil || usage(of: $0) == usageFilter }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    private var summary: some View {
        let unused = apps.filter { [.unused, .longUnused].contains(usage(of: $0)) && !$0.isProtected }
        return HStack {
            Text("\(apps.count) apps")
            Text("·").foregroundStyle(.tertiary)
            Text("\(unused.count) unused for \(occasionalDays)+ days, \(formatBytes(unused.reduce(0) { $0 + $1.totalSize })) including their data")
            Spacer()
            Text("Double-click an app to see where its space goes")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("App", value: \.name) { app in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.installationPath))
                        .resizable()
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                        Text(app.version.isEmpty ? app.bundleIdentifier : "\(app.version) · \(app.bundleIdentifier)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if app.isProtected {
                        SafetyBadge(safety: .protected)
                    }
                }
            }
            TableColumn("Last Opened", value: \.lastOpenedSort) { app in
                Text(app.lastOpenedDate?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown")
                    .foregroundStyle(app.lastOpenedDate == nil ? .secondary : .primary)
            }
            .width(110)
            TableColumn("Usage") { app in
                Text(usage(of: app).rawValue)
                    .foregroundStyle(color(for: usage(of: app)))
            }
            .width(120)
            TableColumn("App Size", value: \.bundleSize) { app in
                Text(formatBytes(app.bundleSize)).monospacedDigit()
            }
            .width(80)
            TableColumn("Data", value: \.associatedDataSize) { app in
                Text(formatBytes(app.associatedDataSize)).monospacedDigit()
            }
            .width(80)
            TableColumn("Total", value: \.totalSize) { app in
                Text(formatBytes(app.totalSize)).monospacedDigit()
            }
            .width(80)
        }
        .contextMenu(forSelectionType: InstalledApp.ID.self) { ids in
            if let app = apps.first(where: { ids.contains($0.id) }) {
                Button("Show Details…") { detailApp = app }
                Button("Reveal in Finder") { revealInFinder([app.url]) }
            }
        } primaryAction: { ids in
            detailApp = apps.first { ids.contains($0.id) }
        }
    }

    private var rules: some View {
        Form {
            Stepper("Recently used: within \(recentDays) days", value: $recentDays, in: 1...365)
            Stepper("Occasionally used: within \(occasionalDays) days", value: $occasionalDays, in: recentDays...730)
            Stepper("Long unused: over \(longUnusedDays) days", value: $longUnusedDays, in: occasionalDays...1095)
            Text("Apps with no last-opened date from macOS are shown as Unknown.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 360)
    }

    // MARK: Helpers

    private func usage(of app: InstalledApp) -> AppUsage {
        AppUsage.classify(
            lastOpened: app.lastOpenedDate,
            recentDays: recentDays,
            occasionalDays: occasionalDays,
            longUnusedDays: longUnusedDays
        )
    }

    private func color(for usage: AppUsage) -> Color {
        switch usage {
        case .recent: .green
        case .occasional: .primary
        case .unused: .orange
        case .longUnused: .red
        case .unknown: .secondary
        }
    }

    private func rescan() {
        store.refresh(context: context, extraFolders: extraFolders)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Folder"
        panel.message = "Choose another folder that contains apps."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folders = Set(extraFolders.split(separator: "\n").map(String.init) + [url.path])
        extraFolders = folders.sorted().joined(separator: "\n")
        rescan()
    }
}
