import SwiftData
import SwiftUI

struct CleanupHistoryView: View {
    @Query(sort: \CleanupRecord.cleanupDate, order: .reverse) private var records: [CleanupRecord]
    @EnvironmentObject private var scan: ScanStore
    @Environment(\.modelContext) private var context
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    "No cleanups yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Items you clean appear here. Anything still in the Trash can be put back.")
                )
            } else {
                Table(records) {
                    TableColumn("Item") { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.operationType == "Emptied Trash"
                                 ? "Emptied Trash"
                                 : URL(filePath: record.originalLocation).lastPathComponent)
                            Text(record.originalLocation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    TableColumn("Size") { record in
                        Text(formatBytes(record.deletedSize)).monospacedDigit()
                    }
                    .width(90)
                    TableColumn("Date") { record in
                        Text(record.cleanupDate.formatted(date: .abbreviated, time: .shortened))
                    }
                    .width(150)
                    TableColumn("Status") { record in
                        let state = status(of: record)
                        HStack {
                            Text(state.label)
                                .foregroundStyle(state.canPutBack ? Color.primary : Color.secondary)
                            Spacer()
                            if state.canPutBack {
                                Button("Put Back") { putBack(record) }
                            }
                        }
                    }
                    .width(210)
                }
            }
        }
        .alert(
            "Couldn't put it back",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Whether an item is still in the Trash is checked live, since the user can empty it anytime.
    private func status(of record: CleanupRecord) -> (label: String, canPutBack: Bool) {
        switch record.recoveryStatus {
        case "restored": ("Put back", false)
        case "permanent": ("Deleted permanently", false)
        default:
            FileManager.default.fileExists(atPath: record.filePath)
                ? ("In Trash", true)
                : ("No longer in Trash", false)
        }
    }

    private func putBack(_ record: CleanupRecord) {
        do {
            try CleanupEngine.putBack(trashPath: record.filePath, originalPath: record.originalLocation)
            record.recoveryStatus = "restored"
            try? context.save()

            let url = URL(filePath: record.originalLocation)
            let measured = StorageScanner.measure(url)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            scan.applyRestore(ScanItem(
                path: record.originalLocation,
                size: measured.bytes,
                fileCount: measured.files,
                modified: values?.contentModificationDate,
                isFolder: values?.isDirectory == true,
                category: record.category.flatMap(StorageCategory.init(rawValue:))
            ))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
