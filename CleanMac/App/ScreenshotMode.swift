import AppKit

/// Developer tool for the README: `CleanMac.app/Contents/MacOS/CleanMac --screenshots <folder>`
/// visits each screen, saves a PNG of CleanMac's own window, then quits.
/// Capturing its own windows needs no Screen Recording permission. Normal launches skip all of this.
enum ScreenshotMode {
    static let outputFolder: URL? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--screenshots"), index + 1 < arguments.count else { return nil }
        return URL(filePath: arguments[index + 1])
    }()

    static var isActive: Bool { outputFolder != nil }

    /// The app whose detail sheet is captured: the one using the most space.
    static let detailNotification = Notification.Name("CleanMacScreenshotOpenAppDetail")

    @MainActor
    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0.sheetParent == nil }
    }

    /// Captures one of CleanMac's own windows exactly as shown on screen (translucent sidebar included).
    /// macOS allows an app to capture its own windows without Screen Recording permission.
    @MainActor
    static func capture(_ window: NSWindow, name: String) {
        guard let folder = outputFolder,
              let image = CGWindowListCreateImage(
                  .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]
              ) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(cgImage: image)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name).png"))
    }

    @MainActor
    static func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Waits until `condition` holds, for at most `timeout` seconds.
    @MainActor
    static func wait(until condition: () -> Bool, timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
        }
    }
}
