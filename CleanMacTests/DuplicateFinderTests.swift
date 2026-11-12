import XCTest
@testable import CleanMac

final class DuplicateFinderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        root = StorageScanner.realPath(temp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFindsIdenticalContentOnly() throws {
        var content = Data(repeating: 7, count: 2_000_000)
        try write("a.bin", content)
        try write("sub/b.bin", content)
        content[content.count - 1] = 8 // same size, different last byte
        try write("c.bin", content)
        try FileManager.default.linkItem(atPath: path("a.bin"), toPath: path("hardlink.bin")) // same file, not a copy

        let groups = DuplicateFinder.find(in: [root], minSize: 1_000_000, progress: ScanProgress())

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].files.map(\.name)).count, 2)
        XCTAssertTrue(Set(groups[0].files.map(\.path)).isSuperset(of: [path("sub/b.bin")]))
        XCTAssertFalse(groups[0].files.contains { $0.path == path("c.bin") })
        XCTAssertEqual(groups[0].wasted, 2_000_000)
    }

    func testOneCopyIsAlwaysKept() {
        let group = DuplicateGroup(id: "x", size: 10, files: [file("/a"), file("/b")])
        XCTAssertEqual(DuplicateFinder.removable([group], selected: ["/a", "/b"]), [], "never every copy")
        XCTAssertEqual(DuplicateFinder.removable([group], selected: ["/a"]).map(\.path), ["/a"])
    }

    func testSuggestedKeepPrefersCopyOutsideDownloads() {
        let home = URL(filePath: "/Users/me")
        let group = DuplicateGroup(id: "x", size: 10, files: [
            file("/Users/me/Downloads/report.pdf", created: .distantPast),
            file("/Users/me/Documents/report.pdf", created: .now),
        ])
        XCTAssertEqual(DuplicateFinder.suggestedKeep(group, home: home), "/Users/me/Documents/report.pdf")
    }

    private func file(_ path: String, created: Date? = nil) -> DuplicateFile {
        DuplicateFile(path: path, modified: nil, created: created)
    }

    private func path(_ relative: String) -> String { root.appending(path: relative).path }

    private func write(_ relative: String, _ data: Data) throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
