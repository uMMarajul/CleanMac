import XCTest
@testable import CleanMac

final class OrphanFinderTests: XCTestCase {
    func testBundleIDParsing() {
        XCTAssertEqual(OrphanFinder.bundleID(fromEntry: "com.old.app.plist"), "com.old.app")
        XCTAssertEqual(OrphanFinder.bundleID(fromEntry: "com.old.app.savedState"), "com.old.app")
        XCTAssertNil(OrphanFinder.bundleID(fromEntry: "Google"))
        XCTAssertNil(OrphanFinder.bundleID(fromEntry: "foo.bar"))
        XCTAssertNil(OrphanFinder.bundleID(fromEntry: "My App.data.file"))
    }

    func testFindsOnlyLeftoversOfUninstalledApps() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let home = StorageScanner.realPath({ try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true); return temp }())
        defer { try? FileManager.default.removeItem(at: home) }
        for entry in [
            "Library/Caches/com.old.app/x", "Library/Preferences/com.old.app.plist",
            "Library/Caches/com.installed.app/x", "Library/Caches/com.installed.app.helper/x",
            "Library/Caches/com.apple.Safari/x", "Library/Caches/com.known.elsewhere/x",
        ] {
            let url = home.appending(path: entry)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }

        let found = OrphanFinder.find(
            home: home,
            installed: [(bundleID: "com.installed.app", name: "Installed")],
            knownToSystem: { $0 == "com.known.elsewhere" }
        )

        XCTAssertEqual(Set(found.map(\.path)), [
            home.path + "/Library/Caches/com.old.app",
            home.path + "/Library/Preferences/com.old.app.plist",
        ])
    }

    func testSameDeveloperHint() {
        XCTAssertEqual(
            OrphanFinder.sameDeveloper("com.google.Keystone.Agent", installed: [(bundleID: "com.google.Chrome", name: "Google Chrome")]),
            "Google Chrome"
        )
    }
}

final class DeveloperToolsTests: XCTestCase {
    func testParsesSimulatorRuntimes() {
        let json = """
        { "33ED": { "identifier": "33ED", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                    "version": "26.5", "sizeBytes": 8494282293, "deletable": true, "lastUsedAt": "2026-11-11T06:03:40Z" } }
        """
        let runtimes = DeveloperTools.parseRuntimes(json)
        XCTAssertEqual(runtimes.count, 1)
        XCTAssertEqual(runtimes[0].name, "iOS 26.5")
        XCTAssertEqual(runtimes[0].sizeBytes, 8_494_282_293)
        XCTAssertTrue(runtimes[0].deletable)
        XCTAssertNotNil(runtimes[0].lastUsed)
    }

    func testParsesUnavailableDevices() {
        let json = #"{ "devices": { "rt": [ { "udid": "A-1", "name": "iPhone" } ], "rt2": [] } }"#
        XCTAssertEqual(DeveloperTools.parseUnavailableDevices(json), ["A-1"])
    }

    func testParsesDockerSizes() {
        XCTAssertEqual(DeveloperTools.parseDockerSize("1.2GB"), 1_200_000_000)
        XCTAssertEqual(DeveloperTools.parseDockerSize("512kB"), 512_000)
        XCTAssertEqual(DeveloperTools.parseDockerSize("0B"), 0)
        let usage = DeveloperTools.parseDockerDF("""
        {"Type":"Images","Size":"2.4GB","Reclaimable":"1.2GB (50%)"}
        {"Type":"Build Cache","Size":"300MB","Reclaimable":"300MB"}
        """)
        XCTAssertEqual(usage["Images"]?.reclaimable, 1_200_000_000)
        XCTAssertEqual(usage["Build Cache"]?.size, 300_000_000)
    }
}
