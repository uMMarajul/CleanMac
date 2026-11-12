import SwiftUI

struct SmartScanView: View {
    @EnvironmentObject private var scan: ScanStore
    @EnvironmentObject private var permissions: PermissionManager
    let navigate: (SidebarSection) -> Void

    var body: some View {
        VStack(spacing: 18) {
            if scan.phase == .scanning {
                scanning
            } else if let result = scan.result {
                summary(result)
            } else {
                start
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var start: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Smart Scan")
                .font(.largeTitle.bold())
            Text("Measures what is using your storage and finds caches and other data you may not need. Nothing is changed or deleted.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            if !permissions.hasFullDiskAccess {
                Text("Without Full Disk Access, protected folders (Desktop, Documents, Mail, app containers…) are skipped and listed as inaccessible.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 460)
            }
            startButton("Start Scan")
        }
    }

    private var scanning: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Scanning… \(scan.itemsScanned.formatted()) items")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(scan.currentPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 560)
            Button("Cancel") { scan.cancel() }
        }
    }

    private func summary(_ result: ScanResult) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Scan complete")
                .font(.largeTitle.bold())
            Text("Measured \(formatBytes(result.totalBytes)) in \(duration(result.duration)) · \(result.scannedAt.formatted(date: .abbreviated, time: .shortened))")
                .foregroundStyle(.secondary)

            Grid(horizontalSpacing: 32, verticalSpacing: 10) {
                GridRow {
                    stat("Safe to clean", formatBytes(result.safeBytes), .green)
                    stat("Needs review", formatBytes(result.reviewBytes), .orange)
                    stat("System Data (estimate)", formatBytes(result.systemDataEstimate), .primary)
                    stat("Inaccessible folders", result.inaccessible.count.formatted(), .secondary)
                }
            }
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Button("View System Data") { navigate(.systemData) }
                    .buttonStyle(.borderedProminent)
                Button("Explore Storage") { navigate(.storageExplorer) }
                Button("Large Files") { navigate(.largeFiles) }
            }
            startButton("Scan Again")
            Text("Scanning again replaces these results once the new scan finishes.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func startButton(_ title: String) -> some View {
        Button(title) {
            scan.start(fullDiskAccess: permissions.hasFullDiskAccess)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }
}
