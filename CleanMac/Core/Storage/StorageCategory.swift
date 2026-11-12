import Foundation
import UniformTypeIdentifiers

/// CleanMac's analytical storage categories. These are not Apple's official System Data subcategories.
enum StorageCategory: String, CaseIterable, Identifiable, Hashable, Codable {
    case applicationCaches, browserCaches, systemCaches, applicationSupport, developerData
    case xcodeDerivedData, xcodeArchives, deviceBackups, simulatorData, dockerData
    case jsPackageCaches, jvmCaches, pythonGoCaches
    case applicationLogs, temporaryFiles, mailAttachments, messageAttachments
    case virtualMachines, localSnapshots, macOSUpdates, oldInstallers, otherLargeFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .applicationCaches: "Application Caches"
        case .browserCaches: "Browser Caches"
        case .systemCaches: "System Caches"
        case .applicationSupport: "Application Support"
        case .developerData: "Developer Data"
        case .xcodeDerivedData: "Xcode DerivedData"
        case .xcodeArchives: "Xcode Archives"
        case .deviceBackups: "iOS Device Backups"
        case .simulatorData: "iOS Simulator Data"
        case .dockerData: "Docker Data"
        case .jsPackageCaches: "npm, pnpm & Yarn Caches"
        case .jvmCaches: "Gradle & Maven Caches"
        case .pythonGoCaches: "Python & Go Caches"
        case .applicationLogs: "Application Logs"
        case .temporaryFiles: "Temporary Files"
        case .mailAttachments: "Mail Attachments"
        case .messageAttachments: "Message Attachments"
        case .virtualMachines: "Virtual Machine Images"
        case .localSnapshots: "Local Time Machine Snapshots"
        case .macOSUpdates: "macOS Update Files"
        case .oldInstallers: "Old Installers"
        case .otherLargeFiles: "Other Large Files"
        }
    }

    var summary: String {
        switch self {
        case .applicationCaches: "Data apps cache for speed. Rebuilt automatically."
        case .browserCaches: "Cached web pages and images. Browsers rebuild them."
        case .systemCaches: "Caches shared by all users."
        case .applicationSupport: "App data and settings. Often user data."
        case .developerData: "Developer tools data not covered by a more specific category."
        case .xcodeDerivedData: "Xcode build output and indexes. Rebuilt on next build."
        case .xcodeArchives: "Archived app builds, needed to re-submit past versions."
        case .deviceBackups: "Local iPhone and iPad backups."
        case .simulatorData: "Simulator devices, runtimes and their data."
        case .dockerData: "Docker images, containers and volumes."
        case .jsPackageCaches: "Downloaded JavaScript packages. Re-downloaded when needed."
        case .jvmCaches: "Downloaded Java and Android dependencies. Re-downloaded when needed."
        case .pythonGoCaches: "pip, Poetry and Go build caches and modules."
        case .applicationLogs: "Log files written by apps and the system."
        case .temporaryFiles: "Temporary files. Some are in active use."
        case .mailAttachments: "Mail messages and downloaded attachments."
        case .messageAttachments: "Photos and files received in Messages."
        case .virtualMachines: "Virtual machine disks and bundles."
        case .localSnapshots: "Snapshots macOS keeps for Time Machine. Managed by macOS."
        case .macOSUpdates: "Downloaded macOS updates. Managed by macOS."
        case .oldInstallers: "Disk images and installer packages in Downloads, older than 30 days."
        case .otherLargeFiles: "Large files outside the categories above."
        }
    }

    var icon: String {
        switch self {
        case .applicationCaches: "archivebox"
        case .browserCaches: "globe"
        case .systemCaches: "gearshape.2"
        case .applicationSupport: "folder.badge.gearshape"
        case .developerData: "hammer"
        case .xcodeDerivedData: "hammer.circle"
        case .xcodeArchives: "shippingbox"
        case .deviceBackups: "iphone"
        case .simulatorData: "ipad.and.iphone"
        case .dockerData: "cube.box"
        case .jsPackageCaches: "curlybraces"
        case .jvmCaches: "cup.and.saucer"
        case .pythonGoCaches: "chevron.left.forwardslash.chevron.right"
        case .applicationLogs: "doc.text"
        case .temporaryFiles: "clock.arrow.circlepath"
        case .mailAttachments: "envelope"
        case .messageAttachments: "message"
        case .virtualMachines: "desktopcomputer"
        case .localSnapshots: "camera.aperture"
        case .macOSUpdates: "arrow.down.circle"
        case .oldInstallers: "opticaldiscdrive"
        case .otherLargeFiles: "doc.badge.ellipsis"
        }
    }

    var safety: SafetyClassification {
        switch self {
        case .applicationCaches, .browserCaches, .xcodeDerivedData, .jsPackageCaches, .jvmCaches,
             .pythonGoCaches, .applicationLogs:
            .safe
        case .localSnapshots, .macOSUpdates:
            .protected
        default:
            .reviewRequired
        }
    }

    /// Review categories people commonly clean. Counted in "Potentially Recoverable";
    /// other Review categories (Application Support, Mail, …) are mostly real data and are not.
    static let commonlyCleaned: Set<StorageCategory> = [.oldInstallers, .simulatorData, .xcodeArchives]

    /// Categories the Junk Cleaner offers.
    static let junk: Set<StorageCategory> = [
        .applicationCaches, .browserCaches, .applicationLogs, .xcodeDerivedData,
        .jsPackageCaches, .jvmCaches, .pythonGoCaches, .oldInstallers,
    ]

    /// Folders Quick Scan reads. Nested rules (pip, browsers, …) are found inside them.
    static func quickScanRoots(home: URL) -> [URL] {
        [
            "Library/Caches", "Library/Logs", "Library/Developer/Xcode/DerivedData",
            ".npm", "Library/pnpm", ".yarn/berry/cache", ".gradle", ".m2/repository",
            ".cache/pip", "go/pkg/mod", "Downloads",
        ].map { home.appending(path: $0) } + supportCacheFolders(home: home)
    }

    // MARK: Caches inside Application Support

    /// Cache folders Chromium and Electron apps (Claude, Slack, VS Code, …) keep inside
    /// Application Support instead of ~/Library/Caches. Rebuilt automatically.
    static let chromiumCacheNames: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "GrShaderCache", "ShaderCache",
    ]

    /// The app folder name when `path` is such a cache, e.g. ".../Application Support/Claude/Cache",
    /// ".../Claude/Partitions/<name>/Code Cache" or ".../Claude/Service Worker/CacheStorage".
    /// Deeper layouts (like Chrome's own profiles) are deliberately not matched.
    static func supportCacheOwner(path: String, home: URL) -> String? {
        let support = home.path + "/Library/Application Support/"
        guard path.hasPrefix(support) else { return nil }
        let parts = path.dropFirst(support.count).split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var rest = Array(parts.dropFirst())
        if rest.count >= 3, rest[0] == "Partitions" { rest = Array(rest.dropFirst(2)) }
        let isCache = (rest.count == 1 && chromiumCacheNames.contains(rest[0]))
            || (rest.count == 2 && rest[0] == "Service Worker" && ["CacheStorage", "ScriptCache"].contains(rest[1]))
        return isCache ? parts[0] : nil
    }

    /// Existing cache folders inside one app's Application Support folder.
    static func supportCaches(in appFolder: URL) -> [URL] {
        let fileManager = FileManager.default
        let partitions = (try? fileManager.contentsOfDirectory(at: appFolder.appending(path: "Partitions"), includingPropertiesForKeys: nil)) ?? []
        let bases = [appFolder] + partitions
        let names = chromiumCacheNames.map { $0 } + ["Service Worker/CacheStorage", "Service Worker/ScriptCache"]
        return bases.flatMap { base in names.map { base.appending(path: $0) } }.filter { url in
            var isFolder: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
        }
    }

    /// Every such cache across all apps in ~/Library/Application Support.
    static func supportCacheFolders(home: URL) -> [URL] {
        let support = home.appending(path: "Library/Application Support")
        let apps = (try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? []
        return apps.flatMap(supportCaches(in:))
    }

    /// Cache folders whose owner app must be quit before cleaning, by bundle identifier.
    static func cacheOwners(home: URL) -> [String: String] {
        let caches = home.path + "/Library/Caches"
        return [
            caches + "/Google/Chrome": "com.google.Chrome",
            caches + "/com.apple.Safari": "com.apple.Safari",
            caches + "/Firefox": "org.mozilla.firefox",
            caches + "/Microsoft Edge": "com.microsoft.edgemac",
            caches + "/BraveSoftware": "com.brave.Browser",
        ]
    }

    /// Category of a path by the deepest matching rule folder, or nil (uncategorized).
    static func category(forPath path: String, home: URL) -> StorageCategory? {
        rules(home: home)
            .filter { pathIsInside(path, $0.key) }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    /// Folder path → category. The deepest matching folder wins, so nested rules never double count.
    static func rules(home: URL) -> [String: StorageCategory] {
        let h = home.path
        var rules: [String: StorageCategory] = [
            h + "/Library/Caches": .applicationCaches,
            "/Library/Caches": .systemCaches,
            h + "/Library/Application Support": .applicationSupport,
            "/Library/Application Support": .applicationSupport,
            h + "/Library/Developer": .developerData,
            h + "/Library/Developer/Xcode/DerivedData": .xcodeDerivedData,
            h + "/Library/Developer/Xcode/Archives": .xcodeArchives,
            h + "/Library/Application Support/MobileSync/Backup": .deviceBackups,
            h + "/Library/Developer/CoreSimulator": .simulatorData,
            "/Library/Developer/CoreSimulator": .simulatorData,
            h + "/Library/Containers/com.docker.docker": .dockerData,
            h + "/.docker": .dockerData,
            h + "/.npm": .jsPackageCaches,
            h + "/Library/pnpm": .jsPackageCaches,
            h + "/Library/Caches/pnpm": .jsPackageCaches,
            h + "/Library/Caches/Yarn": .jsPackageCaches,
            h + "/.yarn/berry/cache": .jsPackageCaches,
            h + "/.gradle": .jvmCaches,
            h + "/.m2/repository": .jvmCaches,
            h + "/Library/Caches/pip": .pythonGoCaches,
            h + "/Library/Caches/pypoetry": .pythonGoCaches,
            h + "/Library/Caches/go-build": .pythonGoCaches,
            h + "/.cache/pip": .pythonGoCaches,
            h + "/go/pkg/mod": .pythonGoCaches,
            h + "/Library/Logs": .applicationLogs,
            "/Library/Logs": .applicationLogs,
            "/private/var/log": .applicationLogs,
            "/private/tmp": .temporaryFiles,
            "/private/var/tmp": .temporaryFiles,
            "/private/var/folders": .temporaryFiles,
            h + "/Library/Mail": .mailAttachments,
            h + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads": .mailAttachments,
            h + "/Library/Messages": .messageAttachments,
            h + "/Parallels": .virtualMachines,
            h + "/Virtual Machines.localized": .virtualMachines,
            h + "/Library/Containers/com.utmapp.UTM": .virtualMachines,
            "/Library/Updates": .macOSUpdates,
        ]
        for path in cacheOwners(home: home).keys {
            rules[path] = .browserCaches
        }
        return rules
    }
}

enum FileKind: String, CaseIterable, Identifiable {
    case all = "All Types", video = "Video", archive = "Archive", diskImage = "Disk Image"
    case document = "Document", other = "Other"

    var id: String { rawValue }

    init(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            self = .other
            return
        }
        if type.conforms(to: .audiovisualContent) {
            self = .video
        } else if type.conforms(to: .diskImage) {
            self = .diskImage
        } else if type.conforms(to: .archive) {
            self = .archive
        } else if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
                    || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent) {
            self = .document
        } else {
            self = .other
        }
    }
}

enum StorageAnalyzer {
    /// Uncategorized files at least this big count as "Other Large Files".
    static let otherLargeThreshold: Int64 = 100_000_000
    /// Smallest file kept for the Large Files screen.
    static let largeFileFloor: Int64 = 50_000_000
    /// Items listed per category.
    static let itemsPerCategory = 200
    static let vmExtensions: Set<String> = ["vmdk", "vdi", "qcow2", "vhd", "vhdx", "utm", "pvm", "vmwarevm", "hdd"]
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso"]

    struct Analysis {
        var categories: [CategoryTotal]
        var otherBytes: Int64
        var largeFiles: [ScanItem]
    }

    /// Assigns every byte to exactly one category (or "other"). Apps are left to the Applications screen.
    static func analyze(_ roots: [FileNode], home: URL, largeFileFloor: Int64 = largeFileFloor) -> Analysis {
        let rules = StorageCategory.rules(home: home)
        let downloads = home.path + "/Downloads"
        let monthAgo = Date().addingTimeInterval(-30 * 24 * 3600)
        var totals = Dictionary(uniqueKeysWithValues: StorageCategory.allCases.map { ($0, CategoryTotal(category: $0)) })
        var starts: [StorageCategory: [FileNode]] = [:]
        /// Starts listed as one item rather than by their contents (app caches found by name).
        var listedWhole = Set<ObjectIdentifier>()
        var other: Int64 = 0
        var large: [ScanItem] = []

        func add(_ category: StorageCategory?, _ bytes: Int64, _ files: Int) {
            if let category {
                totals[category]!.bytes += bytes
                totals[category]!.files += files
            } else {
                other += bytes
            }
        }

        func visit(_ node: FileNode, _ inherited: StorageCategory?) {
            let isItem = !node.isDirectory || node.isPackage
            let ext = node.url.pathExtension.lowercased()
            var category = inherited
            if let ruled = rules[node.path] {
                category = ruled
            } else if StorageCategory.supportCacheOwner(path: node.path, home: home) != nil {
                category = .applicationCaches
                listedWhole.insert(ObjectIdentifier(node))
            } else if category == nil, isItem, vmExtensions.contains(ext) {
                category = .virtualMachines
            } else if category == nil, !node.isDirectory, installerExtensions.contains(ext),
                      node.url.deletingLastPathComponent().path == downloads,
                      (node.modified ?? .now) < monthAgo {
                category = .oldInstallers
            } else if category == nil, isItem, ext != "app", node.size >= otherLargeThreshold {
                category = .otherLargeFiles
            }
            if let category, category != inherited {
                node.ruleCategory = category
                starts[category, default: []].append(node)
            }
            if isItem, ext != "app", node.size >= largeFileFloor {
                large.append(ScanItem(node: node, category: category))
            }
            if isItem {
                add(category, node.size, node.fileCount)
                return
            }
            add(category, node.looseBytes, node.looseCount)
            for child in node.children { visit(child, category) }
        }

        roots.forEach { visit($0, nil) }

        // Each category lists the items inside the folders where it starts,
        // leaving out sub-folders that belong to a different category.
        for (category, nodes) in starts {
            totals[category]!.items = nodes
                .flatMap { start in
                    start.children.isEmpty || listedWhole.contains(ObjectIdentifier(start))
                        ? [start]
                        : start.children.filter { $0.ruleCategory == nil || $0.ruleCategory == category }
                }
                .sorted { $0.size > $1.size }
                .prefix(itemsPerCategory)
                .map { ScanItem(node: $0, category: category) }
        }

        return Analysis(
            categories: totals.values.sorted { $0.bytes > $1.bytes },
            otherBytes: other,
            largeFiles: large.sorted { $0.size > $1.size }
        )
    }
}
