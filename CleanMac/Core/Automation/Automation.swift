import AppKit
import Foundation
import SwiftData
import UserNotifications

/// UserDefaults keys shared by the Automation screen (@AppStorage) and the scheduler.
enum AutomationKeys {
    static let scheduleEnabled = "automationScheduleEnabled"
    static let scanKind = "automationScanKind"
    static let frequency = "automationFrequency"
    static let hour = "automationHour"
    static let lastRun = "automationLastRun"
    static let autoClean = "automationAutoClean"
    static let autoCleanCategories = "automationAutoCleanCategories"
    static let lowSpaceAlert = "automationLowSpaceAlert"
    static let lowSpaceGB = "automationLowSpaceGB"
    static let lastLowSpaceAlert = "automationLastLowSpaceAlert"
    static let menuBarEnabled = "menuBarEnabled"
}

enum ScheduledScanKind: String, CaseIterable, Identifiable {
    case quick = "Quick Scan", smart = "Smart Scan"
    var id: String { rawValue }
}

enum ScheduleFrequency: String, CaseIterable, Identifiable {
    case daily = "Daily", weekly = "Weekly", monthly = "Monthly"
    var id: String { rawValue }

    var component: Calendar.Component {
        switch self {
        case .daily: .day
        case .weekly: .weekOfYear
        case .monthly: .month
        }
    }
}

enum Schedule {
    /// One period after `last`, at `hour` o'clock. A run missed while the Mac was off happens at the next check.
    static func nextRun(after last: Date, frequency: ScheduleFrequency, hour: Int, calendar: Calendar = .current) -> Date {
        let day = calendar.date(byAdding: frequency.component, value: 1, to: last) ?? last
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    /// Categories automatic cleanup may use: Safe junk only, never Review items.
    static let autoCleanable = StorageCategory.junk.filter { $0.safety == .safe }.sorted { $0.title < $1.title }
}

enum Notifier {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func send(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Runs scheduled scans, optional Safe-only cleanup and low disk space alerts while CleanMac is running.
@MainActor
final class AutomationScheduler: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var lastMessage: String?

    private var loop: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    var lastRun: Date? {
        let value = defaults.double(forKey: AutomationKeys.lastRun)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    var nextRun: Date? {
        guard defaults.bool(forKey: AutomationKeys.scheduleEnabled), let lastRun else { return nil }
        return Schedule.nextRun(after: lastRun, frequency: frequency, hour: hour)
    }

    private var frequency: ScheduleFrequency {
        ScheduleFrequency(rawValue: defaults.string(forKey: AutomationKeys.frequency) ?? "") ?? .weekly
    }

    private var hour: Int {
        defaults.object(forKey: AutomationKeys.hour) as? Int ?? 10
    }

    /// Starts the background check (every 15 minutes). Safe to call more than once.
    func start(scan: ScanStore, permissions: PermissionManager, context: ModelContext) {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                checkLowSpace()
                if let next = nextRun, Date() >= next {
                    await runNow(scan: scan, permissions: permissions, context: context)
                }
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    /// Marks "now" as the schedule's starting point, so the first run is one period later.
    func scheduleChanged() {
        defaults.set(Date().timeIntervalSince1970, forKey: AutomationKeys.lastRun)
        objectWillChange.send()
    }

    func runNow(scan: ScanStore, permissions: PermissionManager, context: ModelContext) async {
        guard !running else { return }
        running = true
        defer { running = false }

        let kind = ScheduledScanKind(rawValue: defaults.string(forKey: AutomationKeys.scanKind) ?? "") ?? .quick
        guard let junk = await scan.runScheduled(kind, fullDiskAccess: permissions.hasFullDiskAccess) else {
            lastMessage = "Skipped: another scan was running."
            return
        }
        defaults.set(Date().timeIntervalSince1970, forKey: AutomationKeys.lastRun)
        let safeBytes = junk.filter { $0.category.safety == .safe }.reduce(0) { $0 + $1.bytes }
        var message = "\(formatBytes(safeBytes)) of safe junk found."

        if defaults.bool(forKey: AutomationKeys.autoClean) {
            let allowed = Set((defaults.string(forKey: AutomationKeys.autoCleanCategories) ?? "")
                .split(separator: ",").compactMap { StorageCategory(rawValue: String($0)) })
                .intersection(Schedule.autoCleanable)
            let items = junk.filter { allowed.contains($0.category) }.flatMap(\.items)
            if !items.isEmpty {
                let home = scan.home
                let apps = NSWorkspace.shared.runningApplications.compactMap { app in
                    app.bundleIdentifier.map { (bundleID: $0, name: app.localizedName ?? $0) }
                }
                let report = await Task.detached { CleanupEngine.clean(items, home: home, runningApps: apps) }.value
                for entry in report.cleaned {
                    context.insert(CleanupRecord(
                        filePath: entry.trashPath ?? "", originalLocation: entry.item.path, deletedSize: entry.size,
                        operationType: "Automatic cleanup", category: entry.item.category?.rawValue
                    ))
                }
                try? context.save()
                scan.applyCleanup(report.cleaned)
                message += " Moved \(formatBytes(report.freedBytes)) to the Trash."
            }
        }
        lastMessage = message
        Notifier.send("CleanMac \(kind.rawValue) finished", message)
    }

    /// At most one alert a day while free space is under the limit.
    private func checkLowSpace() {
        guard defaults.bool(forKey: AutomationKeys.lowSpaceAlert) else { return }
        let limitGB = defaults.object(forKey: AutomationKeys.lowSpaceGB) as? Int ?? 20
        let free = DiskInfo.current().available
        let lastAlert = defaults.double(forKey: AutomationKeys.lastLowSpaceAlert)
        guard free < Int64(limitGB) * 1_000_000_000, Date().timeIntervalSince1970 - lastAlert > 24 * 3600 else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: AutomationKeys.lastLowSpaceAlert)
        Notifier.send("Low disk space", "Only \(formatBytes(free)) is free. Open CleanMac to find space you can recover.")
    }
}
