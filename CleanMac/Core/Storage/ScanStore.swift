import Foundation

/// Owns scan state: progress while running, the saved last result, and session-only data.
@MainActor
final class ScanStore: ObservableObject {
    enum Phase: Equatable {
        case idle, scanning
    }

    @Published private(set) var phase: Phase = .idle
    /// Last Smart Scan. Saved to disk and restored on launch.
    @Published private(set) var result: ScanResult?
    /// Folder tree for Storage Explorer. Memory only: gone after relaunch.
    @Published private(set) var tree: [FileNode]?
    /// Junk Cleaner Quick Scan results. Memory only.
    @Published private(set) var quickJunk: [CategoryTotal]?
    @Published private(set) var quickScanning = false
    /// Bumped after every cleanup or restore, so screens can refresh.
    @Published private(set) var cleanupVersion = 0
    @Published private(set) var itemsScanned = 0
    @Published private(set) var currentPath = ""
    /// Asks the user before scanning without Full Disk Access.
    @Published var askFullDiskAccess = false
    /// Asks to measure system-owned folders with the administrator password after a scan.
    @Published var askAdministrator = false
    @Published private(set) var measuringSystemFolders = false
    @Published private(set) var administratorError: String?

    let home = StorageScanner.realPath(FileManager.default.homeDirectoryForCurrentUser)
    private var progress: ScanProgress?
    private var scanWithoutFullDiskAccessConfirmed = false

    init() {
        result = Self.loadSaved()
    }

    /// User chose to scan anyway; protected folders are skipped and listed as inaccessible.
    func startWithoutFullDiskAccess() {
        scanWithoutFullDiskAccessConfirmed = true
        start(fullDiskAccess: false)
    }

    /// Reads sizes of system-owned folders as administrator. macOS shows its own password prompt.
    func measureSystemFolders() {
        guard let paths = result?.systemOwned, !paths.isEmpty, !measuringSystemFolders else { return }
        measuringSystemFolders = true
        administratorError = nil
        Task {
            let outcome = await Task.detached { () -> Result<[String: Int64]?, Error> in
                Result { try AdminHelper.measure(paths) }
            }.value
            measuringSystemFolders = false
            switch outcome {
            case .success(let sizes?):
                result?.systemFolderSizes = sizes
                save()
            case .success(nil):
                break // cancelled at the password prompt
            case .failure(let error):
                administratorError = error.localizedDescription
            }
        }
    }

    func start(fullDiskAccess: Bool) {
        guard phase == .idle else { return }
        if !fullDiskAccess && !scanWithoutFullDiskAccessConfirmed {
            askFullDiskAccess = true
            return
        }
        let progress = ScanProgress(skipped: skippedFolders(fullDiskAccess))
        self.progress = progress
        phase = .scanning
        itemsScanned = 0
        currentPath = ""
        let home = home

        Task {
            let poller = Task {
                while !Task.isCancelled {
                    let snapshot = progress.snapshot
                    itemsScanned = snapshot.items
                    currentPath = snapshot.current
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            let outcome = await Task.detached(priority: .userInitiated) {
                await StorageScanner.run(progress: progress, home: home)
            }.value
            poller.cancel()
            self.progress = nil
            phase = .idle

            // Cancelled: keep the previous result untouched.
            guard let outcome else { return }
            result = outcome.result
            tree = outcome.tree
            quickJunk = nil
            save()
            askAdministrator = !(outcome.result.systemOwned ?? []).isEmpty
        }
    }

    func cancel() {
        progress?.cancel()
    }

    /// For automation: runs without prompts and waits. Returns the junk categories found,
    /// or nil when another scan is already running.
    func runScheduled(_ kind: ScheduledScanKind, fullDiskAccess: Bool) async -> [CategoryTotal]? {
        guard phase == .idle, !quickScanning else { return nil }
        let progress = ScanProgress(skipped: skippedFolders(fullDiskAccess))
        let home = home
        switch kind {
        case .quick:
            quickScanning = true
            let junk = await Task.detached(priority: .utility) {
                await StorageScanner.quickJunk(progress: progress, home: home)
            }.value
            quickJunk = junk
            quickScanning = false
            return junk
        case .smart:
            phase = .scanning
            self.progress = progress
            let outcome = await Task.detached(priority: .utility) {
                await StorageScanner.run(progress: progress, home: home)
            }.value
            phase = .idle
            self.progress = nil
            guard let outcome else { return nil }
            result = outcome.result
            tree = outcome.tree
            quickJunk = nil
            save()
            return outcome.result.categories.filter { StorageCategory.junk.contains($0.category) }
        }
    }

    /// Forgets the saved scan (Settings → Data).
    func clearSaved() {
        result = nil
        tree = nil
        quickJunk = nil
        try? FileManager.default.removeItem(at: Self.saveURL)
    }

    func startQuickScan(fullDiskAccess: Bool) {
        guard !quickScanning, phase == .idle else { return }
        quickScanning = true
        let progress = ScanProgress(skipped: skippedFolders(fullDiskAccess))
        let home = home
        Task {
            quickJunk = await Task.detached(priority: .userInitiated) {
                await StorageScanner.quickJunk(progress: progress, home: home)
            }.value
            quickScanning = false
        }
    }

    /// Removes cleaned items from every list, the folder tree, and the saved scan.
    func applyCleanup(_ cleaned: [CleanedItem]) {
        guard !cleaned.isEmpty else { return }
        result?.remove(cleaned)
        if quickJunk != nil {
            for index in quickJunk!.indices { quickJunk![index].remove(cleaned) }
        }
        let paths = cleaned.map(\.item.path)
        tree?.forEach { $0.remove(paths: paths) }
        cleanupVersion += 1
        save()
    }

    /// Adds an item put back from the Trash to the lists and the saved scan.
    func applyRestore(_ item: ScanItem) {
        result?.restore(item)
        cleanupVersion += 1
        save()
    }

    private func skippedFolders(_ fullDiskAccess: Bool) -> Set<String> {
        fullDiskAccess ? [] : StorageScanner.protectedWithoutFullDiskAccess(home: home)
    }

    // MARK: Saved last scan

    private static var saveURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CleanMac")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "last-scan.json")
    }

    private static func loadSaved() -> ScanResult? {
        guard let data = try? Data(contentsOf: saveURL) else { return nil }
        return try? JSONDecoder().decode(ScanResult.self, from: data)
    }

    /// Atomic write: the old file is replaced only once the new one is fully written.
    private func save() {
        guard let result, let data = try? JSONEncoder().encode(result) else { return }
        try? data.write(to: Self.saveURL, options: .atomic)
    }
}
