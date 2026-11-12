import Foundation

/// True when `path` is `root` or anywhere inside it.
func pathIsInside(_ path: String, _ root: String) -> Bool {
    path == root || path.hasPrefix(root + "/")
}

/// A file or folder shown to the user. Small and Codable so the last scan can be saved.
struct ScanItem: Codable, Identifiable, Hashable {
    var path: String
    var size: Int64
    var fileCount: Int
    var modified: Date?
    var isFolder: Bool
    var category: StorageCategory?

    var id: String { path }
    var url: URL { URL(filePath: path) }
    var name: String { url.lastPathComponent }
    var location: String { url.deletingLastPathComponent().path }
    var kind: FileKind { FileKind(url: url) }
    var kindTitle: String { kind.rawValue }
    var modifiedSort: Date { modified ?? .distantPast }
}

extension ScanItem {
    init(node: FileNode, category: StorageCategory?) {
        self.init(
            path: node.path,
            size: node.size,
            fileCount: node.fileCount,
            modified: node.modified,
            isFolder: node.isDirectory,
            category: category
        )
    }
}

/// An item the cleanup engine moved to the Trash.
struct CleanedItem {
    let item: ScanItem
    /// Size measured right before cleaning.
    let size: Int64
    /// Where the item now lives in the Trash, needed for Put Back.
    let trashPath: String?
}

struct CategoryTotal: Codable, Identifiable {
    let category: StorageCategory
    var bytes: Int64 = 0
    var files = 0
    /// Largest items in this category, biggest first.
    var items: [ScanItem] = []

    var id: StorageCategory { category }

    mutating func remove(_ cleaned: [CleanedItem]) {
        for entry in cleaned where entry.item.category == category {
            bytes = max(0, bytes - entry.size)
            files = max(0, files - entry.item.fileCount)
        }
        let gone = cleaned.map(\.item.path)
        items.removeAll { item in gone.contains { pathIsInside(item.path, $0) } }
    }
}

/// What CleanMac shows from the last Smart Scan. Saved to disk; the folder tree is not.
struct ScanResult: Codable, Identifiable {
    var id = UUID()
    var scannedAt: Date
    var duration: TimeInterval
    var totalBytes: Int64
    var otherBytes: Int64
    var categories: [CategoryTotal]
    var largeFiles: [ScanItem]
    var inaccessible: [String]
    /// nil when `tmutil` could not be asked.
    var snapshotCount: Int?
    /// Inaccessible folders owned by macOS system accounts; only an administrator can read them.
    var systemOwned: [String]?
    /// Sizes of `systemOwned` folders, once measured with the administrator password.
    var systemFolderSizes: [String: Int64]?

    /// Inaccessible because of macOS privacy protection (fixed by Full Disk Access).
    var privacyBlocked: [String] {
        let owned = Set(systemOwned ?? [])
        return inaccessible.filter { !owned.contains($0) }
    }

    var systemFolderBytes: Int64 { systemFolderSizes?.values.reduce(0, +) ?? 0 }

    var safeBytes: Int64 { bytes(where: .safe) }
    var reviewBytes: Int64 { bytes(where: .reviewRequired) }

    /// Review items people commonly clean (simulators, archives, old installers).
    var recoverableReviewBytes: Int64 {
        categories.filter { StorageCategory.commonlyCleaned.contains($0.category) }.reduce(0) { $0 + $1.bytes }
    }

    /// Realistic estimate: Safe junk plus commonly cleaned Review items.
    var recoverableBytes: Int64 { safeBytes + recoverableReviewBytes }

    /// Bytes in CleanMac's System Data categories. An estimate; never Apple's exact figure.
    var systemDataEstimate: Int64 {
        categories.filter { $0.category != .otherLargeFiles }.reduce(0) { $0 + $1.bytes }
    }

    private func bytes(where safety: SafetyClassification) -> Int64 {
        categories.filter { $0.category.safety == safety }.reduce(0) { $0 + $1.bytes }
    }

    /// Takes cleaned items (and anything inside them) out of every list and total.
    mutating func remove(_ cleaned: [CleanedItem]) {
        for entry in cleaned {
            totalBytes = max(0, totalBytes - entry.size)
            if entry.item.category == nil {
                otherBytes = max(0, otherBytes - entry.size)
            }
        }
        for index in categories.indices { categories[index].remove(cleaned) }
        let gone = cleaned.map(\.item.path)
        largeFiles.removeAll { file in gone.contains { pathIsInside(file.path, $0) } }
        categories.sort { $0.bytes > $1.bytes }
    }

    /// Adds back an item restored from the Trash.
    mutating func restore(_ item: ScanItem) {
        totalBytes += item.size
        if let category = item.category, let index = categories.firstIndex(where: { $0.category == category }) {
            categories[index].bytes += item.size
            categories[index].files += item.fileCount
            categories[index].items.append(item)
            categories[index].items.sort { $0.size > $1.size }
        } else {
            otherBytes += item.size
        }
        if !item.isFolder, item.size >= StorageAnalyzer.largeFileFloor {
            largeFiles.append(item)
        }
        categories.sort { $0.bytes > $1.bytes }
    }
}
