import AppKit

/// Developer tool for the README: `CleanMac.app/Contents/MacOS/CleanMac --screenshots <folder>`
/// visits each screen, saves a PNG of CleanMac's own window, then quits.
/// Capturing its own windows needs no Screen Recording permission. Normal launches skip all of this.
enum ScreenshotMode {
    static let outputFolder: URL? = folder(after: "--screenshots")
    /// `--demo-frames <folder>`: records a tour of the app as numbered PNG frames for a demo GIF.
    static let demoFolder: URL? = folder(after: "--demo-frames")

    static var isActive: Bool { outputFolder != nil || demoFolder != nil }

    private static func folder(after flag: String) -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return URL(filePath: arguments[index + 1])
    }

    // MARK: Demo recording

    static let framesPerSecond = 4.0
    @MainActor private static var frameNumber = 0

    /// Records frames of the main window (with any open sheet drawn on top) for `seconds`.
    @MainActor
    static func record(_ window: NSWindow, seconds: Double) async {
        for _ in 0..<Int(seconds * framesPerSecond) {
            if let folder = demoFolder, let frame = composite(window) {
                frameNumber += 1
                let url = folder.appending(path: String(format: "frame_%04d.png", frameNumber))
                try? NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])?.write(to: url)
            }
            try? await Task.sleep(for: .seconds(1 / framesPerSecond))
        }
    }

    @MainActor
    private static func image(of window: NSWindow) -> CGImage? {
        CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])
    }

    /// A sheet is its own window, so it is drawn onto the main window's image at its position.
    @MainActor
    private static func composite(_ window: NSWindow) -> CGImage? {
        guard let base = image(of: window) else { return nil }
        guard let sheet = window.attachedSheet, let top = image(of: sheet),
              let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return base }
        let scale = CGFloat(base.width) / window.frame.width
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        context.draw(top, in: CGRect(
            x: (sheet.frame.minX - window.frame.minX) * scale,
            y: (sheet.frame.minY - window.frame.minY) * scale,
            width: CGFloat(top.width), height: CGFloat(top.height)
        ))
        return context.makeImage()
    }

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
