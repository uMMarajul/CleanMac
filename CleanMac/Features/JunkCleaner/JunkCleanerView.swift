import QuickLook
import SwiftData
import SwiftUI

struct JunkCleanerView: View {
    @EnvironmentObject private var scan: ScanStore
    @EnvironmentObject private var permissions: PermissionManager
    @Environment(\.modelContext) private var context
    let navigate: (SidebarSection) -> Void

    @State private var selected = Set<String>()
    @State private var pending: [ScanItem]?
    @State private var preview: URL?
    @State private var trashSize: Int64?
    @State private var askEmptyTrash = false
    @State private var confirmEmptyTrash = false
    @State private var trashMessage: String?

    /// Quick Scan results when available, otherwise junk from the last Smart Scan.
    private var source: [CategoryTotal] {
        if let quick = scan.quickJunk { return quick }
        return scan.result?.categories.filter { StorageCategory.junk.contains($0.category) && $0.bytes > 0 } ?? []
    }

    private var allItems: [ScanItem] { source.flatMap(\.items) }
    private var selectedItems: [ScanItem] { allItems.filter { selected.contains($0.path) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                trashSection
                if source.isEmpty {
                    Text(scan.quickScanning ? "Looking for junk…" : "No junk found yet. Run Quick Scan to check caches, logs and developer files in seconds.")
                        .foregroundStyle(.secondary)
                }
                ForEach(source) { total in
                    Section {
                        DisclosureGroup {
                            ForEach(total.items) { itemRow($0) }
                        } label: {
                            categoryLabel(total)
                        }
                    }
                }
            }
            bottomBar
        }
        .cleanupFlow(pending: $pending)
        .quickLookPreview($preview)
        .task(id: scan.cleanupVersion) { await refreshTrashSize() }
        .onChange(of: allItems.map(\.path)) { _, paths in selected.formIntersection(paths) }
        .confirmationDialog("Empty the Trash?", isPresented: $askEmptyTrash, titleVisibility: .visible) {
            Button("Continue…", role: .destructive) {
                DispatchQueue.main.async { confirmEmptyTrash = true }
            }
        } message: {
            Text("Everything in the Trash will be deleted permanently.")
        }
        .alert("Permanently delete \(formatBytes(trashSize ?? 0))?", isPresented: $confirmEmptyTrash) {
            Button("Delete Permanently", role: .destructive) { emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Items in the Trash can no longer be put back.")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text(sourceLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if scan.quickScanning { ProgressView().controlSize(.small) }
            Button("Quick Scan") { scan.startQuickScan(fullDiskAccess: permissions.hasFullDiskAccess) }
                .disabled(scan.quickScanning || scan.phase == .scanning)
            Button("Deep Scan") {
                scan.start(fullDiskAccess: permissions.hasFullDiskAccess)
                navigate(.smartScan)
            }
            .disabled(scan.phase == .scanning)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var sourceLabel: String {
        if scan.quickJunk != nil { return "Quick Scan results" }
        if let result = scan.result {
            return "From Smart Scan, \(result.scannedAt.formatted(.relative(presentation: .named)))"
        }
        return "Quick Scan checks known junk locations. Deep Scan measures the whole disk."
    }

    private var trashSection: some View {
        Section {
            HStack {
                Image(systemName: "trash")
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trash")
                    Text(trashMessage ?? (permissions.hasFullDiskAccess
                        ? "Items moved here still use disk space until the Trash is emptied."
                        : "Grant Full Disk Access to measure the Trash."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(trashSize.map(formatBytes) ?? "—")
                    .monospacedDigit()
                Button("Empty Trash…") { askEmptyTrash = true }
                    .disabled((trashSize ?? 0) == 0)
            }
        }
    }

    private func categoryLabel(_ total: CategoryTotal) -> some View {
        let selectable = total.items.filter(isSelectable)
        let isSafe = total.category.safety == .safe
        return HStack {
            if isSafe {
                Toggle("", isOn: Binding(
                    get: { !selectable.isEmpty && selectable.allSatisfy { selected.contains($0.path) } },
                    set: { on in
                        let paths = selectable.map(\.path)
                        if on { selected.formUnion(paths) } else { selected.subtract(paths) }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(selectable.isEmpty)
            }
            Image(systemName: total.category.icon)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(total.category.title)
                Text(isSafe ? total.category.summary : "Review each item before selecting it.")
                    .font(.caption)
                    .foregroundStyle(isSafe ? Color.secondary : Color.orange)
            }
            Spacer()
            SafetyBadge(safety: total.category.safety)
            Text(formatBytes(total.bytes))
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)
        }
    }

    private func itemRow(_ item: ScanItem) -> some View {
        let refusal = CleanupEngine.locationRefusal(for: item, home: scan.home)
        return HStack {
            Toggle("", isOn: Binding(
                get: { selected.contains(item.path) },
                set: { on in
                    if on { selected.insert(item.path) } else { selected.remove(item.path) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(refusal != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                Text(refusal ?? item.path)
                    .font(.caption)
                    .foregroundStyle(refusal == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Button {
                preview = item.url
            } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .help("Quick Look")
            Text(formatBytes(item.size))
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)
        }
        .contextMenu {
            Button("Reveal in Finder") { revealInFinder([item.url]) }
        }
    }

    private var bottomBar: some View {
        let items = selectedItems
        return HStack {
            Text(items.isEmpty
                 ? "Select items to clean"
                 : "\(items.count) selected · \(formatBytes(items.reduce(0) { $0 + $1.size }))")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clean Up") { pending = items }
                .buttonStyle(.borderedProminent)
                .disabled(items.isEmpty)
        }
        .padding()
        .background(.bar)
    }

    // MARK: Helpers

    private func isSelectable(_ item: ScanItem) -> Bool {
        CleanupEngine.locationRefusal(for: item, home: scan.home) == nil
    }

    private func refreshTrashSize() async {
        let trash = CleanupEngine.trashFolder(home: scan.home)
        trashSize = await Task.detached { StorageScanner.measure(trash).bytes }.value
    }

    private func emptyTrash() {
        let home = scan.home
        Task {
            let outcome = await Task.detached { CleanupEngine.emptyTrash(home: home) }.value
            context.insert(CleanupRecord(
                filePath: CleanupEngine.trashFolder(home: home).path,
                originalLocation: "Trash",
                deletedSize: outcome.freed,
                operationType: "Emptied Trash",
                recoveryStatus: "permanent"
            ))
            try? context.save()
            trashMessage = outcome.failed == 0
                ? "Emptied. \(formatBytes(outcome.freed)) freed."
                : "Freed \(formatBytes(outcome.freed)); \(outcome.failed) items could not be deleted."
            await refreshTrashSize()
        }
    }
}
