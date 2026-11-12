import XCTest
@testable import CleanMac

final class PerformanceTests: XCTestCase {
    func testCPUUsageFromTicks() {
        let before = CoreTicks(user: 100, system: 50, idle: 850, nice: 0)
        let after = CoreTicks(user: 160, system: 70, idle: 870, nice: 0)
        XCTAssertEqual(SystemStats.usage(from: before, to: after), 0.8, accuracy: 0.0001) // 80 busy of 100
    }

    func testCPUUsageSurvivesCounterWrap() {
        let before = CoreTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)
        let after = CoreTicks(user: 10, system: 0, idle: 20, nice: 0)
        XCTAssertEqual(SystemStats.usage(from: before, to: after), 0.5, accuracy: 0.0001) // 20 busy, 20 idle
    }

    func testMemoryPressureLevels() {
        XCTAssertEqual(MemoryPressure(level: 1), .normal)
        XCTAssertEqual(MemoryPressure(level: 2), .warning)
        XCTAssertEqual(MemoryPressure(level: 4), .critical)
    }

    func testBatteryHealth() {
        XCTAssertEqual(SystemStats.healthPercent(rawMax: 6247, design: 6249)!, 99.97, accuracy: 0.01)
        XCTAssertEqual(SystemStats.healthPercent(rawMax: 7000, design: 6249), 100, "capped at 100")
        XCTAssertNil(SystemStats.healthPercent(rawMax: nil, design: 6249))
    }

    func testOnlyOwnAppsCanBeQuit() {
        let me = getuid()
        XCTAssertNil(ProcessActions.refusal(pid: 999_999, uid: me, isApp: true))
        XCTAssertNotNil(ProcessActions.refusal(pid: 999_999, uid: me, isApp: false), "background process")
        XCTAssertNotNil(ProcessActions.refusal(pid: 999_999, uid: 0, isApp: true), "owned by root")
        XCTAssertNotNil(ProcessActions.refusal(pid: getpid(), uid: me, isApp: true), "CleanMac itself")
    }
}

final class StartupItemsTests: XCTestCase {
    func testParsesLaunchAgentPlist() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        let plist: [String: Any] = [
            "Label": "com.example.agent",
            "ProgramArguments": ["/Applications/Example.app/Contents/MacOS/helper", "--quiet"],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)

        let item = try XCTUnwrap(StartupItems.parse(plistAt: url, scope: .user))
        XCTAssertEqual(item.label, "com.example.agent")
        XCTAssertEqual(item.program, "/Applications/Example.app/Contents/MacOS/helper")
        XCTAssertEqual(item.appPath, "/Applications/Example.app")
    }

    func testEmptyPlistIsListedAsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "com.old.updater.plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0).write(to: url)

        let item = try XCTUnwrap(StartupItems.parse(plistAt: url, scope: .user))
        XCTAssertTrue(item.isEmpty)
        XCTAssertEqual(item.label, "com.old.updater")
    }

    func testParsesLaunchctlOutput() {
        let disabled = StartupItems.parseDisabled("""
        	disabled services = {
        		"com.docker.helper" => enabled
        		"com.example.off" => disabled
        	}
        """)
        XCTAssertEqual(disabled, ["com.docker.helper": false, "com.example.off": true])

        let jobs = StartupItems.parseList("PID\tStatus\tLabel\n279\t0\tcom.example.running\n-\t0\tcom.example.loaded\n")
        XCTAssertEqual(jobs["com.example.running"], 279)
        XCTAssertEqual(jobs["com.example.loaded"], .some(nil))
        XCTAssertNil(jobs["com.example.missing"] as Int??)
    }

    func testParsesLoginItemsReportAndSkipsApple() {
        let report = """
        ========================
         Records for UID 501 : 1234
        ========================
         #1:
                         Name: Docker
               Developer Name: Docker Inc
                         Type: app (0x2)
                  Disposition: [enabled, allowed, visible, notified] (0xb)
                          URL: file:///Applications/Docker.app/
            Bundle Identifier: com.docker.docker
         #2:
                         Name: Some Apple Thing
               Developer Name: Apple Inc.
                         Type: agent (0x8)
                  Disposition: [enabled, allowed] (0x3)
        ========================
         Records for UID 0 : 5678
        ========================
         #1:
                         Name: Zoom Updater
                         Type: daemon (0x10)
                  Disposition: [disabled, allowed, visible] (0x2)
              Executable Path: /Library/PrivilegedHelperTools/us.zoom.ZoomDaemon
        """
        let records = StartupItems.parseLoginItems(report)
        XCTAssertEqual(records.map(\.name), ["Docker", "Zoom Updater"])
        XCTAssertEqual(records[0].type, "app")
        XCTAssertEqual(records[0].enabled, true)
        XCTAssertEqual(records[0].location, "/Applications/Docker.app/")
        XCTAssertFalse(records[0].forAllUsers)
        XCTAssertEqual(records[1].enabled, false)
        XCTAssertTrue(records[1].forAllUsers)
    }
}
