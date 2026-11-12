import AppKit
import SwiftUI

struct StartupItemsView: View {
    @EnvironmentObject private var scan: ScanStore

    @State private var items: [LaunchItem]?
    @State private var loginItems: [LoginItemRecord]?
    @State private var loadingLoginItems = false
    @State private var message: String?
    @State private var pending: [ScanItem]?

    var body: some View {
        Group {
            if let items {
                list(items)
            } else {
                ProgressView("Reading startup items…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            Button("Open Login Items Settings") { openLoginItemsSettings() }
            Button("Refresh") { Task { await reload() } }
        }
        .task { await reload() }
        .cleanupFlow(pending: $pending)
        .onChange(of: scan.cleanupVersion) { Task { await afterCleanup() } }
    }

    private func list(_ items: [LaunchItem]) -> some View {
        List {
            if let message {
                Text(message).foregroundStyle(.red).font(.caption)
            }
            ForEach([StartupScope.user, .systemAgent, .systemDaemon], id: \.self) { scope in
                let rows = items.filter { $0.scope == scope }
                Section {
                    if rows.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row($0) }
                } header: {
                    Text(scope.rawValue)
                } footer: {
                    Text(scope == .user
                         ? "Disabling stops the item now and at future logins. You can enable it again anytime."
                         : "These apply to every user. Changing them needs an administrator, so use Login Items Settings.")
                }
            }
            loginItemsSection
        }
    }

    private func row(_ item: LaunchItem) -> some View {
        HStack(spacing: 10) {
            icon(for: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(item))
                Text(item.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let program = item.program {
                    Text(program)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer()
            status(item)
            if item.scope == .user && !item.isEmpty {
                Toggle("", isOn: Binding(
                    get: { item.disabled != true },
                    set: { enabled in setEnabled(item, enabled) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(item.disabled == true ? "Disabled" : "Enabled")
            }
            if item.scope == .user {
                Button("Remove…") {
                    pending = [ScanItem(path: item.path, size: 0, fileCount: 1, modified: nil, isFolder: false, category: nil)]
                }
            }
        }
        .contextMenu {
            Button("Reveal in Finder") { revealInFinder([item.url]) }
        }
    }

    @ViewBuilder
    private func status(_ item: LaunchItem) -> some View {
        if item.isEmpty {
            Text("Empty file, ignored by macOS").font(.caption).foregroundStyle(.orange)
        } else if item.disabled == true {
            Text("Disabled").font(.caption).foregroundStyle(.secondary)
        } else if item.scope == .user {
            Text(item.pid != nil ? "Running" : item.isLoaded ? "Loaded" : "Not loaded")
                .font(.caption)
                .foregroundStyle(item.pid != nil ? .green : .secondary)
        } else {
            Text("Enabled").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var loginItemsSection: some View {
        Section {
            if let loginItems {
                if loginItems.isEmpty {
                    Text("No login items from other developers.").foregroundStyle(.secondary)
                }
                ForEach(loginItems) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name)
                            Text([record.type, record.developer, record.forAllUsers ? "all users" : nil]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let location = record.location {
                                Text(location).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                            }
                        }
                        Spacer()
                        if let enabled = record.enabled {
                            Text(enabled ? "Allowed" : "Off")
                                .font(.caption)
                                .foregroundStyle(enabled ? .green : .secondary)
                        }
                    }
                }
            } else {
                HStack {
                    Text("macOS shows the complete list of login items and background apps only to an administrator.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if loadingLoginItems {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Show All Login Items…") { loadLoginItems() }
                    }
                }
            }
        } header: {
            Text("Login Items & Background Apps")
        } footer: {
            Text("Read-only. Turn these on or off in System Settings → General → Login Items.")
        }
    }

    // MARK: Helpers

    private func icon(for item: LaunchItem) -> some View {
        Group {
            if let app = item.appPath, FileManager.default.fileExists(atPath: app) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable()
            } else {
                Image(systemName: "gearshape.2").foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
    }

    private func displayName(_ item: LaunchItem) -> String {
        guard let app = item.appPath, let bundle = Bundle(path: app) else { return item.label }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? item.label
    }

    private func reload() async {
        let home = scan.home
        items = await Task.detached { StartupItems.load(home: home) }.value
    }

    private func setEnabled(_ item: LaunchItem, _ enabled: Bool) {
        Task {
            message = await Task.detached { StartupItems.setEnabled(item, enabled) }.value
            await reload()
        }
    }

    /// A removed agent's file is in the Trash, but the job may still be loaded: stop it.
    private func afterCleanup() async {
        let removed = (items ?? []).filter { $0.scope == .user && !FileManager.default.fileExists(atPath: $0.path) }
        await Task.detached { removed.forEach { StartupItems.bootout(label: $0.label) } }.value
        await reload()
    }

    private func loadLoginItems() {
        loadingLoginItems = true
        message = nil
        Task {
            let outcome = await Task.detached { () -> Result<String?, Error> in
                Result { try AdminHelper.loginItemsReport() }
            }.value
            loadingLoginItems = false
            switch outcome {
            case .success(let report?): loginItems = StartupItems.parseLoginItems(report)
            case .success(nil): break // cancelled at the password prompt
            case .failure(let error): message = error.localizedDescription
            }
        }
    }

    private func openLoginItemsSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}
