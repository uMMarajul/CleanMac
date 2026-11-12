import SQLite3
import XCTest
@testable import CleanMac

final class ScheduleTests: XCTestCase {
    func testNextRunIsOnePeriodLaterAtTheChosenHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let last = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 15))!
        func next(_ frequency: ScheduleFrequency) -> DateComponents {
            calendar.dateComponents([.month, .day, .hour], from: Schedule.nextRun(after: last, frequency: frequency, hour: 9, calendar: calendar))
        }
        XCTAssertEqual(next(.daily), DateComponents(month: 11, day: 13, hour: 9))
        XCTAssertEqual(next(.weekly), DateComponents(month: 11, day: 19, hour: 9))
        XCTAssertEqual(next(.monthly), DateComponents(month: 12, day: 12, hour: 9))
    }

    func testAutomaticCleanupOffersSafeCategoriesOnly() {
        XCTAssertFalse(Schedule.autoCleanable.isEmpty)
        XCTAssertTrue(Schedule.autoCleanable.allSatisfy { $0.safety == .safe })
        XCTAssertFalse(Schedule.autoCleanable.contains(.oldInstallers))
    }
}

final class RecommendationTests: XCTestCase {
    private let home = URL(filePath: "/Users/me")

    private func input(available: Int64 = 300_000_000_000) -> Recommendations.Input {
        Recommendations.Input(
            home: home, diskTotal: 500_000_000_000, diskAvailable: available, result: nil, devItems: [],
            apps: [], longUnusedDays: 180, trashBytes: nil, pressure: .normal
        )
    }

    func testNothingToRecommendOnATidyMac() {
        XCTAssertTrue(Recommendations.build(input()).isEmpty)
    }

    func testLowDiskSpaceComesFirst() {
        var data = input(available: 8_000_000_000)
        data.trashBytes = 3_000_000_000
        let list = Recommendations.build(data)
        XCTAssertEqual(list.first?.target, .systemData)
        XCTAssertTrue(list.contains { $0.target == .junkCleaner })
    }

    func testOldRuntimesAndUnusedAppsAreSuggested() {
        var data = input()
        let old = Date().addingTimeInterval(-90 * 86_400)
        data.devItems = [DevItem(id: "runtime-x", group: "Simulators", title: "iOS 18 runtime", detail: "", size: 8_000_000_000,
                                 safety: .reviewRequired, action: .none, lastUsed: old)]
        data.apps = [
            (name: "Old", lastOpened: Date().addingTimeInterval(-400 * 86_400), size: 2_000_000_000, isProtected: false),
            (name: "Safari", lastOpened: Date().addingTimeInterval(-400 * 86_400), size: 2_000_000_000, isProtected: true),
            (name: "New", lastOpened: Date(), size: 2_000_000_000, isProtected: false),
        ]
        let list = Recommendations.build(data)
        XCTAssertTrue(list.contains { $0.target == .developerCleaner })
        XCTAssertTrue(list.contains { $0.title.hasPrefix("1 app unused") }, "protected and recent apps are not counted")
    }
}

final class PrivacyTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        home = StorageScanner.realPath(temp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testChromiumProfilesHistoryCookiesAndExtensions() throws {
        let chrome = "Library/Application Support/Google/Chrome"
        try write("\(chrome)/Default/History", "h")
        try write("\(chrome)/Profile 1/Network/Cookies", "c")
        try write("\(chrome)/Default/Extensions/abc/1.0/manifest.json", #"{"name":"__MSG_appName__","default_locale":"en"}"#)
        try write("\(chrome)/Default/Extensions/abc/1.0/_locales/en/messages.json", #"{"appName":{"message":"Dark Reader"}}"#)
        try write("\(chrome)/Local State", "{}") // not a profile

        let spec = try XCTUnwrap(BrowserInspector.browsers.first { $0.bundleID == "com.google.Chrome" })
        let data = BrowserInspector.inspect(spec, home: home)

        XCTAssertEqual(data.profiles, 2)
        XCTAssertEqual(data.history, [home.path + "/\(chrome)/Default/History"])
        XCTAssertEqual(data.cookies, [home.path + "/\(chrome)/Profile 1/Network/Cookies"])
        XCTAssertEqual(data.extensions, ["Dark Reader"])
    }

    func testFirefoxHistoryIsNeverOfferedAndAddonsAreRead() throws {
        let profile = "Library/Application Support/Firefox/Profiles/abc.default"
        try write("\(profile)/places.sqlite", "history and bookmarks")
        try write("\(profile)/extensions.json", """
        {"addons":[{"type":"extension","location":"app-profile","defaultLocale":{"name":"uBlock Origin"}},
                   {"type":"extension","location":"app-system-defaults","defaultLocale":{"name":"Built-in"}}]}
        """)
        let spec = try XCTUnwrap(BrowserInspector.browsers.first { $0.engine == .firefox })
        let data = BrowserInspector.inspect(spec, home: home)

        XCTAssertTrue(data.history.isEmpty, "places.sqlite also holds bookmarks")
        XCTAssertNotNil(data.historyNote)
        XCTAssertEqual(data.extensions, ["uBlock Origin"])
    }

    func testPluginkitParsing() {
        XCTAssertEqual(BrowserInspector.parsePluginkit("+    com.example.Ext(1.2)\n-    org.other.Blocker(3)\n"),
                       ["com.example.Ext", "org.other.Blocker"])
    }

    func testBrowserHistoryIsRefusedWhileBrowserRuns() throws {
        try write("Library/Application Support/Google/Chrome/Default/History", "h")
        let item = ScanItem(path: home.path + "/Library/Application Support/Google/Chrome/Default/History", size: 1,
                            fileCount: 1, modified: nil, isFolder: false, category: nil)
        XCTAssertEqual(CleanupEngine.refusal(for: item, home: home, runningApps: [("com.google.Chrome", "Google Chrome")]),
                       "Quit Google Chrome first")
        XCTAssertNil(CleanupEngine.refusal(for: item, home: home, runningApps: []))
    }

    func testReadsPermissionGrantsFromPrivacyDatabase() throws {
        let path = home.appending(path: "TCC.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE access (service TEXT, client TEXT, auth_value INTEGER);
        INSERT INTO access VALUES ('kTCCServiceCamera', 'us.zoom.xos', 2);
        INSERT INTO access VALUES ('kTCCServiceMicrophone', 'us.zoom.xos', 0);
        INSERT INTO access VALUES ('kTCCServiceSomethingInternal', 'x', 2);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let grants = try XCTUnwrap(AppPermissions.read(databases: [path]))
        XCTAssertEqual(Set(grants.map(\.id)), ["kTCCServiceCamera|us.zoom.xos", "kTCCServiceMicrophone|us.zoom.xos"])
        XCTAssertEqual(grants.first { $0.service == "kTCCServiceCamera" }?.allowed, true)
        XCTAssertNil(AppPermissions.read(databases: [home.path + "/missing.db"]))
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = home.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
