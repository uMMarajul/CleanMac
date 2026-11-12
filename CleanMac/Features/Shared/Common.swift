import AppKit
import SwiftUI

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func revealInFinder(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
}

extension SafetyClassification {
    var title: String {
        switch self {
        case .safe: "Safe"
        case .reviewRequired: "Review"
        case .protected: "Protected"
        }
    }

    var color: Color {
        switch self {
        case .safe: .green
        case .reviewRequired: .orange
        case .protected: .red
        }
    }
}

struct SafetyBadge: View {
    let safety: SafetyClassification

    var body: some View {
        Text(safety.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(safety.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(safety.color.opacity(0.15), in: Capsule())
    }
}

/// Shown by result screens before any scan has run in this session.
struct NeedsScanView: View {
    let navigate: (SidebarSection) -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No scan yet", systemImage: "magnifyingglass")
        } description: {
            Text("Run Smart Scan to measure your storage. Results are kept until you quit CleanMac.")
        } actions: {
            Button("Go to Smart Scan") { navigate(.smartScan) }
        }
    }
}
