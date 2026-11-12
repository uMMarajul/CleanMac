import AppKit
import SwiftData
import SwiftUI

/// Confirm → clean through `CleanupEngine` → log → update lists → report.
/// Every screen that removes files uses this, so the flow is identical everywhere.
private struct CleanupFlow: ViewModifier {
    @Binding var pending: [ScanItem]?
    /// Replaces the standard confirmation text, e.g. to ask consent for personal data.
    var explanation: String?
    @EnvironmentObject private var scan: ScanStore
    @Environment(\.modelContext) private var context
    @State private var report: CleanupReport?
    @State private var running = false

    func body(content: Content) -> some View {
        let items = pending ?? []
        let total = items.reduce(0) { $0 + $1.size }
        let needsReview = items.contains { $0.category?.safety != .safe }

        content
            .confirmationDialog(
                "Move \(items.count) item\(items.count == 1 ? "" : "s") (\(formatBytes(total))) to the Trash?",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) { run(items) }
            } message: {
                Text(explanation ?? (needsReview
                     ? "Some items need review. Make sure you no longer need them. You can put everything back from Cleanup History."
                     : "You can put them back from Cleanup History."))
            }
            .sheet(isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
                if let report {
                    CleanupReportView(report: report) { self.report = nil }
                }
            }
            .overlay {
                if running {
                    ProgressView("Moving to Trash…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
    }

    private func run(_ items: [ScanItem]) {
        guard !items.isEmpty else { return }
        running = true
        let home = scan.home
        let apps = NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map { (bundleID: $0, name: app.localizedName ?? $0) }
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                CleanupEngine.clean(items, home: home, runningApps: apps)
            }.value
            for entry in result.cleaned {
                context.insert(CleanupRecord(
                    filePath: entry.trashPath ?? "",
                    originalLocation: entry.item.path,
                    deletedSize: entry.size,
                    operationType: "Moved to Trash",
                    category: entry.item.category?.rawValue
                ))
            }
            try? context.save()
            scan.applyCleanup(result.cleaned)
            running = false
            report = result
        }
    }
}

extension View {
    /// Set `pending` to start a cleanup of those items.
    func cleanupFlow(pending: Binding<[ScanItem]?>, explanation: String? = nil) -> some View {
        modifier(CleanupFlow(pending: pending, explanation: explanation))
    }
}

struct CleanupReportView: View {
    let report: CleanupReport
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                report.cleaned.isEmpty
                    ? "Nothing was moved"
                    : "Moved \(report.cleaned.count) item\(report.cleaned.count == 1 ? "" : "s") to the Trash",
                systemImage: report.cleaned.isEmpty ? "exclamationmark.triangle" : "checkmark.circle.fill"
            )
            .font(.title2.bold())

            if !report.cleaned.isEmpty {
                Text("\(formatBytes(report.freedBytes)) is in the Trash. The space is freed when the Trash is emptied, and you can put items back from Cleanup History.")
                    .foregroundStyle(.secondary)
            }

            if !report.skipped.isEmpty {
                Text("Skipped \(report.skipped.count)")
                    .font(.headline)
                List(report.skipped, id: \.item.path) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.item.name)
                        Text(entry.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 100, maxHeight: 240)
            }

            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
