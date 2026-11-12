import AppKit
import SwiftUI

struct PrivacyView: View {
    @EnvironmentObject private var scan: ScanStore
    @EnvironmentObject private var permissions: PermissionManager
    let navigate: (SidebarSection) -> Void

    @State private var browsers: [BrowserData]?
    @State private var grants: [PermissionGrant]?
    @State private var pending: [ScanItem]?
    @State private var consent: String?

    var body: some View {
        Group {
            if let browsers {
                List {
                    browsersSection(browsers)
                    permissionsSection
                    Section("Login & Background Items") {
                        HStack {
                            Text("See and turn off apps that start automatically.")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Startup Items") { navigate(.startupItems) }
                        }
                    }
                }
            } else {
                ProgressView("Reading browser data and permissions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            Button("Export Report…") { exportReport() }
                .disabled(browsers == nil)
            Button("Refresh") { Task { await load() } }
        }
        .task { await load() }
        .onChange(of: scan.cleanupVersion) { Task { await load() } }
        .cleanupFlow(pending: $pending, explanation: consent)
    }

    // MARK: Browsers

    private func browsersSection(_ browsers: [BrowserData]) -> some View {
        Section {
            if browsers.isEmpty {
                Text("No browsers found.").foregroundStyle(.secondary)
            }
            ForEach(browsers) { browser in
                browserRow(browser)
            }
        } header: {
            Text("Browsers")
        } footer: {
            Text("The browser must be quit first. Everything goes to the Trash. Clearing history or cookies needs your confirmation each time; clearing cookies signs you out of websites.")
        }
    }

    private func browserRow(_ browser: BrowserData) -> some View {
        let runningName = NSRunningApplication.runningApplications(withBundleIdentifier: browser.spec.bundleID).first?.localizedName
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.spec.bundleID) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 28, height: 28)
                } else {
                    Image(systemName: "globe").frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(browser.spec.name).font(.headline)
                    Text("\(browser.profiles) profile\(browser.profiles == 1 ? "" : "s")\(runningName != nil ? " · Running: quit it to clear data" : "")")
                        .font(.caption)
                        .foregroundStyle(runningName != nil ? .orange : .secondary)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                dataButton("Cache", browser.cacheBytes, enabled: !browser.cache.isEmpty && runningName == nil) {
                    clear(browser.cache, consent: nil)
                }
                if let note = browser.historyNote {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("History").font(.caption).foregroundStyle(.secondary)
                        Text("Clear in Firefox").font(.caption)
                    }
                    .help(note)
                } else {
                    dataButton("History", browser.historyBytes, enabled: !browser.history.isEmpty && runningName == nil) {
                        clear(browser.history, consent: "This deletes \(browser.spec.name)'s browsing history for every profile. If the browser syncs history (for example through iCloud), it may come back from other devices.")
                    }
                }
                dataButton("Cookies", browser.cookieBytes, enabled: !browser.cookies.isEmpty && runningName == nil) {
                    clear(browser.cookies, consent: "This deletes \(browser.spec.name)'s cookies for every profile. You will be signed out of websites.")
                }
            }
            if !browser.extensions.isEmpty {
                DisclosureGroup("\(browser.extensions.count) extension\(browser.extensions.count == 1 ? "" : "s")") {
                    ForEach(browser.extensions, id: \.self) { Text($0).font(.callout) }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func dataButton(_ title: String, _ bytes: Int64, enabled: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(formatBytes(bytes)).monospacedDigit()
                Button("Clear…", action: action)
                    .controlSize(.small)
                    .disabled(!enabled || bytes == 0)
            }
        }
    }

    private func clear(_ paths: [String], consent: String?) {
        self.consent = consent
        pending = paths.map {
            ScanItem(path: $0, size: StorageScanner.measure(URL(filePath: $0)).bytes, fileCount: 1, modified: nil,
                     isFolder: false, category: StorageCategory.category(forPath: $0, home: scan.home))
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        Section {
            if let grants {
                ForEach(AppPermissions.services) { service in
                    let rows = grants.filter { $0.service == service.key }.sorted { name($0.client) < name($1.client) }
                    if !rows.isEmpty {
                        DisclosureGroup {
                            ForEach(rows) { grant in
                                HStack {
                                    Text(name(grant.client))
                                    Spacer()
                                    Text(grant.allowed ? "Allowed" : "Denied")
                                        .font(.caption)
                                        .foregroundStyle(grant.allowed ? .green : .secondary)
                                }
                            }
                            Button("Change in System Settings") { NSWorkspace.shared.open(service.settingsURL) }
                        } label: {
                            Label("\(service.title): \(rows.filter(\.allowed).count) allowed", systemImage: service.icon)
                        }
                    }
                }
            } else {
                HStack {
                    Text("Reading app permissions needs Full Disk Access.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings") { permissions.openFullDiskAccessSettings() }
                }
            }
        } header: {
            Text("App Permissions")
        } footer: {
            Text("Read-only. Permissions can only be changed in System Settings → Privacy & Security.")
        }
    }

    // MARK: Helpers

    /// Bundle identifier or path → app name.
    private func name(_ client: String) -> String {
        if client.hasPrefix("/") { return URL(filePath: client).lastPathComponent }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: client) else { return client }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func load() async {
        let home = scan.home
        async let browserData = Task.detached {
            BrowserInspector.inspect(
                home: home,
                isInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
                safariExtensions: BrowserInspector.safariExtensions
            )
        }.value
        async let permissionData = Task.detached { AppPermissions.read(databases: AppPermissions.databases(home: home)) }.value
        browsers = await browserData
        grants = await permissionData
    }

    private func exportReport() {
        var lines = ["CleanMac Privacy Report", Date().formatted(date: .long, time: .shortened), ""]
        lines.append("BROWSERS")
        for browser in browsers ?? [] {
            lines.append("- \(browser.spec.name): cache \(formatBytes(browser.cacheBytes)), history \(formatBytes(browser.historyBytes)), cookies \(formatBytes(browser.cookieBytes)), \(browser.extensions.count) extensions")
            browser.extensions.forEach { lines.append("    · \($0)") }
        }
        lines.append("")
        lines.append("APP PERMISSIONS")
        if let grants {
            for service in AppPermissions.services {
                let allowed = grants.filter { $0.service == service.key && $0.allowed }.map { name($0.client) }.sorted()
                if !allowed.isEmpty { lines.append("- \(service.title): \(allowed.joined(separator: ", "))") }
            }
        } else {
            lines.append("- Not available without Full Disk Access")
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CleanMac Privacy Report.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
