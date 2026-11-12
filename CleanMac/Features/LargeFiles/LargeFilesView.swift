import SwiftUI

struct LargeFilesView: View {
    @EnvironmentObject private var scan: ScanStore
    let navigate: (SidebarSection) -> Void

    @AppStorage("largeFileThreshold") private var threshold = 100_000_000
    @State private var kind: FileKind = .all
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\ScanItem.size, order: .reverse)]
    @State private var selection = Set<ScanItem.ID>()
    @State private var pending: [ScanItem]?

    private static let thresholds: [(String, Int)] = [
        ("50 MB", 50_000_000), ("100 MB", 100_000_000), ("500 MB", 500_000_000), ("1 GB", 1_000_000_000),
    ]

    var body: some View {
        if let result = scan.result {
            table(result)
        } else {
            NeedsScanView(navigate: navigate)
        }
    }

    private func table(_ result: ScanResult) -> some View {
        let rows = result.largeFiles
            .filter {
                $0.size >= Int64(threshold)
                    && (kind == .all || $0.kind == kind)
                    && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
            }
            .sorted(using: sortOrder)

        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name)
            TableColumn("Size", value: \.size) { file in
                Text(formatBytes(file.size)).monospacedDigit()
            }
            .width(90)
            TableColumn("Kind", value: \.kindTitle)
                .width(90)
            TableColumn("Modified", value: \.modifiedSort) { file in
                Text(file.modified?.formatted(date: .abbreviated, time: .omitted) ?? "—")
            }
            .width(110)
            TableColumn("Location", value: \.location) { file in
                Text(file.location)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: ScanItem.ID.self) { ids in
            Button("Reveal in Finder") { revealInFinder(pick(ids, from: rows).map(\.url)) }
            Button("Move to Trash…") { pending = pick(ids, from: rows) }
        } primaryAction: { ids in
            revealInFinder(pick(ids, from: rows).map(\.url))
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search file names")
        .toolbar {
            Picker("Minimum size", selection: $threshold) {
                ForEach(Self.thresholds, id: \.1) { label, bytes in
                    Text(label).tag(bytes)
                }
            }
            .pickerStyle(.menu)
            Picker("Type", selection: $kind) {
                ForEach(FileKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            Button("Move to Trash…") { pending = pick(selection, from: rows) }
                .disabled(selection.isEmpty)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(rows.count.formatted()) files · \(formatBytes(rows.reduce(0) { $0 + $1.size }))")
                Spacer()
                Text("Double-click to reveal in Finder")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .cleanupFlow(pending: $pending)
    }

    private func pick(_ ids: Set<ScanItem.ID>, from rows: [ScanItem]) -> [ScanItem] {
        rows.filter { ids.contains($0.id) }
    }
}
