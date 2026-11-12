import AppKit
import Combine

/// Central place for macOS permission state. Phase 1 covers Full Disk Access.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var hasFullDiskAccess: Bool

    private var observer: NSObjectProtocol?

    /// TCC.db opens only with Full Disk Access. Actually opening it (not just checking
    /// readability) also makes macOS list CleanMac under Full Disk Access, switched off,
    /// so the user only has to turn it on.
    private static func probeFullDiskAccess() -> Bool {
        guard let handle = FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db") else {
            return false
        }
        try? handle.close()
        return true
    }

    init() {
        hasFullDiskAccess = Self.probeFullDiskAccess()
        // Re-check whenever the app comes to the front, so the banner clears
        // right after the user grants access in System Settings.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        hasFullDiskAccess = Self.probeFullDiskAccess()
    }

    /// macOS applies a new Full Disk Access grant only to a freshly started process.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        )
    }
}
