import ServiceManagement
import SwiftData
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var scan: ScanStore
    @Environment(\.modelContext) private var context

    @AppStorage(AutomationKeys.menuBarEnabled) private var menuBarEnabled = true
    @AppStorage("largeFileThreshold") private var largeFileThreshold = 100_000_000
    @AppStorage("usageRecentDays") private var recentDays = 30
    @AppStorage("usageOccasionalDays") private var occasionalDays = 90
    @AppStorage("usageLongUnusedDays") private var longUnusedDays = 180

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemMessage: String?
    @State private var notificationsAllowed: Bool?
    @State private var confirmClearScan = false
    @State private var confirmClearHistory = false

    var body: some View {
        Form {
            Section {
                permissionRow(
                    "Full Disk Access",
                    granted: permissions.hasFullDiskAccess,
                    detail: "Needed to read protected folders such as Mail, Messages, Desktop and app containers."
                ) {
                    Button("Open Settings") { permissions.openFullDiskAccessSettings() }
                }
                permissionRow(
                    "Notifications",
                    granted: notificationsAllowed,
                    detail: "Used for scheduled scan results and low disk space alerts."
                ) {
                    Button("Allow") {
                        Task {
                            _ = await Notifier.requestPermission()
                            await refreshNotifications()
                        }
                    }
                }
                permissionRow(
                    "Administrator password",
                    granted: nil,
                    detail: "Asked only when needed: measuring folders owned by macOS, reading all login items, or removing apps owned by the system. CleanMac never sees the password."
                ) { EmptyView() }
            } header: {
                Text("Permissions")
            }

            Section("General") {
                Toggle("Open CleanMac at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginItemMessage {
                    Text(loginItemMessage).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Show CleanMac in the menu bar", isOn: $menuBarEnabled)
                Text("With the menu bar item on, closing the window keeps CleanMac running so schedules and alerts keep working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Large files start at", selection: $largeFileThreshold) {
                    Text("50 MB").tag(50_000_000)
                    Text("100 MB").tag(100_000_000)
                    Text("500 MB").tag(500_000_000)
                    Text("1 GB").tag(1_000_000_000)
                }
            }

            Section("App usage") {
                Stepper("Recently used: within \(recentDays) days", value: $recentDays, in: 1...365)
                Stepper("Occasionally used: within \(occasionalDays) days", value: $occasionalDays, in: recentDays...730)
                Stepper("Long unused: over \(longUnusedDays) days", value: $longUnusedDays, in: occasionalDays...1095)
            }

            Section("Data") {
                LabeledContent("Saved scan") {
                    Button("Delete Saved Scan…") { confirmClearScan = true }
                        .disabled(scan.result == nil)
                }
                LabeledContent("Cleanup History") {
                    Button("Clear History…") { confirmClearHistory = true }
                }
                Text("Clearing history removes only the records. Items already in the Trash stay there, but can no longer be put back from CleanMac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refreshNotifications() }
        .confirmationDialog("Delete the saved scan?", isPresented: $confirmClearScan, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { scan.clearSaved() }
        } message: {
            Text("Results disappear until you scan again. No files are touched.")
        }
        .confirmationDialog("Clear Cleanup History?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                try? context.delete(model: CleanupRecord.self)
                try? context.save()
            }
        }
    }

    private func permissionRow(_ title: String, granted: Bool?, detail: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .top) {
            Image(systemName: granted == nil ? "key" : granted! ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted == nil ? Color.secondary : granted! ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted == false { action() }
            if granted == true { Text("Allowed").foregroundStyle(.secondary) }
        }
    }

    private func refreshNotifications() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsAllowed = status == .authorized || status == .provisional
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemMessage = SMAppService.mainApp.status == .requiresApproval
                ? "Approve CleanMac in System Settings → General → Login Items."
                : nil
        } catch {
            loginItemMessage = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
