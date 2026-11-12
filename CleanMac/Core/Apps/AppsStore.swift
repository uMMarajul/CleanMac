import Foundation
import SwiftData

/// Runs the app inventory scan and saves the result as `InstalledApp` rows (replacing the old list).
@MainActor
final class AppsStore: ObservableObject {
    @Published private(set) var scanning = false

    let home = StorageScanner.realPath(FileManager.default.homeDirectoryForCurrentUser)

    func folders(extra: String) -> [URL] {
        AppInventory.appFolders(home: home, extra: extra.split(separator: "\n").map(String.init))
    }

    func refresh(context: ModelContext, extraFolders: String) {
        guard !scanning else { return }
        scanning = true
        let folders = folders(extra: extraFolders)
        let home = home
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                await AppInventory.scan(folders: folders, home: home)
            }.value
            try? context.delete(model: InstalledApp.self)
            for app in found {
                context.insert(InstalledApp(
                    name: app.name,
                    bundleIdentifier: app.bundleID,
                    version: app.version,
                    installationPath: app.path,
                    bundleSize: app.bundleSize,
                    associatedDataSize: app.associatedSize,
                    lastOpenedDate: app.lastOpened,
                    isProtected: app.isProtected,
                    appGroups: app.groups
                ))
            }
            try? context.save()
            scanning = false
        }
    }
}
