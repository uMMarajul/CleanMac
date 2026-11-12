import XCTest
@testable import CleanMac

final class CleanupEngineTests: XCTestCase {
    /// Acts as the home folder for the engine's location rules.
    private var home: URL!
    /// Items trashed by a test that were not put back; removed from the Trash on tear down.
    private var trashedLeftovers: [String] = []

    override func setUpWithError() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        home = StorageScanner.realPath(temp)
    }

    override func tearDownWithError() throws {
        trashedLeftovers.forEach { try? FileManager.default.removeItem(atPath: $0) }
        try? FileManager.default.removeItem(at: home)
    }

    func testRefusesProtectedSystemAndEssentialLocations() {
        func refusal(_ path: String, _ category: StorageCategory? = .applicationCaches) -> String? {
            CleanupEngine.locationRefusal(for: item(path, category: category), home: home)
        }
        XCTAssertNotNil(refusal("/System/Library/Caches/x"))
        XCTAssertNotNil(refusal("/usr/lib/x"))
        XCTAssertNotNil(refusal("/Applications/Safari.app", nil))
        XCTAssertNotNil(refusal("/private/var/folders/xy/T/cache", nil), "system temp outside home")
        XCTAssertNotNil(refusal(home.path))
        XCTAssertNotNil(refusal(home.path + "/Documents"))
        XCTAssertNotNil(refusal(home.path + "/Library/Caches"))
        XCTAssertNotNil(refusal("/opt/homebrew/x"), "outside cleanable locations")
        XCTAssertNotNil(refusal(home.path + "/Library/Caches/x", .localSnapshots), "protected category")
        XCTAssertNil(refusal(home.path + "/Library/Caches/com.example.app"))
    }

    func testTrashThenPutBackRoundTripRemeasuresSize() throws {
        let path = try write("Library/Caches/com.example.app/data.bin", bytes: 2_000_000)
        let folder = home.path + "/Library/Caches/com.example.app"
        let stale = item(folder, size: 1) // the scan's size is out of date
        let actual = try allocated(path)

        let report = CleanupEngine.clean([stale], home: home, runningApps: [])

        XCTAssertEqual(report.cleaned.count, 1)
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertEqual(report.freedBytes, actual, "size is measured at cleanup time")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder))
        let trashPath = try XCTUnwrap(report.cleaned.first?.trashPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashPath))

        try CleanupEngine.putBack(trashPath: trashPath, originalPath: folder)

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashPath))
    }

    func testRunningAppCacheIsSkipped() throws {
        let path = try write("Library/Caches/com.example.running/data.bin", bytes: 1_000)
        let cache = item(home.path + "/Library/Caches/com.example.running")

        let report = CleanupEngine.clean([cache], home: home, runningApps: [("com.example.running", "Example")])

        XCTAssertTrue(report.cleaned.isEmpty)
        XCTAssertEqual(report.skipped.first?.reason, "Quit Example first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testFolderAndItsChildAreTrashedOnce() throws {
        try write("Library/Caches/com.example.app/data.bin", bytes: 1_000)
        let folder = item(home.path + "/Library/Caches/com.example.app")
        let child = item(home.path + "/Library/Caches/com.example.app/data.bin")

        let report = CleanupEngine.clean([child, folder], home: home, runningApps: [])
        trashedLeftovers += report.cleaned.compactMap(\.trashPath)

        XCTAssertEqual(report.cleaned.map(\.item.path), [folder.path])
        XCTAssertTrue(report.skipped.isEmpty, "the child is not reported as missing")
    }

    func testReadOnlyFolderOwnedByUserIsTrashed() throws {
        try write("go/pkg/mod/example.com@v1.0.0/go.mod", bytes: 100)
        let module = home.path + "/go/pkg/mod/example.com@v1.0.0"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: module) // like Go does

        let report = CleanupEngine.clean([item(module, category: .pythonGoCaches)], home: home, runningApps: [])
        trashedLeftovers += report.cleaned.compactMap(\.trashPath)

        XCTAssertEqual(report.cleaned.map(\.item.path), [module])
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: module))
    }

    func testCleanupUpdatesTotalsAndLists() {
        let cacheA = item("/x/Caches/a", size: 5)
        let cacheB = item("/x/Caches/b", size: 5)
        let video = item("/x/Movies/v.mov", size: 3, category: nil)
        var result = ScanResult(
            scannedAt: .now, duration: 1, totalBytes: 13, otherBytes: 3,
            categories: [CategoryTotal(category: .applicationCaches, bytes: 10, files: 2, items: [cacheA, cacheB])],
            largeFiles: [video], inaccessible: [], snapshotCount: 0
        )

        result.remove([
            CleanedItem(item: cacheA, size: 5, trashPath: nil),
            CleanedItem(item: video, size: 3, trashPath: nil),
        ])

        XCTAssertEqual(result.totalBytes, 5)
        XCTAssertEqual(result.otherBytes, 0)
        XCTAssertEqual(result.categories[0].bytes, 5)
        XCTAssertEqual(result.categories[0].items.map(\.path), [cacheB.path])
        XCTAssertTrue(result.largeFiles.isEmpty)

        result.restore(cacheA)
        XCTAssertEqual(result.totalBytes, 10)
        XCTAssertEqual(result.categories[0].bytes, 10)
    }

    // MARK: Helpers

    private func item(_ path: String, size: Int64 = 1, category: StorageCategory? = .applicationCaches) -> ScanItem {
        ScanItem(path: path, size: size, fileCount: 1, modified: nil, isFolder: false, category: category)
    }

    @discardableResult
    private func write(_ relative: String, bytes: Int) throws -> String {
        let url = home.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url.path
    }

    private func allocated(_ path: String) throws -> Int64 {
        Int64(try URL(filePath: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
    }
}
