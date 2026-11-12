import Foundation

struct AdminError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs read-only commands as administrator through the standard macOS password prompt.
/// The password goes to macOS, never to CleanMac.
enum AdminHelper {
    static let measurePrompt = "CleanMac wants to measure folders owned by macOS. It only reads their sizes and changes nothing."

    /// Sizes of folders only an administrator can read. Read-only: runs `du`.
    /// Returns nil if the user cancels the password prompt.
    static func measure(_ paths: [String]) throws -> [String: Int64]? {
        try run(appleScript(for: paths)).map(parse)
    }

    /// The full Login Items and background items list, which only an administrator can read.
    static func loginItemsReport() throws -> String? {
        try run(appleScript(
            command: "/usr/bin/sfltool dumpbtm",
            prompt: "CleanMac wants to read the list of login and background items. It changes nothing."
        ))
    }

    /// Runs an AppleScript (with an administrator shell command). nil when the user cancels.
    private static func run(_ script: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            if errorText.contains("-128") { return nil } // user cancelled
            throw AdminError(message: errorText.isEmpty ? "The administrator command failed." : errorText)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// `du -sk` over every path, each single-quoted for the shell. Errors are ignored so one
    /// unreadable folder (e.g. protected by System Integrity Protection) does not fail the rest.
    static func shellCommand(for paths: [String]) -> String {
        let quoted = paths.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "/usr/bin/du -sk " + quoted.joined(separator: " ") + " 2>/dev/null; true"
    }

    static func appleScript(for paths: [String]) -> String {
        appleScript(command: shellCommand(for: paths), prompt: measurePrompt)
    }

    static func appleScript(command: String, prompt: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges without altering line endings"
            + " with prompt \"\(prompt)\""
    }

    /// Parses `du -sk` lines ("<KiB>\t<path>") into bytes per path.
    static func parse(_ output: String) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kib = Int64(parts[0]) else { continue }
            sizes[String(parts[1])] = kib * 1024
        }
        return sizes
    }
}
