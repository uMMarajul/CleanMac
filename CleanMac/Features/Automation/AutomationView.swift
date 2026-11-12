import SwiftUI

struct AutomationView: View {
    @EnvironmentObject private var scheduler: AutomationScheduler
    @EnvironmentObject private var scan: ScanStore
    @EnvironmentObject private var permissions: PermissionManager
    @Environment(\.modelContext) private var context

    @AppStorage(AutomationKeys.scheduleEnabled) private var scheduleEnabled = false
    @AppStorage(AutomationKeys.scanKind) private var scanKind = ScheduledScanKind.quick.rawValue
    @AppStorage(AutomationKeys.frequency) private var frequency = ScheduleFrequency.weekly.rawValue
    @AppStorage(AutomationKeys.hour) private var hour = 10
    @AppStorage(AutomationKeys.autoClean) private var autoClean = false
    @AppStorage(AutomationKeys.autoCleanCategories) private var autoCleanCategories = ""
    @AppStorage(AutomationKeys.lowSpaceAlert) private var lowSpaceAlert = false
    @AppStorage(AutomationKeys.lowSpaceGB) private var lowSpaceGB = 20
    @AppStorage(AutomationKeys.menuBarEnabled) private var menuBarEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Scan automatically", isOn: $scheduleEnabled)
                Picker("Scan", selection: $scanKind) {
                    ForEach(ScheduledScanKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Picker("How often", selection: $frequency) {
                    ForEach(ScheduleFrequency.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Picker("At", selection: $hour) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                LabeledContent("Last run", value: scheduler.lastRun?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                LabeledContent("Next run", value: scheduleEnabled
                               ? scheduler.nextRun?.formatted(date: .abbreviated, time: .shortened) ?? "—"
                               : "Off")
                HStack {
                    Button(scheduler.running ? "Running…" : "Run Now") {
                        Task { await scheduler.runNow(scan: scan, permissions: permissions, context: context) }
                    }
                    .disabled(scheduler.running)
                    if let message = scheduler.lastMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Scheduled scan")
            } footer: {
                Text(menuBarEnabled
                     ? "Runs while CleanMac is open or in the menu bar. A run missed while the Mac was off happens at the next chance."
                     : "Runs only while CleanMac is open. Turn on the menu bar item in Settings so closing the window keeps it running.")
            }

            Section {
                Toggle("Clean automatically after each scheduled scan", isOn: $autoClean)
                ForEach(Schedule.autoCleanable) { category in
                    Toggle(isOn: categoryBinding(category)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.title)
                            Text(category.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!autoClean)
                }
            } header: {
                Text("Automatic cleanup")
            } footer: {
                Text("Only Safe categories can be cleaned automatically. Items go to the Trash, appear in Cleanup History, and caches of running apps are skipped. Review items are never cleaned automatically.")
            }

            Section {
                Toggle("Alert me when free space is low", isOn: $lowSpaceAlert)
                Stepper("When less than \(lowSpaceGB) GB is free", value: $lowSpaceGB, in: 5...500, step: 5)
                    .disabled(!lowSpaceAlert)
            } header: {
                Text("Low disk space")
            } footer: {
                Text("At most one alert a day.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: scheduleEnabled) { _, on in
            if on { enableNotifications() }
            scheduler.scheduleChanged()
        }
        .onChange(of: frequency) { scheduler.scheduleChanged() }
        .onChange(of: hour) { scheduler.scheduleChanged() }
        .onChange(of: lowSpaceAlert) { _, on in if on { enableNotifications() } }
    }

    private func categoryBinding(_ category: StorageCategory) -> Binding<Bool> {
        Binding(
            get: { autoCleanCategories.split(separator: ",").contains { $0 == category.rawValue } },
            set: { on in
                var chosen = Set(autoCleanCategories.split(separator: ",").map(String.init))
                if on { chosen.insert(category.rawValue) } else { chosen.remove(category.rawValue) }
                autoCleanCategories = chosen.sorted().joined(separator: ",")
            }
        )
    }

    /// Asked at the moment it is needed: when the user turns on something that notifies.
    private func enableNotifications() {
        Task { _ = await Notifier.requestPermission() }
    }
}
