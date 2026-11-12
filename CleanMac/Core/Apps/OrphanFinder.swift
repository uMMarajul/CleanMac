import Foundation

/// A Library item named after an app that is no longer installed.
struct OrphanItem: Identifiable, Hashable {
    let path: String
    let bundleID: String
    let kind: String
    let size: Int64
    /// An installed app from the same developer, which may still use this item.
    let relatedApp: String?

    var id: String { path }
    var url: URL { URL(filePath: path) }
}

/// Finds leftovers of removed apps: entries named like a bundle identifier that no installed
/// app matches. Always Review: the app may live on an external drive or be reinstalled later.
enum OrphanFinder {
    static let locations: [(folder: String, kind: String)] = [
        ("Application Support", "Application Support"), ("Caches", "Caches"), ("Containers", "Container"),
        ("Preferences", "Preferences"), ("Saved Application State", "Saved State"), ("HTTPStorages", "Web Storage"),
        ("WebKit", "Website Data"), ("Logs", "Logs"), ("LaunchAgents", "Launch Agent"),
    ]

    /// "com.example.app.plist" → "com.example.app". nil unless it looks like a reverse-DNS identifier.
    static func bundleID(fromEntry name: String) -> String? {
        var id = name
        for suffix in [".plist", ".savedState", ".binarycookies"] where id.hasSuffix(suffix) {
            id = String(id.dropLast(suffix.count))
        }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } })
        else { return nil }
        return id
    }

    /// Installed when an app has this identifier, or one is a sub-identifier of the other
    /// (helpers like "com.foo.app.helper" belong to "com.foo.app").
    static func isInstalled(_ id: String, installed: Set<String>) -> Bool {
        let id = id.lowercased()
        return installed.contains { app in
            let app = app.lowercased()
            return id == app || id.hasPrefix(app + ".") || app.hasPrefix(id + ".")
        }
    }

    static func find(
        home: URL,
        installed: [(bundleID: String, name: String)],
        knownToSystem: (String) -> Bool
    ) -> [OrphanItem] {
        let installedIDs = Set(installed.map(\.bundleID))
        var items: [OrphanItem] = []
        for (folder, kind) in locations {
            let base = home.appending(path: "Library/\(folder)")
            let entries = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                guard let id = bundleID(fromEntry: entry.lastPathComponent),
                      !id.lowercased().hasPrefix("com.apple."),
                      !isInstalled(id, installed: installedIDs),
                      !knownToSystem(id)
                else { continue }
                items.append(OrphanItem(
                    path: entry.path, bundleID: id, kind: kind,
                    size: StorageScanner.measure(entry).bytes,
                    relatedApp: sameDeveloper(id, installed: installed)
                ))
            }
        }
        return items.sorted { $0.size > $1.size }
    }

    /// An installed app whose identifier starts with the same two parts ("com.google").
    static func sameDeveloper(_ id: String, installed: [(bundleID: String, name: String)]) -> String? {
        let vendor = id.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
        return installed.first { $0.bundleID.lowercased().hasPrefix(vendor + ".") }?.name
    }
}
