import Foundation

struct Recommendation: Identifiable, Equatable {
    let icon: String
    let title: String
    let detail: String
    let bytes: Int64
    let target: SidebarSection
    var id: String { title }
}

/// Rule-based next steps for the Dashboard. Predictable on purpose: no AI, fixed thresholds.
enum Recommendations {
    struct Input {
        var home: URL
        var diskTotal: Int64
        var diskAvailable: Int64
        var result: ScanResult?
        var devItems: [DevItem]
        var apps: [(name: String, lastOpened: Date?, size: Int64, isProtected: Bool)]
        var longUnusedDays: Int
        var trashBytes: Int64?
        var pressure: MemoryPressure?
        var now = Date()
    }

    static let minimumWorthwhile: Int64 = 500_000_000

    static func build(_ input: Input, limit: Int = 5) -> [Recommendation] {
        var list: [Recommendation] = []

        // Below 10% or 20 GB free, everything else matters less.
        if input.diskTotal > 0, input.diskAvailable < max(input.diskTotal / 10, 20_000_000_000) {
            list.append(Recommendation(
                icon: "exclamationmark.triangle", title: "Low disk space: \(formatBytes(input.diskAvailable)) free",
                detail: "macOS slows down and updates can fail when the disk is nearly full.",
                bytes: .max, target: .systemData
            ))
        }

        if let pressure = input.pressure, pressure != .normal {
            list.append(Recommendation(
                icon: "memorychip", title: "Memory pressure is \(pressure.rawValue.lowercased())",
                detail: "Quit apps you are not using to keep your Mac responsive.",
                bytes: .max - 1, target: .performance
            ))
        }

        if let result = input.result {
            if result.safeBytes >= minimumWorthwhile {
                list.append(Recommendation(
                    icon: "trash", title: "Clean \(formatBytes(result.safeBytes)) of safe junk",
                    detail: "Caches, logs and build data that apps rebuild automatically.",
                    bytes: result.safeBytes, target: .junkCleaner
                ))
            }

            // The app with the most cache hidden inside Application Support.
            let supportCaches = result.categories.first { $0.category == .applicationCaches }?.items ?? []
            let byApp = Dictionary(grouping: supportCaches) {
                StorageCategory.supportCacheOwner(path: $0.path, home: input.home)
            }
            if let (app, items) = byApp.compactMap({ key, value in key.map { ($0, value) } })
                .max(by: { $0.1.reduce(0) { $0 + $1.size } < $1.1.reduce(0) { $0 + $1.size } }) {
                let bytes = items.reduce(0) { $0 + $1.size }
                if bytes >= minimumWorthwhile {
                    list.append(Recommendation(
                        icon: "archivebox", title: "Clear \(formatBytes(bytes)) of \(app) cache",
                        detail: "\(app) rebuilds it as you use it. Quit \(app) first.",
                        bytes: bytes, target: .applications
                    ))
                }
            }

            let large = result.largeFiles.reduce(0) { $0 + $1.size }
            if large >= 5_000_000_000 {
                list.append(Recommendation(
                    icon: "doc.badge.ellipsis", title: "\(result.largeFiles.count) large files use \(formatBytes(large))",
                    detail: "Review big files you may no longer need.",
                    bytes: large / 4, target: .largeFiles
                ))
            }
        }

        for runtime in input.devItems where runtime.id.hasPrefix("runtime-") && runtime.size >= minimumWorthwhile {
            let days = runtime.lastUsed.map { Int(input.now.timeIntervalSince($0) / 86_400) }
            guard days.map({ $0 >= 60 }) ?? true else { continue }
            list.append(Recommendation(
                icon: "ipad.and.iphone", title: "Remove the \(runtime.title) (\(formatBytes(runtime.size)))",
                detail: days.map { "Not used for \($0) days." } ?? "Never used.",
                bytes: runtime.size, target: .developerCleaner
            ))
        }

        let cutoff = input.now.addingTimeInterval(-Double(input.longUnusedDays) * 86_400)
        let unused = input.apps.filter { !$0.isProtected && ($0.lastOpened.map { $0 < cutoff } ?? false) }
        let unusedBytes = unused.reduce(0) { $0 + $1.size }
        if !unused.isEmpty, unusedBytes >= minimumWorthwhile {
            list.append(Recommendation(
                icon: "square.grid.2x2",
                title: "\(unused.count) app\(unused.count == 1 ? "" : "s") unused for \(input.longUnusedDays)+ days (\(formatBytes(unusedBytes)))",
                detail: "Uninstall apps you no longer need, with their leftover files.",
                bytes: unusedBytes, target: .applications
            ))
        }

        if let trash = input.trashBytes, trash >= 1_000_000_000 {
            list.append(Recommendation(
                icon: "trash.slash", title: "The Trash holds \(formatBytes(trash))",
                detail: "Space is only freed once the Trash is emptied.",
                bytes: trash, target: .junkCleaner
            ))
        }

        return Array(list.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }
}
