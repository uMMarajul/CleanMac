import Foundation

/// How a developer item is cleaned.
enum DevAction: Hashable {
    /// Reversible: moved to the Trash through `CleanupEngine`.
    case trash(String)
    /// Permanent: runs the tool's own clean command (each array is one invocation).
    case command(tool: String, invocations: [[String]])
    /// Shown for information only (e.g. Docker volumes).
    case none
}

struct DevItem: Identifiable, Hashable {
    let id: String
    let group: String
    let title: String
    let detail: String
    let size: Int64
    let safety: SafetyClassification
    let action: DevAction
    /// When the item was last used, if known (simulator runtimes).
    var lastUsed: Date? = nil
}

struct SimRuntime: Equatable {
    let identifier: String
    let name: String
    let sizeBytes: Int64
    let lastUsed: Date?
    let deletable: Bool
}

/// Finds developer tool data (Xcode, simulators, Docker, package caches) and cleans it.
/// Source code, git repositories, project dependencies and Docker volumes are never touched.
enum DeveloperTools {
    static let groups = ["Xcode", "Simulators", "Docker", "Package Caches"]
    static let xcrun = "/usr/bin/xcrun"
    static let dockerPaths = [
        "/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker",
    ]

    static func scan(home: URL) async -> [DevItem] {
        async let folders = folderItems(home: home)
        async let simulators = Task.detached { simulatorItems(home: home) }.value
        async let docker = Task.detached { dockerItems() }.value
        return await folders + simulators + docker
    }

    /// Runs a permanent clean command. Returns an error message, or nil on success.
    static func perform(_ action: DevAction) -> String? {
        guard case let .command(tool, invocations) = action else { return nil }
        for arguments in invocations {
            let result = run(tool, arguments)
            if !result.ok {
                return result.error.isEmpty ? "The command failed." : result.error
            }
        }
        return nil
    }

    // MARK: Folders

    private struct FolderSpec {
        let group: String, title: String, detail: String, path: String, safety: SafetyClassification
    }

    private static func folderSpecs(home: URL) -> [FolderSpec] {
        let h = home.path
        let xcode = h + "/Library/Developer/Xcode"
        return [
            FolderSpec(group: "Xcode", title: "DerivedData", detail: "Build output and indexes. Rebuilt on the next build.", path: xcode + "/DerivedData", safety: .safe),
            FolderSpec(group: "Xcode", title: "Archives", detail: "Archived builds, needed to re-submit or symbolicate past releases.", path: xcode + "/Archives", safety: .reviewRequired),
            FolderSpec(group: "Xcode", title: "iOS Device Support", detail: "Debug symbols for connected devices. Copied again when a device connects.", path: xcode + "/iOS DeviceSupport", safety: .safe),
            FolderSpec(group: "Xcode", title: "watchOS Device Support", detail: "Debug symbols for paired watches. Copied again when needed.", path: xcode + "/watchOS DeviceSupport", safety: .safe),
            FolderSpec(group: "Xcode", title: "Documentation Cache", detail: "Downloaded documentation. Downloaded again when opened.", path: xcode + "/DocumentationCache", safety: .safe),
            FolderSpec(group: "Simulators", title: "Simulator Caches", detail: "Cached simulator data. Rebuilt automatically.", path: h + "/Library/Developer/CoreSimulator/Caches", safety: .safe),
            FolderSpec(group: "Package Caches", title: "npm", detail: "Downloaded npm packages. Re-downloaded when needed.", path: h + "/.npm", safety: .safe),
            FolderSpec(group: "Package Caches", title: "pnpm store", detail: "Shared pnpm package store. Re-downloaded when needed.", path: h + "/Library/pnpm/store", safety: .safe),
            FolderSpec(group: "Package Caches", title: "pnpm cache", detail: "pnpm metadata cache.", path: h + "/Library/Caches/pnpm", safety: .safe),
            FolderSpec(group: "Package Caches", title: "Yarn", detail: "Yarn package cache.", path: h + "/Library/Caches/Yarn", safety: .safe),
            FolderSpec(group: "Package Caches", title: "Yarn Berry", detail: "Yarn 2+ global package cache.", path: h + "/.yarn/berry/cache", safety: .safe),
            FolderSpec(group: "Package Caches", title: "Gradle caches", detail: "Downloaded Gradle dependencies and build cache.", path: h + "/.gradle/caches", safety: .safe),
            FolderSpec(group: "Package Caches", title: "Gradle distributions", detail: "Downloaded Gradle versions used by wrappers.", path: h + "/.gradle/wrapper/dists", safety: .safe),
            FolderSpec(group: "Package Caches", title: "Maven repository", detail: "Downloaded Maven dependencies.", path: h + "/.m2/repository", safety: .safe),
            FolderSpec(group: "Package Caches", title: "pip", detail: "Downloaded Python packages.", path: h + "/Library/Caches/pip", safety: .safe),
            FolderSpec(group: "Package Caches", title: "pip (XDG)", detail: "Downloaded Python packages.", path: h + "/.cache/pip", safety: .safe),
            FolderSpec(group: "Package Caches", title: "Poetry", detail: "Poetry package and virtualenv cache.", path: h + "/Library/Caches/pypoetry", safety: .safe),
            FolderSpec(group: "Package Caches", title: "Go build cache", detail: "Compiled Go packages. Rebuilt on the next build.", path: h + "/Library/Caches/go-build", safety: .safe),
            FolderSpec(group: "Package Caches", title: "Go modules", detail: "Downloaded Go modules. Re-downloaded when needed.", path: h + "/go/pkg/mod", safety: .safe),
            FolderSpec(group: "Package Caches", title: "Cargo registry", detail: "Downloaded Rust crates. Re-downloaded when needed.", path: h + "/.cargo/registry", safety: .safe),
            FolderSpec(group: "Package Caches", title: "Cargo git", detail: "Git dependencies fetched by Cargo.", path: h + "/.cargo/git", safety: .safe),
        ]
    }

    private static func folderItems(home: URL) async -> [DevItem] {
        await withTaskGroup(of: DevItem?.self) { group in
            for spec in folderSpecs(home: home) {
                group.addTask {
                    guard FileManager.default.fileExists(atPath: spec.path) else { return nil }
                    let size = StorageScanner.measure(URL(filePath: spec.path)).bytes
                    guard size > 0 else { return nil }
                    return DevItem(id: spec.path, group: spec.group, title: spec.title, detail: spec.detail,
                                   size: size, safety: spec.safety, action: .trash(spec.path))
                }
            }
            var items: [DevItem] = []
            for await item in group {
                if let item { items.append(item) }
            }
            return items
        }
    }

    // MARK: Simulators

    private static func simulatorItems(home: URL) -> [DevItem] {
        var items: [DevItem] = []

        let unavailable = parseUnavailableDevices(run(xcrun, ["simctl", "list", "devices", "unavailable", "-j"]).output)
        if !unavailable.isEmpty {
            let size = unavailable.reduce(Int64(0)) {
                $0 + StorageScanner.measure(home.appending(path: "Library/Developer/CoreSimulator/Devices/\($1)")).bytes
            }
            items.append(DevItem(
                id: "simulators-unavailable", group: "Simulators",
                title: "Unavailable simulators (\(unavailable.count))",
                detail: "Simulator devices whose runtime is no longer installed. They cannot be used.",
                size: size, safety: .safe,
                action: .command(tool: xcrun, invocations: [["simctl", "delete", "unavailable"]])
            ))
        }

        for runtime in parseRuntimes(run(xcrun, ["simctl", "runtime", "list", "-j"]).output) {
            let used = runtime.lastUsed.map { "Last used \($0.formatted(date: .abbreviated, time: .omitted))." } ?? "Never used."
            items.append(DevItem(
                id: "runtime-\(runtime.identifier)", group: "Simulators",
                title: "\(runtime.name) runtime",
                detail: "\(used) Download it again from Xcode → Settings → Components if you need it.",
                size: runtime.sizeBytes, safety: .reviewRequired,
                action: runtime.deletable
                    ? .command(tool: xcrun, invocations: [["simctl", "runtime", "delete", runtime.identifier]])
                    : .none,
                lastUsed: runtime.lastUsed
            ))
        }
        return items
    }

    /// UDIDs from `simctl list devices unavailable -j`.
    static func parseUnavailableDevices(_ json: String) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let devices = root["devices"] as? [String: [[String: Any]]]
        else { return [] }
        return devices.values.flatMap { $0.compactMap { $0["udid"] as? String } }
    }

    /// Runtimes from `simctl runtime list -j`, e.g. "iOS 26.5".
    static func parseRuntimes(_ json: String) -> [SimRuntime] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: Any]] else { return [] }
        return root.values.compactMap { entry in
            guard let identifier = entry["identifier"] as? String else { return nil }
            let platform = (entry["runtimeIdentifier"] as? String)?
                .split(separator: ".").last?
                .split(separator: "-").first
                .map(String.init) ?? "Simulator"
            let version = entry["version"] as? String ?? ""
            return SimRuntime(
                identifier: identifier,
                name: "\(platform) \(version)".trimmingCharacters(in: .whitespaces),
                sizeBytes: (entry["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                lastUsed: (entry["lastUsedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
                deletable: entry["deletable"] as? Bool ?? false
            )
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: Docker

    private static func dockerItems() -> [DevItem] {
        guard let docker = dockerPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return [DevItem(id: "docker-missing", group: "Docker", title: "Docker is not installed",
                            detail: "Nothing to clean.", size: 0, safety: .safe, action: .none)]
        }
        let result = run(docker, ["system", "df", "--format", "{{json .}}"])
        guard result.ok else {
            return [DevItem(id: "docker-stopped", group: "Docker", title: "Docker is not running",
                            detail: "Start Docker Desktop to see its images, containers and build cache.",
                            size: 0, safety: .safe, action: .none)]
        }
        let usage = parseDockerDF(result.output)
        var items: [DevItem] = []
        if let images = usage["Images"], images.reclaimable > 0 {
            items.append(DevItem(id: "docker-images", group: "Docker", title: "Unused images",
                                 detail: "Images no container uses. They are downloaded again when needed.",
                                 size: images.reclaimable, safety: .reviewRequired,
                                 action: .command(tool: docker, invocations: [["image", "prune", "-a", "-f"]])))
        }
        if let containers = usage["Containers"], containers.reclaimable > 0 {
            items.append(DevItem(id: "docker-containers", group: "Docker", title: "Stopped containers",
                                 detail: "Containers that are not running. Anything saved inside them is lost.",
                                 size: containers.reclaimable, safety: .reviewRequired,
                                 action: .command(tool: docker, invocations: [["container", "prune", "-f"]])))
        }
        if let cache = usage["Build Cache"], cache.reclaimable > 0 {
            items.append(DevItem(id: "docker-build-cache", group: "Docker", title: "Build cache",
                                 detail: "Cached image build layers. Rebuilt on the next build.",
                                 size: cache.reclaimable, safety: .safe,
                                 action: .command(tool: docker, invocations: [["builder", "prune", "-a", "-f"]])))
        }
        if let volumes = usage["Local Volumes"], volumes.size > 0 {
            items.append(DevItem(id: "docker-volumes", group: "Docker", title: "Volumes",
                                 detail: "Your container data. CleanMac never removes volumes.",
                                 size: volumes.size, safety: .protected, action: .none))
        }
        return items
    }

    /// `docker system df --format '{{json .}}'` lines → size and reclaimable bytes per type.
    static func parseDockerDF(_ output: String) -> [String: (size: Int64, reclaimable: Int64)] {
        var usage: [String: (size: Int64, reclaimable: Int64)] = [:]
        for line in output.split(separator: "\n") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = row["Type"] as? String else { continue }
            let size = parseDockerSize(row["Size"] as? String ?? "")
            let reclaimable = parseDockerSize((row["Reclaimable"] as? String ?? "").split(separator: " ").first.map(String.init) ?? "")
            usage[type] = (size, reclaimable)
        }
        return usage
    }

    /// Docker's decimal sizes: "1.2GB", "512kB", "0B".
    static func parseDockerSize(_ text: String) -> Int64 {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (unit, factor) in units where text.hasSuffix(unit) {
            return Int64((Double(text.dropLast(unit.count)) ?? 0) * factor)
        }
        return 0
    }

    // MARK: Process

    static func run(_ tool: String, _ arguments: [String]) -> (ok: Bool, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return (false, "", error.localizedDescription) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus == 0,
            String(decoding: data, as: UTF8.self),
            String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

/// Holds the Developer Cleaner results and runs permanent commands.
@MainActor
final class DeveloperStore: ObservableObject {
    @Published private(set) var items: [DevItem]?
    @Published private(set) var scanning = false
    @Published private(set) var runningID: String?
    @Published var lastError: String?

    func refresh(home: URL) {
        guard !scanning else { return }
        scanning = true
        Task {
            items = await DeveloperTools.scan(home: home)
            scanning = false
        }
    }

    /// Runs a permanent clean command, logs it in Cleanup History, then rescans.
    func perform(_ item: DevItem, home: URL, log: @escaping (DevItem) -> Void) {
        guard runningID == nil else { return }
        runningID = item.id
        lastError = nil
        Task {
            let error = await Task.detached { DeveloperTools.perform(item.action) }.value
            runningID = nil
            if let error {
                lastError = "\(item.title): \(error)"
            } else {
                log(item)
            }
            refresh(home: home)
        }
    }
}
