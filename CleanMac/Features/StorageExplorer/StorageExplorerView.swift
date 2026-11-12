import SwiftUI

struct StorageExplorerView: View {
    @EnvironmentObject private var scan: ScanStore
    @EnvironmentObject private var permissions: PermissionManager
    let navigate: (SidebarSection) -> Void

    @State private var path: [FileNode] = []
    @State private var sort: SortKey = .size
    @State private var search = ""

    enum SortKey: String, CaseIterable, Identifiable {
        case size = "Size", name = "Name", date = "Date Modified"
        var id: String { rawValue }
    }

    var body: some View {
        if let tree = scan.tree, let result = scan.result {
            explorer(tree)
                .onChange(of: result.id) { path = [] }
        } else if scan.result != nil {
            // The folder tree is kept in memory only, so it is gone after a relaunch.
            ContentUnavailableView {
                Label("Folder browsing needs a fresh scan", systemImage: "folder.badge.questionmark")
            } description: {
                Text("CleanMac saves your scan results, but not the full folder tree. Scan again to browse folders.")
            } actions: {
                Button("Scan Again") {
                    scan.start(fullDiskAccess: permissions.hasFullDiskAccess)
                    navigate(.smartScan)
                }
                .disabled(scan.phase == .scanning)
            }
        } else {
            NeedsScanView(navigate: navigate)
        }
    }

    private func explorer(_ tree: [FileNode]) -> some View {
        let current = path.last
        let entries = sorted((current?.children ?? tree).filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
        })
        let largest = max(entries.map(\.size).max() ?? 1, 1)

        return VStack(alignment: .leading, spacing: 0) {
            breadcrumb
            Divider()
            List {
                ForEach(entries) { node in
                    row(node, largest: largest, atTop: current == nil)
                }
                if let current, current.looseBytes > 0, search.isEmpty {
                    HStack {
                        Image(systemName: "square.stack.3d.down.right")
                            .frame(width: 20)
                        Text("\(current.looseCount.formatted()) smaller items (under 1 MB each)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formatBytes(current.looseBytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search this folder")
        .toolbar {
            Picker("Sort by", selection: $sort) {
                ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("All Locations") { open(at: 0) }
                ForEach(Array(path.enumerated()), id: \.offset) { index, node in
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button(index == 0 ? node.path : node.name) { open(at: index + 1) }
                }
            }
            .buttonStyle(.link)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func row(_ node: FileNode, largest: Int64, atTop: Bool) -> some View {
        let canOpen = node.isDirectory && !node.children.isEmpty
        return HStack(spacing: 10) {
            Image(systemName: node.isPackage ? "shippingbox" : node.isDirectory ? "folder" : "doc")
                .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(atTop ? node.path : node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(node.modified?.formatted(date: .abbreviated, time: .omitted) ?? "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            ProgressView(value: Double(node.size), total: Double(largest))
                .frame(width: 140)
            Text(formatBytes(node.size))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .opacity(canOpen ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard canOpen else { return }
            path.append(node)
            search = ""
        }
        .contextMenu {
            Button("Reveal in Finder") { revealInFinder([node.url]) }
        }
    }

    private func open(at depth: Int) {
        path = Array(path.prefix(depth))
        search = ""
    }

    private func sorted(_ nodes: [FileNode]) -> [FileNode] {
        switch sort {
        case .size: nodes.sorted { $0.size > $1.size }
        case .name: nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date: nodes.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
    }
}
