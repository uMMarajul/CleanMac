import Foundation

/// One file or folder in the scanned tree. Built once by `StorageScanner`; kept in memory only.
final class FileNode: Identifiable, @unchecked Sendable {
    let url: URL
    let isDirectory: Bool
    let isPackage: Bool
    let modified: Date?
    /// Allocated bytes, including everything inside a folder.
    var size: Int64 = 0
    var fileCount = 0
    /// Bytes and file count of contents too small to keep as their own nodes.
    var looseBytes: Int64 = 0
    var looseCount = 0
    var children: [FileNode] = []
    /// Set when this node is where a storage category starts.
    var ruleCategory: StorageCategory?

    var name: String { url.lastPathComponent }
    var path: String { url.path }

    init(url: URL, isDirectory: Bool, isPackage: Bool, modified: Date?) {
        self.url = url
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.modified = modified
    }

    /// Removes descendants at `paths` (after a cleanup) and returns the bytes removed.
    @discardableResult
    func remove(paths: [String]) -> Int64 {
        var removed: Int64 = 0
        children.removeAll { child in
            guard paths.contains(child.path) else { return false }
            removed += child.size
            return true
        }
        for child in children where paths.contains(where: { pathIsInside($0, child.path) }) {
            removed += child.remove(paths: paths)
        }
        size -= removed
        return removed
    }
}

/// Thread-safe progress, cancel flag and inaccessible-folder log shared by scan tasks.
final class ScanProgress: @unchecked Sendable {
    /// Folders not entered at all (protected folders when Full Disk Access is missing).
    let skipped: Set<String>

    private let lock = NSLock()
    private var items = 0
    private var current = ""
    private var cancelled = false
    private var inaccessible: [String] = []
    private var systemOwned: [String] = []

    init(skipped: Set<String> = []) {
        self.skipped = skipped
    }

    func didScan(count: Int, current path: String) {
        lock.withLock {
            items += count
            current = path
        }
    }

    /// `systemOwned`: the folder belongs to another account (root, _postfix, …), so only an
    /// administrator can read it. Otherwise it is blocked by macOS privacy protection.
    func recordInaccessible(_ path: String, systemOwned owned: Bool = false) {
        lock.withLock {
            inaccessible.append(path)
            if owned { systemOwned.append(path) }
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }
    var snapshot: (items: Int, current: String) { lock.withLock { (items, current) } }
    var inaccessiblePaths: [String] { lock.withLock { inaccessible.sorted() } }
    var systemOwnedPaths: [String] { lock.withLock { systemOwned.sorted() } }
}

enum StorageScanner {
    /// Folders and files below this size are folded into their parent's `looseBytes` to bound memory.
    static let keepThreshold: Int64 = 1_000_000

    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        .totalFileAllocatedSizeKey, .contentModificationDateKey,
    ]

    /// Symlink-free path, as the scanner reports children (e.g. /var/... becomes /private/var/...).
    /// Rule and skip paths must use this form to match scanned paths.
    static func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved))
    }

    /// The data volume locations that make up user-visible storage. The sealed system volume is skipped.
    static func defaultRoots(home: URL) -> [URL] {
        [home.path, "/Users/Shared", "/Applications", "/Library", "/private/var", "/private/tmp", "/opt", "/usr/local"]
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(filePath: $0) }
    }

    /// Folders macOS protects with privacy prompts. Skipped when Full Disk Access is missing,
    /// so the scan never triggers a stream of permission dialogs.
    static func protectedWithoutFullDiskAccess(home: URL) -> Set<String> {
        let inHome = [
            "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", ".Trash",
            "Library/Mail", "Library/Messages", "Library/Safari", "Library/Cookies",
            "Library/Calendars", "Library/Reminders", "Library/HomeKit", "Library/Suggestions",
            "Library/Containers", "Library/Group Containers", "Library/Mobile Documents",
            "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
            "Library/Application Support/com.apple.TCC", "Library/Application Support/MobileSync",
        ].map { home.path + "/" + $0 }
        return Set(inHome + ["/Library/Application Support/com.apple.TCC"])
    }

    /// Full Smart Scan: walk, categorize, count snapshots. Returns nil if cancelled.
    static func run(progress: ScanProgress, home: URL) async -> (result: ScanResult, tree: [FileNode])? {
        let started = Date()
        let roots = await scan(roots: defaultRoots(home: home), progress: progress)
        guard !progress.isCancelled else { return nil }
        let analysis = StorageAnalyzer.analyze(roots, home: home)
        let result = ScanResult(
            scannedAt: started,
            duration: Date().timeIntervalSince(started),
            totalBytes: roots.reduce(0) { $0 + $1.size },
            otherBytes: analysis.otherBytes,
            categories: analysis.categories,
            largeFiles: analysis.largeFiles,
            inaccessible: progress.inaccessiblePaths,
            snapshotCount: localSnapshotCount(),
            systemOwned: progress.systemOwnedPaths
        )
        return (result, roots)
    }

    /// Junk Cleaner's Quick Scan: only the known junk locations, in seconds.
    static func quickJunk(progress: ScanProgress, home: URL) async -> [CategoryTotal] {
        let roots = StorageCategory.quickScanRoots(home: home)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let nodes = await scan(roots: roots, progress: progress)
        return StorageAnalyzer.analyze(nodes, home: home).categories
            .filter { StorageCategory.junk.contains($0.category) && $0.bytes > 0 }
    }

    /// Walks each root. The first level below a root is scanned in parallel.
    static func scan(roots: [URL], progress: ScanProgress) async -> [FileNode] {
        var nodes: [FileNode] = []
        for root in roots {
            nodes.append(await scanRoot(root, progress: progress))
        }
        return nodes
    }

    /// Current size and file count of a file or folder, measured from disk.
    static func measure(_ url: URL) -> (bytes: Int64, files: Int) {
        let sizeKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: sizeKeys), values.isRegularFile == true {
            return (Int64(values.totalFileAllocatedSize ?? 0), 1)
        }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(sizeKeys)) else {
            return (0, 0)
        }
        var bytes: Int64 = 0
        var files = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: sizeKeys), values.isRegularFile == true else { continue }
            bytes += Int64(values.totalFileAllocatedSize ?? 0)
            files += 1
        }
        return (bytes, files)
    }

    private static func scanRoot(_ root: URL, progress: ScanProgress) async -> FileNode {
        let values = try? root.resourceValues(forKeys: keys)
        let node = FileNode(url: root, isDirectory: true, isPackage: false, modified: values?.contentModificationDate)
        guard let entries = list(root, progress: progress) else { return node }

        let subfolders = await withTaskGroup(of: FileNode.self) { group in
            for (url, values) in entries where values.isDirectory == true {
                group.addTask { walk(url, values: values, progress: progress) }
            }
            var done: [FileNode] = []
            for await sub in group { done.append(sub) }
            return done
        }

        for (url, values) in entries where values.isDirectory != true {
            addFile(url, values: values, to: node)
        }
        subfolders.forEach { absorb($0, into: node) }
        finish(node)
        return node
    }

    private static func walk(_ url: URL, values: URLResourceValues, progress: ScanProgress) -> FileNode {
        let node = FileNode(
            url: url,
            isDirectory: true,
            isPackage: values.isPackage == true,
            modified: values.contentModificationDate
        )
        guard !progress.isCancelled, let entries = list(url, progress: progress) else { return node }
        for (child, childValues) in entries {
            if childValues.isDirectory == true {
                absorb(walk(child, values: childValues, progress: progress), into: node)
            } else {
                addFile(child, values: childValues, to: node)
            }
        }
        finish(node)
        return node
    }

    /// Directory contents with prefetched metadata, symlinks dropped. nil when unreadable or skipped.
    private static func list(_ url: URL, progress: ScanProgress) -> [(URL, URLResourceValues)]? {
        if progress.skipped.contains(url.path) {
            progress.recordInaccessible(url.path)
            return nil
        }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
        } catch {
            // The folder's owner can still be read even when its contents cannot.
            let owner = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.ownerAccountID] as? NSNumber
            progress.recordInaccessible(url.path, systemOwned: owner.map { $0.uint32Value != getuid() } ?? false)
            return nil
        }
        progress.didScan(count: urls.count, current: url.path)
        return urls.compactMap { child in
            guard let values = try? child.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return nil }
            return (child, values)
        }
    }

    private static func addFile(_ url: URL, values: URLResourceValues, to node: FileNode) {
        let bytes = Int64(values.totalFileAllocatedSize ?? 0)
        node.size += bytes
        node.fileCount += 1
        if bytes >= keepThreshold {
            let file = FileNode(url: url, isDirectory: false, isPackage: false, modified: values.contentModificationDate)
            file.size = bytes
            file.fileCount = 1
            node.children.append(file)
        } else {
            node.looseBytes += bytes
            node.looseCount += 1
        }
    }

    private static func absorb(_ child: FileNode, into node: FileNode) {
        node.size += child.size
        node.fileCount += child.fileCount
        if child.size >= keepThreshold {
            node.children.append(child)
        } else {
            node.looseBytes += child.size
            node.looseCount += child.fileCount
        }
    }

    /// Packages (apps, libraries) are one item: their contents are not browsable.
    private static func finish(_ node: FileNode) {
        if node.isPackage {
            node.children = []
            node.looseBytes = node.size
            node.looseCount = node.fileCount
        } else {
            node.children.sort { $0.size > $1.size }
        }
    }

    /// Number of local Time Machine snapshots. Their size is not measurable from user space.
    static func localSnapshotCount() -> Int? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", "/"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { $0.contains("com.apple.TimeMachine") }
            .count
    }
}
