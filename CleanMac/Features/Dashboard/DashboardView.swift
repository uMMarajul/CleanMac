import SwiftData
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var scan: ScanStore
    @EnvironmentObject private var monitor: PerformanceMonitor
    @EnvironmentObject private var developer: DeveloperStore
    @Query private var apps: [InstalledApp]
    @AppStorage("usageLongUnusedDays") private var longUnusedDays = 180
    @State private var trashBytes: Int64?
    let navigate: (SidebarSection) -> Void

    private let disk = DiskInfo.current()
    private var result: ScanResult? { scan.result }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !permissions.hasFullDiskAccess { fullDiskBanner }

                storageCard

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], spacing: 16) {
                    statCard(
                        "Junk Found",
                        value: result.map { formatBytes($0.safeBytes) } ?? "—",
                        icon: "trash",
                        note: result == nil ? "Run Smart Scan to find junk" : "Caches, logs and build data marked Safe"
                    )
                    statCard(
                        "Potentially Recoverable",
                        value: result.map { formatBytes($0.recoverableBytes) } ?? "—",
                        icon: "arrow.counterclockwise",
                        note: result.map { "Includes \(formatBytes($0.recoverableReviewBytes)) to review: simulators, archives, old installers" }
                            ?? "Estimated after scanning"
                    )
                    statCard(
                        "System Data (estimate)",
                        value: result.map { formatBytes($0.systemDataEstimate) } ?? "—",
                        icon: "internaldrive",
                        note: "CleanMac's categories, not Apple's exact figure"
                    )
                    statCard("Last Scan", value: lastScanText, icon: "clock", note: lastScanNote)
                    statCard(
                        "CPU",
                        value: monitor.cpuHistory.isEmpty ? "—" : String(format: "%.0f%%", monitor.cpuTotal * 100),
                        icon: "cpu",
                        note: "Average across \(monitor.cpuPerCore.count) cores"
                    )
                    statCard(
                        "Memory",
                        value: monitor.memory.map { "\(formatBytes($0.used)) used" } ?? "—",
                        icon: "memorychip",
                        note: monitor.memory.map { "Pressure: \($0.pressure.rawValue)" } ?? "Measuring…"
                    )
                    if let battery = monitor.battery {
                        statCard(
                            "Battery",
                            value: battery.healthPercent.map { String(format: "%.0f%% health", $0) } ?? "\(battery.charge)%",
                            icon: "battery.75",
                            note: [battery.cycleCount.map { "\($0) cycles" }, battery.condition].compactMap { $0 }.joined(separator: " · ")
                        )
                    }
                }

                recommendationsCard

                smartScanCard
            }
            .padding(24)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .task(id: scan.cleanupVersion) {
            if developer.items == nil { developer.refresh(home: scan.home) }
            let trash = CleanupEngine.trashFolder(home: scan.home)
            trashBytes = await Task.detached { StorageScanner.measure(trash).bytes }.value
        }
    }

    private var recommendations: [Recommendation] {
        let disk = DiskInfo.current()
        return Recommendations.build(Recommendations.Input(
            home: scan.home,
            diskTotal: disk.total,
            diskAvailable: disk.available,
            result: scan.result,
            devItems: developer.items ?? [],
            apps: apps.map { ($0.name, $0.lastOpenedDate, $0.totalSize, $0.isProtected) },
            longUnusedDays: longUnusedDays,
            trashBytes: trashBytes,
            pressure: monitor.memory?.pressure
        ))
    }

    private var recommendationsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if recommendations.isEmpty {
                    Text(scan.result == nil
                         ? "Run Smart Scan to get recommendations."
                         : "Nothing urgent. Your Mac looks tidy.")
                        .foregroundStyle(.secondary)
                }
                ForEach(recommendations) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.icon)
                            .frame(width: 24)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Review") { navigate(item.target) }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Recommendations", systemImage: "lightbulb")
        }
    }

    // MARK: Cards

    private var storageCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Macintosh HD", systemImage: "internaldrive.fill")
                        .font(.headline)
                    Spacer()
                    Text("\(formatBytes(disk.available)) available of \(formatBytes(disk.total))")
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: disk.usedFraction)
                    .progressViewStyle(.linear)
                HStack {
                    Text("Used: \(formatBytes(disk.used))")
                    Spacer()
                    Text("Free space includes purgeable storage, matching Finder.")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private func statCard(_ title: String, value: String, icon: String, note: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title2.weight(.semibold))
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var smartScanCard: some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Smart Scan")
                        .font(.headline)
                    Text("Analyze your storage, find junk, and estimate recoverable space. Nothing is deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(scan.phase == .scanning ? "Scanning…" : result == nil ? "Smart Scan" : "Scan Again") {
                    if scan.phase == .idle {
                        scan.start(fullDiskAccess: permissions.hasFullDiskAccess)
                    }
                    navigate(.smartScan)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(8)
        }
    }

    private var fullDiskBanner: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Full Disk Access needed")
                        .font(.headline)
                    Text("CleanMac needs Full Disk Access to analyze your storage. Turn on CleanMac in System Settings, then relaunch CleanMac so macOS applies it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Settings") { permissions.openFullDiskAccessSettings() }
                Button("Relaunch") { permissions.relaunch() }
            }
            .padding(8)
        }
    }

    // MARK: Helpers

    private var lastScanText: String {
        guard let result else { return "Never" }
        return result.scannedAt.formatted(.relative(presentation: .named))
    }

    private var lastScanNote: String {
        guard let result else { return "No scans yet" }
        return "Measured \(formatBytes(result.totalBytes))"
    }
}
