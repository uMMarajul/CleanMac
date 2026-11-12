import Charts
import SwiftUI

struct SystemDataView: View {
    @EnvironmentObject private var scan: ScanStore
    @EnvironmentObject private var permissions: PermissionManager
    let navigate: (SidebarSection) -> Void

    var body: some View {
        if let result = scan.result {
            NavigationStack {
                content(result)
                    .navigationTitle("System Data")
                    .navigationDestination(for: StorageCategory.self) { category in
                        if let total = scan.result?.categories.first(where: { $0.category == category }) {
                            CategoryDetailView(total: total)
                        }
                    }
                    .toolbar {
                        Button("Scan Again") {
                            scan.start(fullDiskAccess: permissions.hasFullDiskAccess)
                            navigate(.smartScan)
                        }
                        .disabled(scan.phase == .scanning)
                    }
            }
        } else {
            NeedsScanView(navigate: navigate)
        }
    }

    private func content(_ result: ScanResult) -> some View {
        let disk = DiskInfo.current()
        let macOSVolumes = DiskInfo.macOSVolumesUsed()
        let visible = result.categories.filter { $0.bytes > 0 }
        return List {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .topLeading)], alignment: .leading, spacing: 12) {
                    figure("Measured", result.totalBytes, "Everything CleanMac could read")
                    figure("In categories", result.systemDataEstimate, "CleanMac's System Data estimate")
                    figure("Uncategorized", result.otherBytes, "Apps, documents and other files")
                    figure("macOS volumes", macOSVolumes, "Sealed system, Preboot, VM swap, updates")
                    figure(
                        "Unaccounted",
                        max(0, disk.used - result.totalBytes - result.systemFolderBytes - macOSVolumes),
                        "Snapshots, hidden and protected files"
                    )
                }
                .padding(.vertical, 6)
                chart(result, visible: visible)
            } header: {
                Text("Results from \(result.scannedAt.formatted(date: .abbreviated, time: .shortened))")
            }

            Section("Categories") {
                ForEach(visible) { total in
                    NavigationLink(value: total.category) {
                        CategoryRow(total: total)
                    }
                }
                snapshotRow(result.snapshotCount)
            }

            if let owned = result.systemOwned, !owned.isEmpty {
                Section {
                    DisclosureGroup("Owned by macOS (\(owned.count))") {
                        ForEach(owned.prefix(300), id: \.self) { path in
                            HStack {
                                Text(path)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Spacer()
                                if let size = result.systemFolderSizes?[path] {
                                    Text(formatBytes(size)).font(.caption).monospacedDigit()
                                }
                            }
                        }
                    }
                    HStack {
                        if scan.measuringSystemFolders {
                            ProgressView().controlSize(.small)
                            Text("Measuring…").foregroundStyle(.secondary)
                        } else if result.systemFolderSizes != nil {
                            Text("Measured with administrator rights: \(formatBytes(result.systemFolderBytes))")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Measure with Administrator Password…") { scan.measureSystemFolders() }
                        }
                        if let error = scan.administratorError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                } footer: {
                    Text("These belong to macOS system accounts, so only an administrator can read them. Full Disk Access does not change this. CleanMac never cleans them; measuring only reads their sizes.")
                }
            }

            if !result.privacyBlocked.isEmpty {
                Section {
                    DisclosureGroup("Needs Full Disk Access (\(result.privacyBlocked.count))") {
                        ForEach(result.privacyBlocked.prefix(300), id: \.self) { path in
                            Text(path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    if !permissions.hasFullDiskAccess {
                        Button("Open Full Disk Access Settings") { permissions.openFullDiskAccessSettings() }
                    }
                } footer: {
                    Text("macOS privacy protection blocks these folders until CleanMac has Full Disk Access. If you just granted it, scan again.")
                }
            }

            Section {
                Text("These are CleanMac's own analytical categories. macOS calculates System Data differently (it includes purgeable space, snapshots and protected files), so the numbers will not match Storage Settings exactly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func figure(_ title: String, _ bytes: Int64, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(formatBytes(bytes)).font(.title3.weight(.semibold)).monospacedDigit()
            Text(note).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private struct Slice: Identifiable {
        let name: String
        let bytes: Int64
        var id: String { name }
    }

    private func chart(_ result: ScanResult, visible: [CategoryTotal]) -> some View {
        var slices = visible.prefix(7).map { Slice(name: $0.category.title, bytes: $0.bytes) }
        let rest = visible.dropFirst(7).reduce(Int64(0)) { $0 + $1.bytes }
        if rest > 0 { slices.append(Slice(name: "Smaller categories", bytes: rest)) }
        if result.otherBytes > 0 { slices.append(Slice(name: "Uncategorized", bytes: result.otherBytes)) }

        return Chart(slices) { slice in
            BarMark(x: .value("Size", Double(slice.bytes)), y: .value("Storage", "Measured"))
                .foregroundStyle(by: .value("Category", slice.name))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 110)
        .padding(.vertical, 6)
    }

    private func snapshotRow(_ count: Int?) -> some View {
        HStack {
            Image(systemName: StorageCategory.localSnapshots.icon)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(StorageCategory.localSnapshots.title)
                Text(StorageCategory.localSnapshots.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SafetyBadge(safety: .protected)
            Text(count.map { "\($0) snapshot\($0 == 1 ? "" : "s") · size not measurable" } ?? "Could not check")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CategoryRow: View {
    let total: CategoryTotal

    var body: some View {
        HStack {
            Image(systemName: total.category.icon)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(total.category.title)
                Text(total.category.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SafetyBadge(safety: total.category.safety)
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatBytes(total.bytes))
                    .monospacedDigit()
                Text("\(total.files.formatted()) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 100, alignment: .trailing)
        }
    }
}

/// Largest items inside one category, with Move to Trash.
struct CategoryDetailView: View {
    let total: CategoryTotal
    @State private var selection = Set<ScanItem.ID>()
    @State private var pending: [ScanItem]?

    private var canClean: Bool { total.category.safety != .protected }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SafetyBadge(safety: total.category.safety)
                Text("\(formatBytes(total.bytes)) · \(total.category.summary)")
                    .foregroundStyle(.secondary)
            }
            .padding()

            Table(total.items, selection: $selection) {
                TableColumn("Name") { item in
                    Label(item.name, systemImage: item.isFolder ? "folder" : "doc")
                }
                TableColumn("Size") { item in
                    Text(formatBytes(item.size)).monospacedDigit()
                }
                .width(90)
                TableColumn("Modified") { item in
                    Text(item.modified?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                }
                .width(110)
                TableColumn("Path") { item in
                    Text(item.path)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                }
            }
            .contextMenu(forSelectionType: ScanItem.ID.self) { ids in
                Button("Reveal in Finder") { revealInFinder(items(ids).map(\.url)) }
                if canClean {
                    Button("Move to Trash…") { pending = items(ids) }
                }
            } primaryAction: { ids in
                revealInFinder(items(ids).map(\.url))
            }
        }
        .navigationTitle(total.category.title)
        .toolbar {
            if canClean {
                Button("Move to Trash…") { pending = items(selection) }
                    .disabled(selection.isEmpty)
            }
        }
        .cleanupFlow(pending: $pending)
    }

    private func items(_ ids: Set<ScanItem.ID>) -> [ScanItem] {
        total.items.filter { ids.contains($0.id) }
    }
}
