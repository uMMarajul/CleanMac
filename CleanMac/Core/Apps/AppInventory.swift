import CoreServices
import Foundation
import Security

/// An installed app as found on disk.
struct DiscoveredApp: Sendable {
    let path: String
    let name: String
    let bundleID: String
    let version: String
    let bundleSize: Int64
    let associatedSize: Int64
    let lastOpened: Date?
    let isProtected: Bool
    let groups: [String]
}

/// A leftover file or folder that belongs to an app.
struct AssociatedFile: Identifiable, Hashable, Sendable {
    let path: String
    /// Where it lives, e.g. "Caches" or "Preferences".
    let kind: String
    let size: Int64
    let safety: SafetyClassification
    /// Matched by app name rather than bundle identifier: less certain.
    let byNameOnly: Bool
    /// Names of other installed apps using this shared folder. Shared folders are always kept.
    var sharedWith: String?
    var isFolder = false

    var id: String { path }
    var url: URL { URL(filePath: path) }
}

enum AppUsage: String, CaseIterable, Identifiable {
    case recent = "Recently Used"
    case occasional = "Occasionally Used"
    case unused = "Unused"
    case longUnused = "Long Unused"
    case unknown = "Unknown"

    var id: String { rawValue }

    static func classify(lastOpened: Date?, now: Date = .now, recentDays: Int, occasionalDays: Int, longUnusedDays: Int) -> AppUsage {
        guard let lastOpened else { return .unknown }
        let days = now.timeIntervalSince(lastOpened) / 86_400
        if days <= Double(recentDays) { return .recent }
        if days <= Double(occasionalDays) { return .occasional }
        if days <= Double(longUnusedDays) { return .unused }
        return .longUnused
    }
}

enum AppInventory {
    /// Folders searched for apps. `/System/Applications` is the sealed system volume and is left out.
    static func appFolders(home: URL, extra: [String]) -> [URL] {
        (["/Applications", home.path + "/Applications"] + extra)
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(filePath: $0) }
    }

    /// `.app` bundles in each folder and one level of sub-folders (e.g. /Applications/Utilities).
    static func discover(in folders: [URL]) -> [URL] {
        var apps: [URL] = []
        for folder in folders {
            for entry in contents(of: folder) {
                if entry.pathExtension == "app" {
                    apps.append(entry)
                } else if isPlainFolder(entry) {
                    apps += contents(of: entry).filter { $0.pathExtension == "app" }
                }
            }
        }
        return apps
    }

    static func scan(folders: [URL], home: URL) async -> [DiscoveredApp] {
        let urls = discover(in: folders)
        return await withTaskGroup(of: DiscoveredApp?.self) { group in
            for url in urls {
                group.addTask { info(for: url, home: home) }
            }
            var found: [DiscoveredApp] = []
            for await app in group {
                if let app { found.append(app) }
            }
            return found
        }
    }

    static func info(for url: URL, home: URL) -> DiscoveredApp? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let groups = appGroups(of: url)
        let leftovers = associatedFiles(bundleID: bundleID, name: name, groups: groups, home: home)
        return DiscoveredApp(
            path: url.path,
            name: name,
            bundleID: bundleID,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            bundleSize: StorageScanner.measure(url).bytes,
            associatedSize: totalSize(leftovers),
            lastOpened: lastOpened(url),
            isProtected: isSystemProtected(url),
            groups: groups
        )
    }

    /// Spotlight's "last used" date. nil for many background apps and helpers.
    static func lastOpened(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// True for apps macOS locks with System Integrity Protection (e.g. Safari).
    static func isSystemProtected(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_RESTRICTED) != 0
    }

    /// App group identifiers from the app's code signature. Each is a folder in Group Containers.
    static func appGroups(of url: URL) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let signing = info as? [String: Any],
              let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    /// Leftovers matched by exact bundle identifier or exact app name only, never by substring.
    static func associatedFiles(bundleID: String, name: String, groups: [String], home: URL) -> [AssociatedFile] {
        let library = home.path + "/Library"
        // (path, kind, safety, matched by name only)
        var candidates: [(String, String, SafetyClassification, Bool)] = [
            ("\(library)/Caches/\(bundleID)", "Caches", .safe, false),
            ("\(library)/Logs/\(bundleID)", "Logs", .safe, false),
            // May hold login cookies, so it needs review.
            ("\(library)/HTTPStorages/\(bundleID)", "Web Storage", .reviewRequired, false),
            ("\(library)/Saved Application State/\(bundleID).savedState", "Saved State", .safe, false),
            ("\(library)/Application Support/\(bundleID)", "Application Support", .reviewRequired, false),
            ("\(library)/Containers/\(bundleID)", "Container", .reviewRequired, false),
            ("\(library)/Preferences/\(bundleID).plist", "Preferences", .reviewRequired, false),
            ("\(library)/HTTPStorages/\(bundleID).binarycookies", "Cookies", .reviewRequired, false),
            ("\(library)/WebKit/\(bundleID)", "Website Data", .reviewRequired, false),
            ("\(library)/Application Support/\(name)", "Application Support", .reviewRequired, true),
            ("\(library)/Caches/\(name)", "Caches", .reviewRequired, true),
            ("\(library)/Logs/\(name)", "Logs", .reviewRequired, true),
        ]
        candidates += groups.map { ("\(library)/Group Containers/\($0)", "Group Container", .reviewRequired, false) }

        // Per-machine preferences: "<bundleID>.<hardware id>.plist", with no further dots.
        for file in contents(of: URL(filePath: "\(library)/Preferences/ByHost")).map(\.lastPathComponent)
        where file.hasPrefix(bundleID + ".") && file.hasSuffix(".plist") {
            let middle = file.dropFirst(bundleID.count + 1).dropLast(".plist".count)
            if !middle.isEmpty, !middle.contains(".") {
                candidates.append(("\(library)/Preferences/ByHost/\(file)", "Preferences", .reviewRequired, false))
            }
        }
        // Launch agents named after the app: "<bundleID>.plist" or "<bundleID>.<something>.plist".
        for file in contents(of: URL(filePath: "\(library)/LaunchAgents")).map(\.lastPathComponent)
        where file == bundleID + ".plist" || (file.hasPrefix(bundleID + ".") && file.hasSuffix(".plist")) {
            candidates.append(("\(library)/LaunchAgents/\(file)", "Launch Agent", .reviewRequired, false))
        }

        // Chromium/Electron caches inside the app's Application Support folders. They are caches
        // whichever app owns them, so they are Safe even when the folder was matched by name.
        for support in ["\(library)/Application Support/\(bundleID)", "\(library)/Application Support/\(name)"] {
            candidates += StorageCategory.supportCaches(in: URL(filePath: support))
                .map { ($0.path, "App Cache", .safe, false) }
        }

        var seen = Set<String>()
        return candidates.compactMap { path, kind, safety, byName in
            var isFolder: ObjCBool = false
            guard !seen.contains(path), FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { return nil }
            seen.insert(path)
            return AssociatedFile(
                path: path, kind: kind, size: StorageScanner.measure(URL(filePath: path)).bytes,
                safety: safety, byNameOnly: byName, isFolder: isFolder.boolValue
            )
        }
    }

    /// Total size without counting files nested inside other listed files twice.
    static func totalSize(_ files: [AssociatedFile]) -> Int64 {
        files.filter { file in
            !files.contains { $0.path != file.path && pathIsInside(file.path, $0.path) }
        }.reduce(0) { $0 + $1.size }
    }

    /// Bytes per kind for a breakdown, with nested items (e.g. an App Cache inside
    /// Application Support) subtracted from the folder that contains them.
    static func breakdown(_ files: [AssociatedFile]) -> [(kind: String, bytes: Int64)] {
        var bytes: [String: Int64] = [:]
        for file in files {
            let nested = files.filter { $0.path != file.path && pathIsInside($0.path, file.path) }
            bytes[file.kind, default: 0] += max(0, file.size - totalSize(nested))
        }
        return bytes.map { (kind: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }
    }

    /// Largest entries directly inside a folder, for drilling into an app's data.
    static func largestChildren(of path: String, limit: Int = 8) -> [(name: String, size: Int64)] {
        contents(of: URL(filePath: path))
            .map { (name: $0.lastPathComponent, size: StorageScanner.measure($0).bytes) }
            .sorted { $0.size > $1.size }
            .prefix(limit)
            .map { $0 }
    }

    /// Names of other apps that declare `group`, or nil if only this app uses it.
    static func sharing(group: String, excluding bundleID: String, apps: [(bundleID: String, name: String, groups: [String])]) -> String? {
        let others = apps.filter { $0.bundleID != bundleID && $0.groups.contains(group) }.map(\.name)
        return others.isEmpty ? nil : Set(others).sorted().joined(separator: ", ")
    }

    /// Default ticks. Keeping user data removes only Safe leftovers matched by bundle identifier.
    static func defaultSelection(_ files: [AssociatedFile], keepUserData: Bool) -> Set<String> {
        Set(files.filter { file in
            guard file.sharedWith == nil, !file.byNameOnly else { return false }
            return keepUserData ? file.safety == .safe : true
        }.map(\.path))
    }

    private static func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
    }

    private static func isPlainFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isPackage != true && values?.isSymbolicLink != true
    }
}
