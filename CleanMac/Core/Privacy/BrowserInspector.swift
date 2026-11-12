import Foundation

enum BrowserEngine {
    case chromium, safari, firefox
}

struct BrowserSpec {
    let name: String
    let bundleID: String
    let engine: BrowserEngine
    /// Browser data folder, relative to ~/Library/Application Support (Chromium and Firefox).
    let support: String?
    /// Cache folders relative to the home folder.
    let caches: [String]
}

/// One browser's private data on disk, with sizes.
struct BrowserData: Identifiable {
    let spec: BrowserSpec
    let profiles: Int
    let cache: [String]
    let history: [String]
    let cookies: [String]
    let cacheBytes: Int64
    let historyBytes: Int64
    let cookieBytes: Int64
    let extensions: [String]
    /// Why history cannot be cleared from CleanMac, if it cannot.
    let historyNote: String?

    var id: String { spec.bundleID }
}

/// Reads browser caches, history, cookies and extensions. Read-only; clearing goes through `CleanupEngine`.
enum BrowserInspector {
    static let browsers: [BrowserSpec] = [
        BrowserSpec(name: "Safari", bundleID: "com.apple.Safari", engine: .safari, support: nil,
                    caches: ["Library/Caches/com.apple.Safari", "Library/Containers/com.apple.Safari/Data/Library/Caches"]),
        BrowserSpec(name: "Google Chrome", bundleID: "com.google.Chrome", engine: .chromium, support: "Google/Chrome",
                    caches: ["Library/Caches/Google/Chrome"]),
        BrowserSpec(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", engine: .chromium, support: "Microsoft Edge",
                    caches: ["Library/Caches/Microsoft Edge"]),
        BrowserSpec(name: "Brave", bundleID: "com.brave.Browser", engine: .chromium, support: "BraveSoftware/Brave-Browser",
                    caches: ["Library/Caches/BraveSoftware/Brave-Browser"]),
        BrowserSpec(name: "Arc", bundleID: "company.thebrowser.Browser", engine: .chromium, support: "Arc/User Data",
                    caches: ["Library/Caches/Arc"]),
        BrowserSpec(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", engine: .chromium, support: "Vivaldi",
                    caches: ["Library/Caches/Vivaldi"]),
        BrowserSpec(name: "Opera", bundleID: "com.operasoftware.Opera", engine: .chromium, support: "com.operasoftware.Opera",
                    caches: ["Library/Caches/com.operasoftware.Opera"]),
        BrowserSpec(name: "Firefox", bundleID: "org.mozilla.firefox", engine: .firefox, support: "Firefox",
                    caches: ["Library/Caches/Firefox"]),
    ]

    /// Browser data folders and the app that must be quit before they are touched.
    static func dataOwners(home: URL) -> [String: String] {
        var owners: [String: String] = [home.path + "/Library/Safari": "com.apple.Safari"]
        for browser in browsers {
            if let support = browser.support {
                owners[home.path + "/Library/Application Support/" + support] = browser.bundleID
            }
        }
        return owners
    }

    /// Browsers that are installed or have data on disk.
    static func inspect(home: URL, isInstalled: (String) -> Bool, safariExtensions: () -> [String]) -> [BrowserData] {
        browsers.compactMap { spec in
            let data = inspect(spec, home: home, safariExtensions: spec.engine == .safari ? safariExtensions() : [])
            let hasData = data.cacheBytes + data.historyBytes + data.cookieBytes > 0
            return isInstalled(spec.bundleID) || hasData ? data : nil
        }
    }

    static func inspect(_ spec: BrowserSpec, home: URL, safariExtensions: [String] = []) -> BrowserData {
        let library = home.path + "/Library"
        var cache = spec.caches.map { home.path + "/" + $0 }
        var history: [String] = []
        var cookies: [String] = []
        var extensions: [String] = []
        var profiles = 1
        var historyNote: String?

        switch spec.engine {
        case .safari:
            history = ["History.db", "History.db-wal", "History.db-shm", "History.db-lock"].map { "\(library)/Safari/\($0)" }
            cookies = [
                "\(library)/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
                "\(library)/Cookies/Cookies.binarycookies",
            ]
            extensions = safariExtensions

        case .chromium:
            let base = URL(filePath: "\(library)/Application Support/\(spec.support ?? "")")
            let found = chromiumProfiles(base: base)
            profiles = found.count
            for profile in found {
                let p = profile.path
                history += ["History", "History-journal"].map { "\(p)/\($0)" }
                cookies += ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"].map { "\(p)/\($0)" }
                cache += ["Cache", "Code Cache", "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache", "Service Worker/CacheStorage"]
                    .map { "\(p)/\($0)" }
                extensions += chromiumExtensionNames(profile: profile)
            }

        case .firefox:
            let found = firefoxProfiles(home: home)
            profiles = found.count
            for profile in found {
                cookies += ["cookies.sqlite", "cookies.sqlite-wal", "cookies.sqlite-shm"].map { "\(profile.path)/\($0)" }
                extensions += firefoxExtensionNames(profile: profile)
            }
            historyNote = "Firefox keeps history and bookmarks in the same file, so clear history in Firefox → Settings → Privacy."
        }

        let existing = { (paths: [String]) in paths.filter { FileManager.default.fileExists(atPath: $0) } }
        let size = { (paths: [String]) in paths.reduce(Int64(0)) { $0 + StorageScanner.measure(URL(filePath: $1)).bytes } }
        let (c, h, k) = (existing(cache), existing(history), existing(cookies))
        return BrowserData(
            spec: spec, profiles: profiles, cache: c, history: h, cookies: k,
            cacheBytes: size(c), historyBytes: size(h), cookieBytes: size(k),
            extensions: Array(Set(extensions)).sorted(), historyNote: historyNote
        )
    }

    /// "Default" and "Profile N" folders of a Chromium browser.
    static func chromiumProfiles(base: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Extension names from `Extensions/<id>/<version>/manifest.json`, resolving "__MSG_…__" names.
    static func chromiumExtensionNames(profile: URL) -> [String] {
        let root = profile.appending(path: "Extensions")
        let ids = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return ids.compactMap { id in
            let versions = (try? FileManager.default.contentsOfDirectory(at: id, includingPropertiesForKeys: nil)) ?? []
            guard let version = versions.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).last,
                  let manifest = json(version.appending(path: "manifest.json")),
                  var name = manifest["name"] as? String else { return nil }
            if name.hasPrefix("__MSG_"), name.hasSuffix("__") {
                let key = String(name.dropFirst(6).dropLast(2))
                let locale = manifest["default_locale"] as? String ?? "en"
                let messages = json(version.appending(path: "_locales/\(locale)/messages.json")) ?? [:]
                let entry = messages.first { $0.key.lowercased() == key.lowercased() }?.value as? [String: Any]
                name = entry?["message"] as? String ?? id.lastPathComponent
            }
            return name
        }
    }

    static func firefoxProfiles(home: URL) -> [URL] {
        let root = home.appending(path: "Library/Application Support/Firefox/Profiles")
        return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }

    /// Add-ons the user installed, from the profile's extensions.json.
    static func firefoxExtensionNames(profile: URL) -> [String] {
        guard let addons = json(profile.appending(path: "extensions.json"))?["addons"] as? [[String: Any]] else { return [] }
        return addons.compactMap { addon in
            guard addon["type"] as? String == "extension", addon["location"] as? String == "app-profile" else { return nil }
            return (addon["defaultLocale"] as? [String: Any])?["name"] as? String
        }
    }

    /// Safari web extensions registered with macOS.
    static func safariExtensions() -> [String] {
        parsePluginkit(DeveloperTools.run("/usr/bin/pluginkit", ["-mA", "-p", "com.apple.Safari.web-extension"]).output)
    }

    /// pluginkit lines look like "+    com.example.Extension(1.2)".
    static func parsePluginkit(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "+-!=? \t"))
            guard let id = trimmed.split(separator: "(").first, !id.isEmpty else { return nil }
            return String(id).trimmingCharacters(in: .whitespaces)
        }
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
