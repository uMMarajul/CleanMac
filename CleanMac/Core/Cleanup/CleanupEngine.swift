import AppKit
import Foundation

struct CleanupReport {
    var cleaned: [CleanedItem] = []
    var skipped: [(item: ScanItem, reason: String)] = []
    var freedBytes: Int64 { cleaned.reduce(0) { $0 + $1.size } }
}

struct CleanupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The only place CleanMac moves or deletes files. Screens never touch the file system directly.
enum CleanupEngine {
    typealias RunningApp = (bundleID: String, name: String)

    /// Never cleaned, nor anything inside them.
    private static let systemLocations = [
        "/System", "/bin", "/sbin", "/usr", "/Applications", "/Library/Updates",
        "/private/var/db", "/private/var/vm", "/private/var/folders",
    ]

    /// Cleanable locations outside the home folder.
    private static let extraCleanableRoots = ["/Library/Caches", "/Library/Logs", "/private/tmp", "/private/var/tmp", "/Users/Shared"]

    /// Folders that are never removed themselves, though some of their contents may be.
    static func essentialFolders(home: URL) -> Set<String> {
        let h = home.path
        let inHome = [
            "Library", "Library/Caches", "Library/Logs", "Library/Application Support", "Library/Developer",
            "Library/Containers", "Library/Group Containers", "Library/Mobile Documents", "Library/Preferences",
            "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Applications", "Public", ".Trash",
        ].map { h + "/" + $0 }
        return Set(["/", "/Users", h] + inHome + extraCleanableRoots)
    }

    /// Rules that need no disk access: why `item` can never be cleaned, or nil.
    static func locationRefusal(for item: ScanItem, home: URL) -> String? {
        let path = item.path
        if item.category?.safety == .protected { return "Protected by macOS" }
        if essentialFolders(home: home).contains(path) { return "Essential folder" }
        if pathIsInside(path, home.path) { return nil }
        if systemLocations.contains(where: { pathIsInside(path, $0) }) { return "System location" }
        return extraCleanableRoots.contains { pathIsInside(path, $0) } ? nil : "Outside cleanable locations"
    }

    /// All checks, including the current state of the disk and running apps.
    static func refusal(for item: ScanItem, home: URL, runningApps: [RunningApp]) -> String? {
        if let reason = locationRefusal(for: item, home: home) { return reason }

        let path = item.path
        guard let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else {
            return "No longer exists"
        }
        if type == .typeSymbolicLink { return "Is a symbolic link" }
        // A real app bundle, not just a folder named like "com.example.app".
        if item.url.pathExtension == "app", FileManager.default.fileExists(atPath: path + "/Contents/Info.plist") {
            return "Apps are removed from the Applications screen"
        }
        if !FileManager.default.isDeletableFile(atPath: path) { return "Needs administrator permission" }

        let components = item.url.pathComponents.map { $0.lowercased() }
        if let app = runningApps.first(where: { components.contains($0.bundleID.lowercased()) }) {
            return "Quit \(app.name) first"
        }
        // Caches inside Application Support are named after the app folder, not the bundle ID.
        if let owner = StorageCategory.supportCacheOwner(path: path, home: home)?.lowercased(),
           let app = runningApps.first(where: {
               $0.name.lowercased() == owner || $0.bundleID.lowercased() == owner
                   || $0.bundleID.split(separator: ".").last?.lowercased() == owner
           }) {
            return "Quit \(app.name) first"
        }
        // Browser caches and browser data (history, cookies, profiles) need the browser quit.
        let owners = StorageCategory.cacheOwners(home: home)
            .merging(BrowserInspector.dataOwners(home: home)) { first, _ in first }
        for (ownerPath, bundleID) in owners
        where pathIsInside(path, ownerPath) || pathIsInside(ownerPath, path) {
            if let app = runningApps.first(where: { $0.bundleID == bundleID }) {
                return "Quit \(app.name) first"
            }
        }
        return nil
    }

    /// Checks each item, re-measures it, and moves it to the Trash.
    static func clean(_ items: [ScanItem], home: URL, runningApps: [RunningApp]) -> CleanupReport {
        // If a folder and something inside it are both selected, trash only the folder.
        var chosen: [ScanItem] = []
        for item in items.sorted(by: { $0.path < $1.path })
        where !chosen.contains(where: { pathIsInside(item.path, $0.path) }) {
            chosen.append(item)
        }

        var report = CleanupReport()
        for item in chosen {
            if let reason = refusal(for: item, home: home, runningApps: runningApps) {
                report.skipped.append((item, reason))
                continue
            }
            let size = StorageScanner.measure(item.url).bytes
            let originalPermissions = makeMovable(item.url)
            do {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashed)
                report.cleaned.append(CleanedItem(item: item, size: size, trashPath: (trashed as URL?)?.path))
            } catch {
                if let originalPermissions {
                    try? FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: item.path)
                }
                report.skipped.append((item, error.localizedDescription))
            }
        }
        return report
    }

    // MARK: Uninstall

    /// Why an app bundle must not be uninstalled, or nil.
    static func appRefusal(appPath: String, bundleID: String, appFolders: [URL], runningApps: [RunningApp]) -> String? {
        let url = URL(filePath: appPath)
        guard appFolders.contains(where: { pathIsInside(appPath, $0.path) && appPath != $0.path }) else {
            return "Not in an applications folder"
        }
        guard url.pathExtension == "app", FileManager.default.fileExists(atPath: appPath + "/Contents/Info.plist") else {
            return "Not an app bundle"
        }
        if AppInventory.isSystemProtected(url) { return "Protected by macOS" }
        if let app = runningApps.first(where: { $0.bundleID == bundleID }) { return "Quit \(app.name) first" }
        return nil
    }

    /// Moves the app (optional) and selected leftovers to the Trash. The app goes first through
    /// `NSWorkspace.recycle`, which shows macOS's own password prompt for apps owned by the system,
    /// like Finder does. If that fails or is cancelled, no leftovers are touched.
    static func uninstall(
        app: ScanItem?,
        bundleID: String,
        leftovers: [ScanItem],
        appFolders: [URL],
        home: URL,
        runningApps: [RunningApp]
    ) async -> CleanupReport {
        var report = CleanupReport()
        if let app {
            if let reason = appRefusal(appPath: app.path, bundleID: bundleID, appFolders: appFolders, runningApps: runningApps) {
                report.skipped.append((app, reason))
                return report
            }
            let size = StorageScanner.measure(app.url).bytes
            do {
                let moved = try await NSWorkspace.shared.recycle([app.url])
                let trashPath = moved.first { $0.key.path == app.path }?.value.path
                report.cleaned.append(CleanedItem(item: app, size: size, trashPath: trashPath))
            } catch {
                report.skipped.append((app, error.localizedDescription))
                return report
            }
        }
        let rest = clean(leftovers, home: home, runningApps: runningApps)
        report.cleaned += rest.cleaned
        report.skipped += rest.skipped
        return report
    }

    /// Moving a folder needs write permission on the folder itself. Some tools (Go's module
    /// cache) mark their folders read-only on purpose. For a read-only folder the user owns,
    /// adds the owner's write bit and returns the original permissions; otherwise changes nothing.
    private static func makeMovable(_ url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o200 == 0
        else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: permissions | 0o200], ofItemAtPath: url.path)
        return permissions
    }

    /// Moves an item from the Trash back to where it was.
    static func putBack(trashPath: String, originalPath: String) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: trashPath) else {
            throw CleanupError(message: "It is no longer in the Trash.")
        }
        guard !fileManager.fileExists(atPath: originalPath) else {
            throw CleanupError(message: "Something already exists at the original location.")
        }
        let original = URL(filePath: originalPath)
        try fileManager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: URL(filePath: trashPath), to: original)
    }

    static func trashFolder(home: URL) -> URL {
        home.appending(path: ".Trash")
    }

    /// Permanently deletes everything in the user's Trash. Cannot be undone.
    static func emptyTrash(home: URL) -> (freed: Int64, failed: Int) {
        let trash = trashFolder(home: home)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else {
            return (0, 0)
        }
        var freed: Int64 = 0
        var failed = 0
        for item in contents {
            let size = StorageScanner.measure(item).bytes
            do {
                try FileManager.default.removeItem(at: item)
                freed += size
            } catch {
                failed += 1
            }
        }
        return (freed, failed)
    }
}
