import AppKit
import SwiftData
import SwiftUI
import UserNotifications

@main
struct CleanMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var permissions = PermissionManager()
    @StateObject private var scanStore = ScanStore()
    @StateObject private var appsStore = AppsStore()
    @StateObject private var developerStore = DeveloperStore()
    @StateObject private var duplicateStore = DuplicateStore()
    @StateObject private var performance = PerformanceMonitor()
    @StateObject private var scheduler = AutomationScheduler()
    @AppStorage(AutomationKeys.menuBarEnabled) private var menuBarEnabled = true

    /// One store shared by the window and the menu bar.
    private let container: ModelContainer = {
        do {
            return try ModelContainer(for: ScannedFile.self, InstalledApp.self, CleanupRecord.self, ScanSession.self)
        } catch {
            fatalError("Could not open CleanMac's database: \(error)")
        }
    }()

    var body: some Scene {
        // A single window: reopening it from the menu bar brings back the same window.
        Window("CleanMac", id: "main") {
            MainView()
                .withStores(self)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    scheduler.start(scan: scanStore, permissions: permissions, context: container.mainContext)
                }
        }
        .modelContainer(container)

        MenuBarExtra("CleanMac", systemImage: "sparkles", isInserted: $menuBarEnabled) {
            MenuBarView()
                .withStores(self)
        }
        .menuBarExtraStyle(.window)
        .modelContainer(container)
    }

    fileprivate func inject<V: View>(_ view: V) -> some View {
        view
            .environmentObject(permissions)
            .environmentObject(scanStore)
            .environmentObject(appsStore)
            .environmentObject(developerStore)
            .environmentObject(duplicateStore)
            .environmentObject(performance)
            .environmentObject(scheduler)
    }
}

private extension View {
    func withStores(_ app: CleanMacApp) -> some View {
        app.inject(self)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    /// With the menu bar item on, closing the window keeps CleanMac running for schedules and alerts.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: AutomationKeys.menuBarEnabled) as? Bool ?? true)
    }

    /// Show notifications even while CleanMac is in front.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
