import Foundation
import SQLite3

struct PrivacyService: Identifiable {
    /// TCC service name, e.g. "kTCCServiceCamera".
    let key: String
    let title: String
    let icon: String
    /// System Settings anchor in Privacy & Security.
    let anchor: String
    var id: String { key }

    var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

struct PermissionGrant: Identifiable, Hashable {
    let service: String
    /// Bundle identifier or executable path.
    let client: String
    let allowed: Bool
    var id: String { service + "|" + client }
}

/// Which apps have which privacy permissions, read from macOS's privacy databases.
/// Read-only: changes are made in System Settings. Needs Full Disk Access to read.
enum AppPermissions {
    static let services: [PrivacyService] = [
        PrivacyService(key: "kTCCServiceCamera", title: "Camera", icon: "camera", anchor: "Privacy_Camera"),
        PrivacyService(key: "kTCCServiceMicrophone", title: "Microphone", icon: "mic", anchor: "Privacy_Microphone"),
        PrivacyService(key: "kTCCServiceScreenCapture", title: "Screen Recording", icon: "rectangle.dashed.badge.record", anchor: "Privacy_ScreenCapture"),
        PrivacyService(key: "kTCCServiceAccessibility", title: "Accessibility", icon: "accessibility", anchor: "Privacy_Accessibility"),
        PrivacyService(key: "kTCCServiceSystemPolicyAllFiles", title: "Full Disk Access", icon: "internaldrive", anchor: "Privacy_AllFiles"),
        PrivacyService(key: "kTCCServiceListenEvent", title: "Input Monitoring", icon: "keyboard", anchor: "Privacy_ListenEvent"),
        PrivacyService(key: "kTCCServiceAppleEvents", title: "Automation", icon: "gearshape.2", anchor: "Privacy_Automation"),
        PrivacyService(key: "kTCCServicePhotos", title: "Photos", icon: "photo", anchor: "Privacy_Photos"),
        PrivacyService(key: "kTCCServiceAddressBook", title: "Contacts", icon: "person.crop.circle", anchor: "Privacy_Contacts"),
        PrivacyService(key: "kTCCServiceCalendar", title: "Calendars", icon: "calendar", anchor: "Privacy_Calendars"),
        PrivacyService(key: "kTCCServiceReminders", title: "Reminders", icon: "checklist", anchor: "Privacy_Reminders"),
        PrivacyService(key: "kTCCServiceBluetoothAlways", title: "Bluetooth", icon: "dot.radiowaves.left.and.right", anchor: "Privacy_Bluetooth"),
        PrivacyService(key: "kTCCServiceSystemPolicyDesktopFolder", title: "Desktop Folder", icon: "menubar.dock.rectangle", anchor: "Privacy_FilesAndFolders"),
        PrivacyService(key: "kTCCServiceSystemPolicyDocumentsFolder", title: "Documents Folder", icon: "doc", anchor: "Privacy_FilesAndFolders"),
        PrivacyService(key: "kTCCServiceSystemPolicyDownloadsFolder", title: "Downloads Folder", icon: "arrow.down.circle", anchor: "Privacy_FilesAndFolders"),
        PrivacyService(key: "kTCCServiceSystemPolicyRemovableVolumes", title: "Removable Volumes", icon: "externaldrive", anchor: "Privacy_FilesAndFolders"),
        PrivacyService(key: "kTCCServiceSystemPolicyNetworkVolumes", title: "Network Volumes", icon: "network", anchor: "Privacy_FilesAndFolders"),
    ]

    static func databases(home: URL) -> [String] {
        [home.path + "/Library/Application Support/com.apple.TCC/TCC.db", "/Library/Application Support/com.apple.TCC/TCC.db"]
    }

    /// Grants for the services above. nil when no database could be read (Full Disk Access missing).
    static func read(databases: [String]) -> [PermissionGrant]? {
        let known = Set(services.map(\.key))
        var grants: [String: PermissionGrant] = [:]
        var readAny = false

        for path in databases {
            var db: OpaquePointer?
            defer { sqlite3_close(db) }
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { continue }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT service, client, auth_value FROM access", -1, &statement, nil) == SQLITE_OK else { continue }
            readAny = true
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let servicePointer = sqlite3_column_text(statement, 0),
                      let clientPointer = sqlite3_column_text(statement, 1) else { continue }
                let service = String(cString: servicePointer)
                guard known.contains(service) else { continue }
                // auth_value: 0 denied, 2 allowed, 3 limited.
                let value = sqlite3_column_int(statement, 2)
                let grant = PermissionGrant(service: service, client: String(cString: clientPointer), allowed: value == 2 || value == 3)
                grants[grant.id] = grant
            }
        }
        return readAny ? Array(grants.values) : nil
    }
}
