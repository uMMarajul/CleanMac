import SwiftData
import SwiftUI

struct DeveloperCleanerView: View {
    @EnvironmentObject private var store: DeveloperStore
    @EnvironmentObject private var scan: ScanStore
    @Environment(\.modelContext) private var context

    @State private var pendingTrash: [ScanItem]?
    @State private var pendingCommand: DevItem?

    var body: some View {
        Group {
            if let items = store.items {
                list(items)
            } else {
                ProgressView("Measuring developer tools…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            Button {
                store.refresh(home: scan.home)
            } label: {
                if store.scanning { ProgressView().controlSize(.small) } else { Text("Rescan") }
            }
            .disabled(store.scanning)
        }
        .task { if store.items == nil { store.refresh(home: scan.home) } }
        .onChange(of: scan.cleanupVersion) { store.refresh(home: scan.home) }
        .cleanupFlow(pending: $pendingTrash)
        .confirmationDialog(
            pendingCommand.map { "Delete \($0.title) (\(formatBytes($0.size)))?" } ?? "",
            isPresented: Binding(get: { pendingCommand != nil }, set: { if !$0 { pendingCommand = nil } }),
            titleVisibility: .visible
        ) {
            if let item = pendingCommand {
                Button("Delete Permanently", role: .destructive) { runCommand(item) }
            }
        } message: {
            Text("This uses the tool's own clean command and cannot be undone. It does not go to the Trash.")
        }
    }

    private func list(_ items: [DevItem]) -> some View {
        let cleanable = items.filter { $0.action != .none }
        return List {
            Section {
                HStack {
                    Text("\(formatBytes(cleanable.reduce(0) { $0 + $1.size })) of developer data can be cleaned")
                    Text("· \(formatBytes(cleanable.filter { $0.safety == .safe }.reduce(0) { $0 + $1.size })) is Safe")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if let error = store.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Source code, git repositories, project dependencies and Docker volumes are never touched.")
            }

            ForEach(DeveloperTools.groups, id: \.self) { group in
                let rows = items.filter { $0.group == group }.sorted { $0.size > $1.size }
                Section(group) {
                    if rows.isEmpty {
                        Text("Nothing found.").foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row($0) }
                }
            }
        }
    }

    private func row(_ item: DevItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .trash(let path) = item.action {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer()
            if item.size > 0 {
                SafetyBadge(safety: item.safety)
                Text(formatBytes(item.size))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }
            actionButton(item)
                .frame(width: 130, alignment: .trailing)
        }
        .contextMenu {
            if case .trash(let path) = item.action {
                Button("Reveal in Finder") { revealInFinder([URL(filePath: path)]) }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ item: DevItem) -> some View {
        switch item.action {
        case .trash(let path):
            Button("Move to Trash…") {
                pendingTrash = [ScanItem(
                    path: path, size: item.size, fileCount: 0, modified: nil, isFolder: true,
                    category: StorageCategory.category(forPath: path, home: scan.home)
                )]
            }
        case .command:
            if store.runningID == item.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Delete…") { pendingCommand = item }
                    .disabled(store.runningID != nil)
            }
        case .none:
            EmptyView()
        }
    }

    private func runCommand(_ item: DevItem) {
        store.perform(item, home: scan.home) { done in
            context.insert(CleanupRecord(
                filePath: "",
                originalLocation: done.title,
                deletedSize: done.size,
                operationType: "Developer Cleaner: \(done.group)",
                recoveryStatus: "permanent"
            ))
            try? context.save()
        }
    }
}
