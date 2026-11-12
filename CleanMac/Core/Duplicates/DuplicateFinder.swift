import CryptoKit
import Foundation

struct DuplicateFile: Identifiable, Hashable {
    let path: String
    let modified: Date?
    let created: Date?

    var id: String { path }
    var url: URL { URL(filePath: path) }
    var name: String { url.lastPathComponent }
}

struct DuplicateGroup: Identifiable {
    /// Content hash.
    let id: String
    let size: Int64
    var files: [DuplicateFile]

    /// Space used by the extra copies.
    var wasted: Int64 { size * Int64(max(0, files.count - 1)) }
}

/// Finds files with identical content: same size, then same first 4 KB, then same full SHA-256.
enum DuplicateFinder {
    static func defaultFolders(home: URL) -> [String] {
        ["Downloads", "Documents", "Desktop", "Movies", "Pictures", "Music"].map { home.path + "/" + $0 }
    }

    static func find(in folders: [URL], minSize: Int64, progress: ScanProgress) -> [DuplicateGroup] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            .creationDateKey, .ubiquitousItemDownloadingStatusKey,
        ]
        var bySize: [Int64: [DuplicateFile]] = [:]
        var seenFiles = Set<String>()

        for folder in folders {
            // Packages (apps, the Photos library) are skipped: their files must not be removed one by one.
            guard let walker = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants, .skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in walker {
                if progress.isCancelled { return [] }
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      // Files stored only in iCloud would be downloaded just to compare them.
                      values.ubiquitousItemDownloadingStatus != .notDownloaded,
                      let size = values.fileSize, Int64(size) >= minSize
                else { continue }
                // Hard links are one file under two names, not duplicates.
                guard let identity = fileIdentity(url.path), seenFiles.insert(identity).inserted else { continue }
                bySize[Int64(size), default: []].append(
                    DuplicateFile(path: url.path, modified: values.contentModificationDate, created: values.creationDate)
                )
                progress.didScan(count: 1, current: url.path)
            }
        }

        var groups: [DuplicateGroup] = []
        for (size, sameSize) in bySize where sameSize.count > 1 {
            for (_, sameStart) in Dictionary(grouping: sameSize, by: { hash($0.url, limit: 4096) ?? UUID().uuidString })
            where sameStart.count > 1 {
                if progress.isCancelled { return [] }
                for (digest, identical) in Dictionary(grouping: sameStart, by: { hash($0.url, limit: nil) ?? UUID().uuidString })
                where identical.count > 1 {
                    groups.append(DuplicateGroup(id: digest, size: size, files: identical.sorted { $0.path < $1.path }))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    /// SHA-256 of the whole file, or of its first `limit` bytes.
    static func hash(_ url: URL, limit: Int?) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            guard let chunk = try? handle.read(upToCount: min(1 << 20, remaining)), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copy to keep by default: one outside Downloads, then the oldest, then the shortest path.
    static func suggestedKeep(_ group: DuplicateGroup, home: URL) -> String? {
        let downloads = home.path + "/Downloads"
        return group.files.min { a, b in
            let aDownloads = pathIsInside(a.path, downloads), bDownloads = pathIsInside(b.path, downloads)
            if aDownloads != bDownloads { return !aDownloads }
            let aDate = a.created ?? a.modified ?? .distantFuture, bDate = b.created ?? b.modified ?? .distantFuture
            if aDate != bDate { return aDate < bDate }
            return a.path.count < b.path.count
        }?.path
    }

    /// Selected files that may be removed. A group where every copy is selected is dropped
    /// entirely, so at least one copy of every file always remains.
    static func removable(_ groups: [DuplicateGroup], selected: Set<String>) -> [DuplicateFile] {
        groups.flatMap { group in
            let chosen = group.files.filter { selected.contains($0.path) }
            return chosen.count < group.files.count ? chosen : []
        }
    }

    private static func fileIdentity(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }
}

/// Runs duplicate searches and keeps the results for this session.
@MainActor
final class DuplicateStore: ObservableObject {
    @Published private(set) var groups: [DuplicateGroup]?
    @Published private(set) var scanning = false
    @Published private(set) var filesChecked = 0
    /// Changes with every new result, so the screen can reset its selection.
    @Published private(set) var resultID = UUID()

    private var progress: ScanProgress?

    func start(folders: [String], minSize: Int64) {
        guard !scanning else { return }
        let progress = ScanProgress()
        self.progress = progress
        scanning = true
        filesChecked = 0
        let urls = folders.map { URL(filePath: $0) }
        Task {
            let poller = Task {
                while !Task.isCancelled {
                    filesChecked = progress.snapshot.items
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            let found = await Task.detached(priority: .userInitiated) {
                DuplicateFinder.find(in: urls, minSize: minSize, progress: progress)
            }.value
            poller.cancel()
            scanning = false
            self.progress = nil
            if !progress.isCancelled {
                groups = found
                resultID = UUID()
            }
        }
    }

    func cancel() {
        progress?.cancel()
    }

    /// Drops files that no longer exist (e.g. after a cleanup) and groups left with one copy.
    func dropMissing() {
        groups = groups?.compactMap { group in
            var group = group
            group.files.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
            return group.files.count > 1 ? group : nil
        }
    }
}
