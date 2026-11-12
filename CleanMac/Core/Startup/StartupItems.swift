import Foundation

enum StartupScope: String {
    case user = "Your launch agents"
    case systemAgent = "Launch agents for all users"
    case systemDaemon = "Background daemons"
}

/// A launchd job that starts automatically.
struct LaunchItem: Identifiable, Hashable {
    let path: String
    let label: String
    let program: String?
    let scope: StartupScope
    /// The app the program lives in, if any.
    let appPath: String?
    var disabled: Bool?
    /// Process ID when running now. Known only for your own agents.
    var pid: Int?
    var isLoaded = false
    /// The file has no job definition (e.g. an emptied updater file). macOS ignores it.
    var isEmpty = false

    var id: String { path }
    var url: URL { URL(filePath: path) }
}

/// An entry from macOS's Login Items and background items list (`sfltool dumpbtm`).
struct LoginItemRecord: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let type: String
    let developer: String?
    let enabled: Bool?
    let location: String?
    let bundleID: String?
    let forAllUsers: Bool
}

enum StartupItems {
    static var uid: uid_t { getuid() }

    static func folders(home: URL) -> [(URL, StartupScope)] {
        [
            (home.appending(path: "Library/LaunchAgents"), .user),
            (URL(filePath: "/Library/LaunchAgents"), .systemAgent),
            (URL(filePath: "/Library/LaunchDaemons"), .systemDaemon),
        ]
    }

    static func load(home: URL) -> [LaunchItem] {
        let userDisabled = parseDisabled(DeveloperTools.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"]).output)
        let systemDisabled = parseDisabled(DeveloperTools.run("/bin/launchctl", ["print-disabled", "system"]).output)
        let running = parseList(DeveloperTools.run("/bin/launchctl", ["list"]).output)

        return folders(home: home).flatMap { folder, scope in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "plist" }.compactMap { file -> LaunchItem? in
                guard var item = parse(plistAt: file, scope: scope) else { return nil }
                item.disabled = (scope == .user ? userDisabled : systemDisabled)[item.label]
                if scope == .user, let entry = running[item.label] {
                    item.isLoaded = true
                    item.pid = entry
                }
                return item
            }
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    static func parse(plistAt url: URL, scope: StartupScope) -> LaunchItem? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        guard let label = plist["Label"] as? String else {
            // Listed so the leftover file can be removed; named after the file.
            return LaunchItem(path: url.path, label: url.deletingPathExtension().lastPathComponent, program: nil,
                              scope: scope, appPath: nil, isEmpty: true)
        }
        let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
        return LaunchItem(path: url.path, label: label, program: program, scope: scope, appPath: program.flatMap(appPath))
    }

    /// "/Applications/Foo.app/Contents/MacOS/foo" → "/Applications/Foo.app".
    static func appPath(forProgram program: String) -> String? {
        guard let range = program.range(of: ".app/") else { return nil }
        return String(program[..<range.lowerBound]) + ".app"
    }

    /// `launchctl print-disabled` lines: "label" => disabled|enabled.
    static func parseDisabled(_ output: String) -> [String: Bool] {
        var states: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            states[label] = parts[1].trimmingCharacters(in: .whitespaces).hasPrefix("disabled")
        }
        return states
    }

    /// `launchctl list` lines: "PID<tab>Status<tab>Label"; PID is "-" when loaded but not running.
    static func parseList(_ output: String) -> [String: Int?] {
        var jobs: [String: Int?] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t")
            guard columns.count == 3 else { continue }
            jobs[String(columns[2])] = Int(columns[0])
        }
        return jobs
    }

    /// Enables or disables one of your own agents, now and at future logins. Returns an error message.
    static func setEnabled(_ item: LaunchItem, _ enabled: Bool) -> String? {
        guard item.scope == .user else { return "Only your own launch agents can be changed here." }
        let domain = "gui/\(uid)"
        if enabled {
            let result = DeveloperTools.run("/bin/launchctl", ["enable", "\(domain)/\(item.label)"])
            guard result.ok else { return result.error }
            // Fails harmlessly when the job is already loaded.
            _ = DeveloperTools.run("/bin/launchctl", ["bootstrap", domain, item.path])
        } else {
            let result = DeveloperTools.run("/bin/launchctl", ["disable", "\(domain)/\(item.label)"])
            guard result.ok else { return result.error }
            bootout(label: item.label)
        }
        return nil
    }

    /// Stops one of your own agents now (e.g. after its file was removed).
    static func bootout(label: String) {
        _ = DeveloperTools.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
    }

    /// Parses `sfltool dumpbtm`. Apple's own items are left out.
    static func parseLoginItems(_ report: String) -> [LoginItemRecord] {
        var records: [LoginItemRecord] = []
        var fields: [String: String] = [:]
        var forAllUsers = false
        var currentForAllUsers = false

        func flush() {
            defer { fields = [:] }
            guard let name = fields["Name"], !name.isEmpty else { return }
            let developer = fields["Developer Name"]
            let bundleID = fields["Bundle Identifier"]
            if developer?.hasPrefix("Apple") == true || bundleID?.hasPrefix("com.apple.") == true { return }
            let disposition = fields["Disposition"] ?? ""
            records.append(LoginItemRecord(
                name: name,
                type: (fields["Type"] ?? "").components(separatedBy: " (").first ?? "",
                developer: developer,
                enabled: disposition.isEmpty ? nil : (disposition.contains("enabled") && !disposition.contains("disabled")),
                location: (fields["Executable Path"] ?? fields["URL"]).map { $0.replacingOccurrences(of: "file://", with: "") },
                bundleID: bundleID,
                forAllUsers: currentForAllUsers
            ))
        }

        for rawLine in report.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID") {
                flush()
                forAllUsers = line.contains("UID 0 ") || line.contains("UID -2 ")
                continue
            }
            if line.hasPrefix("#"), line.hasSuffix(":"), Int(line.dropFirst().dropLast()) != nil {
                flush()
                currentForAllUsers = forAllUsers
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }
        flush()
        return records
    }
}
