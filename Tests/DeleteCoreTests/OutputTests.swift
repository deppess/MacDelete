import Darwin
import Foundation
import XCTest
@testable import DeleteCore

final class FormatTests: XCTestCase {
    func testSizes() {
        XCTAssertEqual(Format.size(0), "0 B")
        XCTAssertEqual(Format.size(999), "999 B")
        XCTAssertEqual(Format.size(4_096), "4 KB")
        XCTAssertEqual(Format.size(999_499), "999 KB")
        XCTAssertEqual(Format.size(999_600), "1.0 MB")
        XCTAssertEqual(Format.size(1_800_000), "1.8 MB")
        XCTAssertEqual(Format.size(12_000_000), "12 MB")
        XCTAssertEqual(Format.size(312_400_000), "312 MB")
        XCTAssertEqual(Format.size(4_200_000_000), "4.2 GB")
    }

    func testHomeIsShownAsTilde() {
        let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
        XCTAssertEqual(Format.path("/Users/tester/Library/Caches/x", home: home), "~/Library/Caches/x")
        XCTAssertEqual(Format.path("/Users/tester", home: home), "~")
        XCTAssertEqual(Format.path("/Users/testers/x", home: home), "/Users/testers/x")
    }
}

final class DiskUsageTests: XCTestCase {
    func testHardLinksCountOnceAndLinksAreNotFollowed() throws {
        let system = try FakeSystem()
        let folder = system.root.appending(path: "measure", directoryHint: .isDirectory)
        try system.write(String(repeating: "a", count: 100_000), to: folder.appending(path: "file"))
        XCTAssertEqual(link(folder.appending(path: "file").path, folder.appending(path: "hardlink").path), 0)
        try system.write(String(repeating: "b", count: 500_000), to: system.root.appending(path: "outside"))
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "symlink"), withDestinationURL: system.root.appending(path: "outside"))

        let usage = DiskUsage.allocatedSize(of: folder.path)
        let (bytes, complete) = (usage.bytes, usage.complete)
        XCTAssertTrue(complete)
        XCTAssertGreaterThanOrEqual(bytes, 100_000)
        XCTAssertLessThan(bytes, 200_000, "the hard link and the symlink's target aren't counted again")
    }
}

final class CLITests: XCTestCase {
    func testParsesCommands() throws {
        XCTAssertEqual(try Invocation(arguments: []).command, .help)
        XCTAssertEqual(try Invocation(arguments: ["list"]).command, .list)
        let listing = try Invocation(arguments: ["list", "--json", "--all"])
        XCTAssertTrue(listing.json && listing.all)
        let removal = try Invocation(arguments: ["Raycast", "--dry-run", "-y"])
        XCTAssertEqual(removal.command, .remove("Raycast"))
        XCTAssertTrue(removal.dryRun && removal.assumeYes && removal.includeNameMatches)
        XCTAssertEqual(try Invocation(arguments: ["--", "list"]).command, .remove("list"), "an app named list")
        XCTAssertEqual(try Invocation(arguments: ["list", "--help"]).command, .help)
        XCTAssertThrowsError(try Invocation(arguments: ["list", "Raycast"]))
        XCTAssertThrowsError(try Invocation(arguments: ["list", "-y"]))
        XCTAssertThrowsError(try Invocation(arguments: ["Raycast", "Slack"]))
        XCTAssertThrowsError(try Invocation(arguments: ["Raycast", "--all"]))
        XCTAssertThrowsError(try Invocation(arguments: ["--force"]))
    }

    func testListTextAndJSON() throws {
        var raycast = app("Raycast", id: "com.raycast.macos")
        raycast.version = "1.98.2"
        raycast.size = 312_400_000
        raycast.source = .homebrew(token: "raycast", declared: true)
        var alt = app("AltTab", id: "com.lwouis.alt-tab-macos")
        alt.size = 12_000_000
        let text = ListRenderer.text([alt, raycast], home: URL(filePath: "/Users/tester"))
        XCTAssertEqual(text, """
        AltTab              12 MB   Download
        Raycast   1.98.2   312 MB   Homebrew (raycast)

        2 apps, 324 MB
        """)

        let json = try JSONSerialization.jsonObject(with: Data(try ListRenderer.json([raycast], warnings: []).utf8)) as? [String: Any]
        let entry = try XCTUnwrap((json?["applications"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["source"] as? String, "homebrew")
        XCTAssertEqual(entry["homebrewCask"] as? String, "raycast")
        XCTAssertEqual(entry["size"] as? Int, 312_400_000)
        XCTAssertEqual(entry["bundleIdentifier"] as? String, "com.raycast.macos")
    }

    func testNamesAreSanitizedForTheTerminal() {
        let text = ListRenderer.text([app("Evil\u{1B}]0;title\u{07}App")], home: URL(filePath: "/Users/tester"))
        XCTAssertFalse(text.contains("\u{1B}"))
        XCTAssertTrue(text.hasPrefix("EvilApp"))
    }

    /// Every path lines up when nothing limits the width; on a narrow terminal the column stops
    /// where the sizes still fit, and longer paths run past it.
    func testPlanColumnsFollowTheWidth() throws {
        let system = try FakeSystem()
        try system.makeApp("Example.app", metadata: ["CFBundleIdentifier": "com.example.app"])
        try system.touch("Users/tester/Library/Preferences/com.example.app.plist")
        try system.touch("Users/tester/Library/Application Support/Google/Chrome/NativeMessagingHosts/a-very-long-manifest-name-for-the-example-app.json")
        try system.writeJSON(["path": system.applications.appending(path: "Example.app/Contents/MacOS/proxy").path], to: system.home.appending(path: "Library/Application Support/Google/Chrome/NativeMessagingHosts/a-very-long-manifest-name-for-the-example-app.json"))
        let plan = try system.plan("Example")
        let rows = { (width: Int?) in PlanRenderer.text(plan, includeNameMatches: false, isRoot: false, home: system.home, width: width).split(separator: "\n").filter { $0.hasPrefix("  /") || $0.hasPrefix("  ~") } }
        let sizeColumns = Set(rows(nil).map { row in row.range(of: " KB")?.lowerBound.utf16Offset(in: row) ?? row.range(of: " B")?.lowerBound.utf16Offset(in: row) ?? -1 })
        XCTAssertEqual(sizeColumns.count, 1, "aligned: \(rows(nil))")
        XCTAssertTrue(rows(60).contains { $0.count > 60 }, "a long path runs past a narrow terminal rather than being cut")
    }

    func testProtectedItemsSayWhyTheyStay() throws {
        let system = try FakeSystem()
        XCTAssertTrue(Protection.protectedReason(system.home.appending(path: "Library/Application Support/Steam").path, roots: system.roots).hasPrefix("Steam's own folder"))
        XCTAssertEqual(Protection.protectedReason(system.home.appending(path: "Documents/Example").path, roots: system.roots), "in your documents")
        XCTAssertEqual(Protection.protectedReason(system.home.appending(path: "Library/Caches").path, roots: system.roots), "protected location")
    }
}
