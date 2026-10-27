import Foundation
import XCTest
@testable import DeleteCore

/// One test per evidence rule in CLAUDE.md not already covered by FinderTests.
final class RuleTests: XCTestCase {
    func makeExample(_ system: FakeSystem) throws -> URL {
        let bundle = try system.makeApp("Example.app", metadata: ["CFBundleIdentifier": "com.example.app", "CFBundleExecutable": "Example"])
        try system.makeApp("Example.app/Contents/PlugIns/Share.appex", metadata: ["CFBundleIdentifier": "com.example.app.Share"])
        return bundle
    }

    func relative(_ findings: [Finding], _ system: FakeSystem, tier: EvidenceTier) -> Set<String> {
        Set(findings.filter { $0.tier == tier }.map { $0.path.replacingOccurrences(of: system.root.path + "/", with: "") })
    }

    func testTheRemainingIdentifierFolders() throws {
        let system = try FakeSystem()
        try makeExample(system)
        let lib = "Users/tester/Library"
        let expected = [
            "\(lib)/HTTPStorages/com.example.app",
            "\(lib)/WebKit/com.example.app",
            "\(lib)/Logs/com.example.app",
            "\(lib)/Application Scripts/com.example.app.Share",
            "\(lib)/Autosave Information/com.example.app",
            "\(lib)/SyncedPreferences/com.example.app.plist",
            "\(lib)/Input Methods/com.example.app.app",
            "\(lib)/Caches/com.example.app.ShipIt",
            "\(lib)/Caches/com.plausiblelabs.crashreporter.data/com.example.app",
            "private/var/folders/zz/hash/T/com.example.app",
            "Library/Application Support/com.example.app",
            "Library/Caches/com.example.app",
            "Library/Logs/com.example.app",
            "Library/Input Methods/com.example.app.app",
            "Library/Receipts/com.example.app.bom",
            "Library/Receipts/com.example.app.plist",
        ]
        for path in expected { try system.touch(path.hasSuffix(".plist") || path.hasSuffix(".bom") ? path : path + "/") }
        // Look-alikes that aren't the app's.
        try system.touch("\(lib)/WebKit/com.example.application/")
        try system.touch("\(lib)/Logs/com.example/")
        try system.touch("\(lib)/Caches/com.plausiblelabs.crashreporter.data/com.other.app/")

        let exact = relative(try system.plan("Example").findings, system, tier: .exact)
        XCTAssertEqual(exact, Set(expected + ["Applications/Example.app"]))
    }

    /// `<bundle id>.*` stops being the app's once another installed app's identifier starts with
    /// `<bundle id>.`, but the exact name and the app's own suffixes still are.
    func testSubIdentifierItemsYieldToAnotherInstalledApp() throws {
        let system = try FakeSystem()
        try makeExample(system)
        try system.makeApp("Example Pro.app", metadata: ["CFBundleIdentifier": "com.example.app.pro"])
        try system.touch("Users/tester/Library/Caches/com.example.app/")
        try system.touch("Users/tester/Library/Caches/com.example.app.pro/")
        try system.touch("Users/tester/Library/Caches/com.example.app.pro.helper/")
        try system.touch("Users/tester/Library/Containers/com.example.app.Share/")

        let exact = relative(try system.plan("Example").findings, system, tier: .exact)
        XCTAssertTrue(exact.contains("Users/tester/Library/Caches/com.example.app"))
        XCTAssertTrue(exact.contains("Users/tester/Library/Containers/com.example.app.Share"), "the embedded extension's own identifier")
        XCTAssertFalse(exact.contains { $0.contains("com.example.app.pro") }, "\(exact)")
    }

    func testBrowserNativeMessagingManifestsPointingIntoTheApp() throws {
        let system = try FakeSystem()
        let bundle = try makeExample(system)
        let proxy = bundle.appending(path: "Contents/MacOS/example-proxy").path
        let support = "Users/tester/Library/Application Support"
        let ours = [
            "\(support)/Google/Chrome/NativeMessagingHosts/com.example.browser.json",
            "\(support)/Chromium/NativeMessagingHosts/com.example.browser.json",
            "\(support)/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.example.browser.json",
            "\(support)/Arc/User Data/NativeMessagingHosts/com.example.browser.json",
            "\(support)/Mozilla/NativeMessagingHosts/com.example.browser.json",
            "Library/Google/Chrome/NativeMessagingHosts/com.example.browser.json",
            "Library/Application Support/Mozilla/NativeMessagingHosts/com.example.browser.json",
        ]
        for path in ours { try system.writeJSON(["name": "com.example.browser", "path": proxy, "type": "stdio"], to: system.root.appending(path: path)) }
        let hosts = system.root.appending(path: "\(support)/Google/Chrome/NativeMessagingHosts")
        try system.writeJSON(["name": "com.other", "path": "/Applications/Other.app/Contents/MacOS/proxy"], to: hosts.appending(path: "com.other.json"))
        try system.writeJSON(["name": "com.sneaky", "path": bundle.path + "/../Other.app/Contents/MacOS/proxy"], to: hosts.appending(path: "com.sneaky.json"))
        try system.writeJSON(["name": "com.prefix", "path": bundle.path + " Pro.app/Contents/MacOS/proxy"], to: hosts.appending(path: "com.prefix.json"))
        try system.write("{ not json", to: hosts.appending(path: "broken.json"))

        let plan = try system.plan("Example")
        let exact = relative(plan.findings, system, tier: .exact)
        XCTAssertEqual(exact, Set(ours + ["Applications/Example.app"]))
        XCTAssertTrue(plan.findings.filter { $0.path.hasSuffix(".json") }.allSatisfy { $0.reason == "browser native messaging host" })
    }

    func testAppGroupsFromTheEntitlementsUnlessAnotherAppSharesThem() throws {
        let system = try FakeSystem()
        // No extension: codesign won't sign an app whose extension has no executable.
        let bundle = try system.makeApp("Example.app", metadata: ["CFBundleIdentifier": "com.example.app"])
        try system.sign(bundle, applicationGroups: ["ABCDE12345.com.example.shared", "group.com.example.app", "ABCDE12345.com.example.own"])
        let other = try system.makeApp("Other.app", metadata: ["CFBundleIdentifier": "com.example.other"])
        try system.sign(other, applicationGroups: ["ABCDE12345.com.example.shared"])
        let lib = "Users/tester/Library"
        try system.touch("\(lib)/Group Containers/group.com.example.app/data")
        try system.touch("\(lib)/Group Containers/abcde12345.com.example.own/data")
        try system.touch("\(lib)/Group Containers/ABCDE12345.com.example.shared/data")
        try system.touch("\(lib)/Application Scripts/group.com.example.app/")
        try system.touch("\(lib)/Group Containers/group.com.example.unrelated/")

        let plan = try system.plan("Example")
        let exact = relative(plan.findings, system, tier: .exact)
        XCTAssertTrue(exact.isSuperset(of: ["\(lib)/Group Containers/group.com.example.app", "\(lib)/Group Containers/abcde12345.com.example.own", "\(lib)/Application Scripts/group.com.example.app"]), "\(exact)")
        XCTAssertFalse(exact.contains { $0.contains("shared") || $0.contains("unrelated") }, "\(exact)")
        XCTAssertTrue(plan.skipped.contains { $0.path.hasSuffix("ABCDE12345.com.example.shared") && $0.reason == "app group shared with Other" }, "\(plan.skipped)")
    }

    func testCrashReporterAndSentryNameEvidence() throws {
        let system = try FakeSystem()
        try makeExample(system)
        let lib = "Users/tester/Library"
        try system.touch("\(lib)/Caches/SentryCrash/Example/")
        try system.touch("\(lib)/Application Support/CrashReporter/Example_00000000-1111-2222-3333-444444444444.plist")
        try system.touch("\(lib)/Application Support/CrashReporter/ExampleOther_00000000-1111-2222-3333-444444444444.plist")

        let plan = try system.plan("Example")
        XCTAssertEqual(relative(plan.findings, system, tier: .name), ["\(lib)/Caches/SentryCrash/Example", "\(lib)/Application Support/CrashReporter/Example_00000000-1111-2222-3333-444444444444.plist"])
        XCTAssertTrue(plan.selected(includeNameMatches: false).allSatisfy { $0.tier == .exact })
    }

    /// Without Full Disk Access, macOS refuses to list other apps' containers. That must read as
    /// "couldn't look", never as "nothing there".
    func testAnUnreadableFolderIsReportedNotTakenAsEmpty() throws {
        let system = try FakeSystem()
        try makeExample(system)
        let containers = try system.touch("Users/tester/Library/Containers/")
        try system.touch("Users/tester/Library/Containers/com.example.app/")
        XCTAssertEqual(chmod(containers.path, 0o000), 0)
        defer { chmod(containers.path, 0o755) }
        let plan = try system.plan("Example")
        XCTAssertTrue(plan.unreadable.contains(containers.path), "\(plan.unreadable)")
        XCTAssertTrue(PlanRenderer.text(plan, includeNameMatches: false, isRoot: false, home: system.home).contains("Grant Full Disk Access to your terminal"))
    }

    /// Unity's placeholder identifier is shared by unrelated games, so it finds nothing.
    func testPlaceholderIdentifiersAreNoEvidence() throws {
        let system = try FakeSystem()
        try system.makeApp("Comet.app", metadata: ["CFBundleIdentifier": "com.Company.ProductName"])
        try system.touch("Users/tester/Library/Preferences/com.Company.ProductName.plist")
        try system.touch("Users/tester/Library/Application Support/Comet/")
        let plan = try system.plan("Comet")
        XCTAssertEqual(relative(plan.findings, system, tier: .exact), ["Applications/Comet.app"])
        XCTAssertEqual(relative(plan.findings, system, tier: .name), ["Users/tester/Library/Application Support/Comet"])
        XCTAssertTrue(plan.identifiers.isEmpty, "no privacy reset or quit by a shared identifier")
        XCTAssertTrue(plan.notes.contains { $0.contains("placeholder") })
        XCTAssertFalse(EvidenceFinder.isPlaceholder("com.company.productnamepro"))
        XCTAssertTrue(EvidenceFinder.isPlaceholder("unity.DefaultCompany.MyGame"))
    }

    /// A matched item's folder is never selected, even when everything in it matched.
    func testTheFolderHoldingAMatchIsNeverSelected() throws {
        let system = try FakeSystem()
        try makeExample(system)
        try system.touch("Users/tester/Library/Caches/com.plausiblelabs.crashreporter.data/com.example.app/")
        try system.touch("Users/tester/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.example.app.sfl4")
        let paths = try system.plan("Example").findings.map(\.path)
        for folder in ["Caches/com.plausiblelabs.crashreporter.data", "Application Support/com.apple.sharedfilelist", "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"] {
            XCTAssertFalse(paths.contains(system.userLibrary.appending(path: folder).path), folder)
        }
    }

    /// Links on the PATH into the app's bundle go with it; anything else in those folders stays.
    func testCommandLineLinksIntoTheApp() throws {
        let system = try FakeSystem()
        let bundle = try makeExample(system)
        try system.write("bin", to: bundle.appending(path: "Contents/MacOS/example-cli"))
        let other = try system.makeApp("Other.app", metadata: ["CFBundleIdentifier": "com.other.app"])
        try system.write("bin", to: other.appending(path: "Contents/MacOS/other"))
        let bins = [system.root.appending(path: "usr/local/bin"), system.homebrew.appending(path: "bin"), system.home.appending(path: ".local/bin")]
        for folder in bins { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: bins[0].appending(path: "example"), withDestinationURL: bundle.appending(path: "Contents/MacOS/example-cli"))
        try FileManager.default.createSymbolicLink(at: bins[1].appending(path: "example2"), withDestinationURL: bundle.appending(path: "Contents/MacOS/example-cli"))
        try FileManager.default.createSymbolicLink(at: bins[2].appending(path: "chain"), withDestinationURL: bins[0].appending(path: "example"))
        try FileManager.default.createSymbolicLink(at: bins[0].appending(path: "other"), withDestinationURL: other.appending(path: "Contents/MacOS/other"))
        try FileManager.default.createSymbolicLink(at: bins[0].appending(path: "dangling"), withDestinationURL: system.root.appending(path: "gone"))
        try system.write("copy", to: bins[0].appending(path: "example-copy"))

        let plan = try system.plan("Example")
        XCTAssertEqual(Set(plan.findings.filter { $0.reason == "command-line link into the app" }.map { URL(filePath: $0.path).lastPathComponent }), ["example", "example2", "chain"])
        let report = Executor(actions: RecordingSystemActions(), allowedRoot: system.root.path, home: system.home)
            .run(plan, targets: Executor.targets(for: plan.selected(includeNameMatches: false)), isRoot: false, casks: [])
        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertNotNil(FileIdentity.of(bins[0].appending(path: "other").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bins[0].appending(path: "example-copy").path))
    }

    /// Plug-ins outside the bundle, by their own identifier.
    func testInstalledPluginsByTheirOwnIdentifier() throws {
        let system = try FakeSystem()
        try makeExample(system)
        try system.makeApp("Other.app", metadata: ["CFBundleIdentifier": "com.other.app"])
        let lib = system.userLibrary
        try system.makeApp("ExamplePreview.qlgenerator", in: lib.appending(path: "QuickLook"), metadata: ["CFBundleIdentifier": "com.example.app.quicklook"])
        try system.makeApp("Example.saver", in: lib.appending(path: "Screen Savers"), metadata: ["CFBundleIdentifier": "com.example.app.saver"])
        try system.makeApp("Example Audio.driver", in: system.library.appending(path: "Audio/Plug-Ins/HAL"), metadata: ["CFBundleIdentifier": "com.example.app.driver"])
        try system.makeApp("Example.prefPane", in: system.library.appending(path: "PreferencePanes"), metadata: ["CFBundleIdentifier": "net.thirdparty.pane"])
        try system.makeApp("Example.component", in: system.library.appending(path: "Audio/Plug-Ins/Components"), metadata: ["CFBundleIdentifier": "com.other.app.component"])
        try system.makeApp("Unrelated.qlgenerator", in: lib.appending(path: "QuickLook"), metadata: ["CFBundleIdentifier": "com.unrelated.ql"])
        try FileManager.default.createSymbolicLink(at: lib.appending(path: "QuickLook/Linked.qlgenerator"), withDestinationURL: lib.appending(path: "QuickLook/ExamplePreview.qlgenerator"))

        let plan = try system.plan("Example")
        let byName = Dictionary(plan.findings.map { (URL(filePath: $0.path).lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byName["ExamplePreview.qlgenerator"]?.tier, .exact)
        XCTAssertEqual(byName["ExamplePreview.qlgenerator"]?.reason, "QuickLook plug-in")
        XCTAssertEqual(byName["Example.saver"]?.tier, .exact)
        XCTAssertEqual(byName["Example Audio.driver"]?.reason, "audio driver")
        XCTAssertEqual(byName["Example.prefPane"]?.tier, .name, "named after the app, someone else's identifier: shown only")
        XCTAssertNil(byName["Example.component"], "another installed app's plug-in, even named after this one")
        XCTAssertTrue(plan.skipped.contains { $0.path.hasSuffix("Example.component") })
        XCTAssertNil(byName["Unrelated.qlgenerator"])
        XCTAssertNil(byName["Linked.qlgenerator"], "a link isn't read as a bundle")
    }

    func testHelpCachesAndOtherPerAppSystemFolders() throws {
        let system = try FakeSystem()
        try makeExample(system)
        let lib = "Users/tester/Library"
        let expected = ["\(lib)/Caches/com.apple.helpd/Generated/com.example.app.help*1.2", "\(lib)/Caches/com.apple.nsurlsessiond/Downloads/com.example.app",
                        "\(lib)/WebKit/Databases/___IndexedDB/com.example.app", "\(lib)/Preferences/com.apple.FileProvider/com.example.app.Share"]
        for path in expected { try system.touch(path + "/") }
        try system.touch("\(lib)/Caches/com.apple.helpd/Generated/com.other.help*1.0/")
        let exact = relative(try system.plan("Example").findings, system, tier: .exact)
        XCTAssertTrue(exact.isSuperset(of: expected), "\(exact)")
        XCTAssertFalse(exact.contains { $0.contains("com.other") })
        for folder in ["Caches/com.apple.helpd", "Caches/com.apple.helpd/Generated", "Preferences/com.apple.FileProvider", "Audio/Plug-Ins/HAL", "CoreMediaIO/Plug-Ins/DAL"] {
            XCTAssertTrue(Protection.isProtected(system.userLibrary.appending(path: folder).path, roots: system.roots), folder)
        }
        XCTAssertFalse(Protection.isProtected(system.userLibrary.appending(path: "Caches/com.apple.dt.Xcode").path, roots: system.roots), "a removable Apple app's own caches")
    }
}
