import XCTest
@testable import CleanMac

final class StorageScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        root = StorageScanner.realPath(temp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFolderSizesAggregateUpTheTree() async throws {
        try write("a/b/one.bin", bytes: 2_000_000)
        try write("a/two.bin", bytes: 2_000_000)
        try write("small.txt", bytes: 1_000)

        let nodes = await StorageScanner.scan(roots: [root], progress: ScanProgress())
        let top = try XCTUnwrap(nodes.first)
        let a = try XCTUnwrap(top.children.first { $0.name == "a" })

        XCTAssertEqual(a.size, try allocated("a/b/one.bin") + allocated("a/two.bin"))
        XCTAssertEqual(top.size, try a.size + allocated("small.txt"))
        XCTAssertEqual(top.fileCount, 3)
    }

    func testNestedRuleWinsAndTotalsBalance() async throws {
        try write("Library/Caches/com.example.app/data.bin", bytes: 2_000_000)
        try write("Library/Caches/pip/wheel.bin", bytes: 2_000_000)
        try write("Library/Developer/Xcode/DerivedData/Proj/build.bin", bytes: 2_000_000)
        try write("Library/Developer/Tools/tool.bin", bytes: 2_000_000)
        try write("Documents/report.bin", bytes: 2_000_000)

        let nodes = await StorageScanner.scan(roots: [root], progress: ScanProgress())
        let analysis = StorageAnalyzer.analyze(nodes, home: root)
        func bytes(_ category: StorageCategory) -> Int64 {
            analysis.categories.first { $0.category == category }?.bytes ?? 0
        }

        XCTAssertEqual(bytes(.applicationCaches), try allocated("Library/Caches/com.example.app/data.bin"))
        XCTAssertEqual(bytes(.pythonGoCaches), try allocated("Library/Caches/pip/wheel.bin"))
        XCTAssertEqual(bytes(.xcodeDerivedData), try allocated("Library/Developer/Xcode/DerivedData/Proj/build.bin"))
        XCTAssertEqual(bytes(.developerData), try allocated("Library/Developer/Tools/tool.bin"))
        XCTAssertEqual(analysis.otherBytes, try allocated("Documents/report.bin"))

        let categorized = analysis.categories.reduce(0) { $0 + $1.bytes }
        XCTAssertEqual(categorized + analysis.otherBytes, nodes[0].size, "every byte is counted exactly once")
    }

    func testUnreadableFolderIsReportedAsInaccessible() async throws {
        try write("locked/secret.bin", bytes: 1_000)
        let locked = root.appending(path: "locked").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

        let progress = ScanProgress()
        _ = await StorageScanner.scan(roots: [root], progress: progress)

        XCTAssertTrue(progress.inaccessiblePaths.contains { $0.hasSuffix("/locked") })
    }

    func testSkippedFolderIsNotEnteredAndIsReported() async throws {
        try write("Desktop/photo.bin", bytes: 2_000_000)
        let desktop = root.appending(path: "Desktop").path

        let progress = ScanProgress(skipped: [desktop])
        let nodes = await StorageScanner.scan(roots: [root], progress: progress)
        let top = try XCTUnwrap(nodes.first)

        XCTAssertEqual(top.size, 0)
        XCTAssertEqual(progress.inaccessiblePaths, [desktop])
    }

    func testLargeFilesRespectTheFloor() async throws {
        try write("big.bin", bytes: 3_000_000)
        try write("small.bin", bytes: 1_000)

        let nodes = await StorageScanner.scan(roots: [root], progress: ScanProgress())
        let analysis = StorageAnalyzer.analyze(nodes, home: root, largeFileFloor: 1_000_000)

        XCTAssertEqual(analysis.largeFiles.map(\.name), ["big.bin"])
    }

    // MARK: Helpers

    private func write(_ relative: String, bytes: Int) throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func allocated(_ relative: String) throws -> Int64 {
        let values = try root.appending(path: relative).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(values.totalFileAllocatedSize ?? 0)
    }
}
