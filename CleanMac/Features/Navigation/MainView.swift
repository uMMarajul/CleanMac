import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard, smartScan, systemData, junkCleaner, cleanupHistory, storageExplorer
    case duplicateFinder, largeFiles, applications, developerCleaner
    case performance, startupItems, privacy, automation, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .smartScan: "Smart Scan"
        case .systemData: "System Data"
        case .junkCleaner: "Junk Cleaner"
        case .cleanupHistory: "Cleanup History"
        case .storageExplorer: "Storage Explorer"
        case .duplicateFinder: "Duplicate Finder"
        case .largeFiles: "Large Files"
        case .applications: "Applications"
        case .developerCleaner: "Developer Cleaner"
        case .performance: "Performance"
        case .startupItems: "Startup Items"
        case .privacy: "Privacy"
        case .automation: "Automation"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.medium"
        case .smartScan: "sparkles.rectangle.stack"
        case .systemData: "internaldrive"
        case .junkCleaner: "trash"
        case .cleanupHistory: "arrow.uturn.backward.circle"
        case .storageExplorer: "folder"
        case .duplicateFinder: "doc.on.doc"
        case .largeFiles: "doc.badge.ellipsis"
        case .applications: "square.grid.2x2"
        case .developerCleaner: "hammer"
        case .performance: "speedometer"
        case .startupItems: "power"
        case .privacy: "hand.raised"
        case .automation: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }

    /// Development phase that delivers this section (shown on stubs).
    var plannedPhase: String {
        switch self {
        case .dashboard: "Phase 1"
        case .systemData, .storageExplorer, .largeFiles, .smartScan: "Phase 2"
        case .junkCleaner, .cleanupHistory: "Phase 3"
        case .applications: "Phase 4"
        case .duplicateFinder, .developerCleaner, .performance, .startupItems: "Phase 5"
        case .privacy, .automation, .settings: "Phase 6"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var scan: ScanStore
    @EnvironmentObject private var permissions: PermissionManager
    @State private var selection: SidebarSection? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            let section = selection ?? .dashboard
            Group {
                switch section {
                case .dashboard: DashboardView(navigate: go)
                case .smartScan: SmartScanView(navigate: go)
                case .systemData: SystemDataView(navigate: go)
                case .junkCleaner: JunkCleanerView(navigate: go)
                case .cleanupHistory: CleanupHistoryView()
                case .applications: ApplicationsView()
                case .developerCleaner: DeveloperCleanerView()
                case .duplicateFinder: DuplicateFinderView()
                case .performance: PerformanceView()
                case .startupItems: StartupItemsView()
                case .privacy: PrivacyView(navigate: go)
                case .automation: AutomationView()
                case .settings: SettingsView()
                case .storageExplorer: StorageExplorerView(navigate: go)
                case .largeFiles: LargeFilesView(navigate: go)
                default: ComingSoonView(section: section)
                }
            }
            .navigationTitle(section.title)
        }
        // Permissions are asked for at the moment they are needed.
        .alert("Scan without Full Disk Access?", isPresented: $scan.askFullDiskAccess) {
            Button("Open Settings") { permissions.openFullDiskAccessSettings() }
            Button("Scan Without It") { scan.startWithoutFullDiskAccess() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Without it, protected folders such as Desktop, Documents and Mail are skipped. Turn on CleanMac in Full Disk Access, then relaunch CleanMac for a complete scan.")
        }
        .alert(
            "Measure \(scan.result?.systemOwned?.count ?? 0) folders owned by macOS?",
            isPresented: $scan.askAdministrator
        ) {
            Button("Measure…") { scan.measureSystemFolders() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Only an administrator can read these folders. macOS will ask for your password. CleanMac only reads their sizes and never changes them.")
        }
        .task {
            if ScreenshotMode.demoFolder != nil {
                await recordDemo()
            } else if ScreenshotMode.isActive {
                await takeScreenshots()
            }
        }
    }

    private func go(_ section: SidebarSection) {
        selection = section
    }

    /// Demo GIF frames (see `ScreenshotMode`): a tour of the main screens, then quits.
    /// Each screen gets a moment to load before recording starts, so the demo shows no spinners.
    private func recordDemo() async {
        await ScreenshotMode.wait(until: { ScreenshotMode.mainWindow() != nil }, timeout: 10)
        guard let window = ScreenshotMode.mainWindow() else { return NSApp.terminate(nil) }
        window.setContentSize(NSSize(width: 1200, height: 780))
        window.center()
        scan.startQuickScan(fullDiskAccess: permissions.hasFullDiskAccess) // ready by the Junk Cleaner step

        func show(_ section: SidebarSection, load: Double = 1.5, record seconds: Double) async {
            selection = section
            await ScreenshotMode.wait(load)
            await ScreenshotMode.record(window, seconds: seconds)
        }

        await show(.dashboard, load: 6, record: 3.5)
        await show(.systemData, record: 3)
        selection = .junkCleaner
        await ScreenshotMode.wait(until: { !scan.quickScanning }, timeout: 180)
        await show(.junkCleaner, load: 1, record: 2.5)
        await show(.applications, record: 1.5)
        NotificationCenter.default.post(name: ScreenshotMode.detailNotification, object: nil)
        await ScreenshotMode.wait(3)
        await ScreenshotMode.record(window, seconds: 3.5)
        NotificationCenter.default.post(name: ScreenshotMode.detailNotification, object: nil) // closes it
        await ScreenshotMode.wait(1)
        await show(.developerCleaner, load: 2, record: 2.5)
        await show(.performance, load: 4, record: 4)
        await show(.startupItems, load: 2, record: 2.5)
        await show(.privacy, load: 6, record: 3)
        await show(.automation, record: 2)
        await show(.dashboard, load: 1, record: 1.5)
        NSApp.terminate(nil)
    }

    /// README screenshots (see `ScreenshotMode`): visits each screen, captures the window, quits.
    private func takeScreenshots() async {
        await ScreenshotMode.wait(until: { ScreenshotMode.mainWindow() != nil }, timeout: 10)
        guard let window = ScreenshotMode.mainWindow() else { return NSApp.terminate(nil) }
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.center()

        let screens: [(SidebarSection, String, Double)] = [
            (.dashboard, "dashboard", 6),
            (.systemData, "system-data", 3),
            (.developerCleaner, "developer-cleaner", 4),
            (.performance, "performance", 7),
            (.privacy, "privacy", 8),
        ]
        for (section, name, delay) in screens {
            selection = section
            await ScreenshotMode.wait(delay)
            ScreenshotMode.capture(window, name: name)
        }

        selection = .junkCleaner
        scan.startQuickScan(fullDiskAccess: permissions.hasFullDiskAccess)
        await ScreenshotMode.wait(1)
        await ScreenshotMode.wait(until: { !scan.quickScanning }, timeout: 180)
        await ScreenshotMode.wait(2)
        ScreenshotMode.capture(window, name: "junk-cleaner")

        selection = .applications
        await ScreenshotMode.wait(3)
        NotificationCenter.default.post(name: ScreenshotMode.detailNotification, object: nil)
        await ScreenshotMode.wait(6)
        if let sheet = window.attachedSheet {
            ScreenshotMode.capture(sheet, name: "app-details")
        }
        NSApp.terminate(nil)
    }
}

struct ComingSoonView: View {
    let section: SidebarSection

    var body: some View {
        ContentUnavailableView(
            section.title,
            systemImage: section.icon,
            description: Text("Coming in \(section.plannedPhase).")
        )
    }
}
