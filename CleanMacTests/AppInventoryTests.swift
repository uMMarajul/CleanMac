import XCTest
@testable import CleanMac

final class AppInventoryTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        home = StorageScanner.realPath(temp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testLeftoversMatchExactBundleIDOnly() throws {
        for path in [
            "Library/Caches/com.foo/x", "Library/Caches/com.foobar/x",
            "Library/Preferences/com.foo.plist", "Library/Preferences/com.foobar.plist",
            "Library/Preferences/ByHost/com.foo.0A1B2C.plist",
            "Library/Preferences/ByHost/com.foo.helper.0A1B2C.plist",
            "Library/Preferences/ByHost/com.foobar.0A1B2C.plist",
        ] {
            try touch(path)
        }

        let found = AppInventory.associatedFiles(bundleID: "com.foo", name: "Foo", groups: [], home: home)

        XCTAssertEqual(Set(found.map(\.path)), Set([
            home.path + "/Library/Caches/com.foo",
            home.path + "/Library/Preferences/com.foo.plist",
            home.path + "/Library/Preferences/ByHost/com.foo.0A1B2C.plist",
        ]))
    }

    func testSafetyAndNameOnlyMatches() throws {
        try touch("Library/Caches/com.foo/x")
        try touch("Library/Application Support/com.foo/x")
        try touch("Library/Application Support/Foo/x")

        let found = AppInventory.associatedFiles(bundleID: "com.foo", name: "Foo", groups: [], home: home)
        func file(_ relative: String) -> AssociatedFile? { found.first { $0.path == home.path + "/" + relative } }

        XCTAssertEqual(file("Library/Caches/com.foo")?.safety, .safe)
        XCTAssertEqual(file("Library/Application Support/com.foo")?.safety, .reviewRequired)
        XCTAssertEqual(file("Library/Application Support/Foo")?.byNameOnly, true)
    }

    func testFindsChromiumCachesInsideApplicationSupport() throws {
        try touch("Library/Application Support/Claude/Cache/data_0")
        try touch("Library/Application Support/Claude/Partitions/work/Code Cache/js")
        try touch("Library/Application Support/Claude/vm_bundles/disk.img")
        try touch("Library/Application Support/Google/Chrome/Default/Code Cache/js") // browser profile: not matched

        let found = AppInventory.associatedFiles(bundleID: "com.example.claude", name: "Claude", groups: [], home: home)
        let caches = found.filter { $0.kind == "App Cache" }.map(\.path)

        XCTAssertEqual(Set(caches), [
            home.path + "/Library/Application Support/Claude/Cache",
            home.path + "/Library/Application Support/Claude/Partitions/work/Code Cache",
        ])
        XCTAssertTrue(found.filter { $0.kind == "App Cache" }.allSatisfy { $0.safety == .safe })
        XCTAssertNil(StorageCategory.supportCacheOwner(
            path: home.path + "/Library/Application Support/Google/Chrome/Default/Code Cache", home: home
        ))
        // The cache is inside Application Support/Claude: counted once in the total.
        XCTAssertEqual(AppInventory.totalSize(found), found.first { $0.kind == "Application Support" }?.size)
    }

    func testRunningOwnerBlocksSupportCacheCleanup() throws {
        try touch("Library/Application Support/Claude/Cache/data_0")
        let cache = ScanItem(
            path: home.path + "/Library/Application Support/Claude/Cache", size: 1, fileCount: 1,
            modified: nil, isFolder: true, category: .applicationCaches
        )
        let reason = CleanupEngine.refusal(for: cache, home: home, runningApps: [("com.anthropic.claudefordesktop", "Claude")])
        XCTAssertEqual(reason, "Quit Claude first")
    }

    func testKeepUserDataSelectsOnlySafeBundleIDLeftovers() {
        let files = [
            AssociatedFile(path: "/c", kind: "Caches", size: 1, safety: .safe, byNameOnly: false),
            AssociatedFile(path: "/s", kind: "Application Support", size: 1, safety: .reviewRequired, byNameOnly: false),
            AssociatedFile(path: "/n", kind: "Caches", size: 1, safety: .reviewRequired, byNameOnly: true),
            AssociatedFile(path: "/g", kind: "Group Container", size: 1, safety: .reviewRequired, byNameOnly: false, sharedWith: "Other"),
        ]
        XCTAssertEqual(AppInventory.defaultSelection(files, keepUserData: true), ["/c"])
        XCTAssertEqual(AppInventory.defaultSelection(files, keepUserData: false), ["/c", "/s"])
    }

    func testSharedGroupIsDetected() {
        let apps = [
            (bundleID: "com.foo", name: "Foo", groups: ["TEAM.group.shared"]),
            (bundleID: "com.bar", name: "Bar", groups: ["TEAM.group.shared"]),
        ]
        XCTAssertEqual(AppInventory.sharing(group: "TEAM.group.shared", excluding: "com.foo", apps: apps), "Bar")
        XCTAssertNil(AppInventory.sharing(group: "TEAM.group.only", excluding: "com.foo", apps: apps))
    }

    func testUsageClassificationFollowsThresholds() {
        let now = Date()
        func usage(daysAgo: Double?) -> AppUsage {
            AppUsage.classify(
                lastOpened: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) }, now: now,
                recentDays: 30, occasionalDays: 90, longUnusedDays: 180
            )
        }
        XCTAssertEqual(usage(daysAgo: 5), .recent)
        XCTAssertEqual(usage(daysAgo: 60), .occasional)
        XCTAssertEqual(usage(daysAgo: 120), .unused)
        XCTAssertEqual(usage(daysAgo: 400), .longUnused)
        XCTAssertEqual(usage(daysAgo: nil), .unknown)
    }

    func testAppRefusals() throws {
        let folder = home.appending(path: "Applications")
        try touch("Applications/Foo.app/Contents/Info.plist")
        try touch("Elsewhere/Bar.app/Contents/Info.plist")

        XCTAssertNil(CleanupEngine.appRefusal(
            appPath: folder.path + "/Foo.app", bundleID: "com.foo", appFolders: [folder], runningApps: []
        ))
        XCTAssertEqual(CleanupEngine.appRefusal(
            appPath: folder.path + "/Foo.app", bundleID: "com.foo", appFolders: [folder], runningApps: [("com.foo", "Foo")]
        ), "Quit Foo first")
        XCTAssertEqual(CleanupEngine.appRefusal(
            appPath: home.path + "/Elsewhere/Bar.app", bundleID: "com.bar", appFolders: [folder], runningApps: []
        ), "Not in an applications folder")
    }

    private func touch(_ relative: String) throws {
        let url = home.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }
}
