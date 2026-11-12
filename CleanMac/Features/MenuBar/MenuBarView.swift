import AppKit
import SwiftUI

/// The menu bar panel: free space, live load, junk found, and quick actions.
struct MenuBarView: View {
    @EnvironmentObject private var scan: ScanStore
    @EnvironmentObject private var monitor: PerformanceMonitor
    @EnvironmentObject private var permissions: PermissionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("CleanMac", systemImage: "sparkles").font(.headline)
            Divider()
            row("Free space", formatBytes(DiskInfo.current().available))
            row("CPU", monitor.cpuHistory.isEmpty ? "—" : String(format: "%.0f%%", monitor.cpuTotal * 100))
            row("Memory pressure", monitor.memory?.pressure.rawValue ?? "—")
            row("Safe junk found", junkText)
            Divider()
            Button {
                scan.startQuickScan(fullDiskAccess: permissions.hasFullDiskAccess)
            } label: {
                Label(scan.quickScanning ? "Scanning…" : "Quick Scan", systemImage: "magnifyingglass")
            }
            .disabled(scan.quickScanning || scan.phase == .scanning)
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open CleanMac", systemImage: "macwindow")
            }
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit CleanMac", systemImage: "power")
            }
        }
        .buttonStyle(.borderless)
        .padding()
        .frame(width: 260)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private var junkText: String {
        if let quick = scan.quickJunk {
            return formatBytes(quick.filter { $0.category.safety == .safe }.reduce(0) { $0 + $1.bytes })
        }
        return scan.result.map { formatBytes($0.safeBytes) } ?? "Not scanned"
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
