import XCTest
@testable import CleanMac

final class AdminHelperTests: XCTestCase {
    /// Paths come from the file system and can contain anything; they must stay single shell arguments.
    func testShellCommandQuotesEveryPath() {
        let command = AdminHelper.shellCommand(for: ["/var/a b", "/var/it's", "/var/x\"; rm -rf /"])
        XCTAssertEqual(
            command,
            #"/usr/bin/du -sk '/var/a b' '/var/it'\''s' '/var/x"; rm -rf /' 2>/dev/null; true"#
        )
    }

    func testAppleScriptEscapesQuotesAndBackslashes() {
        let script = AdminHelper.appleScript(for: [#"/var/x"y\z"#])
        XCTAssertTrue(script.hasPrefix(#"do shell script "/usr/bin/du -sk '/var/x\"y\\z'"#))
        XCTAssertTrue(script.contains("with administrator privileges"))
    }

    func testParsesDuOutputIntoBytes() {
        let sizes = AdminHelper.parse("12\t/private/var/root\n0\t/private/var/spool/cups\n")
        XCTAssertEqual(sizes, ["/private/var/root": 12 * 1024, "/private/var/spool/cups": 0])
    }
}
