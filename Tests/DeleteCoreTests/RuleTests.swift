import Foundation
import XCTest
@testable import DeleteCore

/// One test per evidence rule not already covered by FinderTests.
final class RuleTests: XCTestCase {
    func makeExample(_ system: FakeSystem) throws -> URL {
        let bundle = try system.makeApp("Example.app", metadata: ["CFBundleIdentifier": "com.example.app", "CFBundleExecutable": "Example"])
        try system.makeApp("Example.app/Contents/PlugIns/Share.appex", metadata: ["CFBundleIdentifier": "com.example.app.Share"])
        return bundle
    }

    func testTheRemainingIdentifierFolders() throws {
        let system = try FakeSystem()
        _ = try makeExample(system)
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
            "Library/Receipts/com.example.app.plist"
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
        _ = try makeExample(system)
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
            "Library/Application Support/Mozilla/NativeMessagingHosts/com.example.browser.json"
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
        XCTAssertTrue(
            exact.isSuperset(of: [
                "\(lib)/Group Containers/group.com.example.app", "\(lib)/Group Containers/abcde12345.com.example.own",
                "\(lib)/Application Scripts/group.com.example.app"
            ]), "\(exact)")
        XCTAssertFalse(exact.contains { $0.contains("shared") || $0.contains("unrelated") }, "\(exact)")
        XCTAssertTrue(
            plan.skipped.contains { $0.path.hasSuffix("ABCDE12345.com.example.shared") && $0.reason == "app group shared with Other" }, "\(plan.skipped)")
    }

    func testCrashReporterAndSentryNameEvidence() throws {
        let system = try FakeSystem()
        _ = try makeExample(system)
        let lib = "Users/tester/Library"
        try system.touch("\(lib)/Caches/SentryCrash/Example/")
        try system.touch("\(lib)/Application Support/CrashReporter/Example_00000000-1111-2222-3333-444444444444.plist")
        try system.touch("\(lib)/Application Support/CrashReporter/ExampleOther_00000000-1111-2222-3333-444444444444.plist")

        let plan = try system.plan("Example")
        XCTAssertEqual(
            relative(plan.findings, system, tier: .name),
            ["\(lib)/Caches/SentryCrash/Example", "\(lib)/Application Support/CrashReporter/Example_00000000-1111-2222-3333-444444444444.plist"])
        XCTAssertTrue(plan.selected().contains { $0.tier == .name })
    }

    /// Without Full Disk Access, macOS refuses to list other apps' containers. That must read as
    /// "couldn't look", never as "nothing there".
    func testAnUnreadableFolderIsReportedNotTakenAsEmpty() throws {
        let system = try FakeSystem()
        _ = try makeExample(system)
        let containers = try system.touch("Users/tester/Library/Containers/")
        try system.touch("Users/tester/Library/Containers/com.example.app/")
        XCTAssertEqual(chmod(containers.path, 0o000), 0)
        defer { chmod(containers.path, 0o755) }
        let plan = try system.plan("Example")
        XCTAssertTrue(plan.unreadable.contains(containers.path), "\(plan.unreadable)")
        XCTAssertTrue(PlanRenderer.text(plan, isRoot: false, home: system.home).contains("Grant Full Disk Access to your terminal"))
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
        _ = try makeExample(system)
        try system.touch("Users/tester/Library/Caches/com.plausiblelabs.crashreporter.data/com.example.app/")
        try system.touch(
            "Users/tester/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.example.app.sfl4")
        let paths = try system.plan("Example").findings.map(\.path)
        for folder in [
            "Caches/com.plausiblelabs.crashreporter.data", "Application Support/com.apple.sharedfilelist",
            "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
        ] {
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
        try FileManager.default.createSymbolicLink(
            at: bins[0].appending(path: "example"), withDestinationURL: bundle.appending(path: "Contents/MacOS/example-cli"))
        try FileManager.default.createSymbolicLink(
            at: bins[1].appending(path: "example2"), withDestinationURL: bundle.appending(path: "Contents/MacOS/example-cli"))
        try FileManager.default.createSymbolicLink(at: bins[2].appending(path: "chain"), withDestinationURL: bins[0].appending(path: "example"))
        try FileManager.default.createSymbolicLink(at: bins[0].appending(path: "other"), withDestinationURL: other.appending(path: "Contents/MacOS/other"))
        try FileManager.default.createSymbolicLink(at: bins[0].appending(path: "dangling"), withDestinationURL: system.root.appending(path: "gone"))
        try system.write("copy", to: bins[0].appending(path: "example-copy"))
        try system.write("bin", to: bins[2].appending(path: "Example"), executable: true)

        let plan = try system.plan("Example")
        XCTAssertEqual(
            Set(plan.findings.filter { $0.reason == "command-line link into the app" }.map { URL(filePath: $0.path).lastPathComponent }),
            ["example", "example2", "chain"])
        XCTAssertEqual(
            plan.findings.filter { $0.reason == "command-line executable named after the app" }.map(\.path), [bins[2].appending(path: "Example").path])
        let report = Executor(actions: RecordingSystemActions(), allowedRoot: system.root.path, home: system.home)
            .run(plan, targets: Executor.targets(for: plan.selected()), isRoot: false, casks: [])
        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertNotNil(FileIdentity.of(bins[0].appending(path: "other").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bins[0].appending(path: "example-copy").path))
        XCTAssertNil(FileIdentity.of(bins[2].appending(path: "Example").path), "the displayed name-derived command is removed too")
    }

    /// Plug-ins outside the bundle, by their own identifier.
    func testInstalledPluginsByTheirOwnIdentifier() throws {
        let system = try FakeSystem()
        _ = try makeExample(system)
        try system.makeApp("Other.app", metadata: ["CFBundleIdentifier": "com.other.app"])
        let lib = system.userLibrary
        try system.makeApp("ExamplePreview.qlgenerator", in: lib.appending(path: "QuickLook"), metadata: ["CFBundleIdentifier": "com.example.app.quicklook"])
        try system.makeApp("Example.saver", in: lib.appending(path: "Screen Savers"), metadata: ["CFBundleIdentifier": "com.example.app.saver"])
        try system.makeApp(
            "Example Audio.driver", in: system.library.appending(path: "Audio/Plug-Ins/HAL"), metadata: ["CFBundleIdentifier": "com.example.app.driver"])
        try system.makeApp("Example.prefPane", in: system.library.appending(path: "PreferencePanes"), metadata: ["CFBundleIdentifier": "net.thirdparty.pane"])
        try system.makeApp(
            "Example.component", in: system.library.appending(path: "Audio/Plug-Ins/Components"), metadata: ["CFBundleIdentifier": "com.other.app.component"])
        try system.makeApp("Unrelated.qlgenerator", in: lib.appending(path: "QuickLook"), metadata: ["CFBundleIdentifier": "com.unrelated.ql"])
        try FileManager.default.createSymbolicLink(
            at: lib.appending(path: "QuickLook/Linked.qlgenerator"), withDestinationURL: lib.appending(path: "QuickLook/ExamplePreview.qlgenerator"))

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
        _ = try makeExample(system)
        let lib = "Users/tester/Library"
        let expected = [
            "\(lib)/Caches/com.apple.helpd/Generated/com.example.app.help*1.2", "\(lib)/Caches/com.apple.nsurlsessiond/Downloads/com.example.app",
            "\(lib)/WebKit/Databases/___IndexedDB/com.example.app", "\(lib)/Preferences/com.apple.FileProvider/com.example.app.Share"
        ]
        for path in expected { try system.touch(path + "/") }
        try system.touch("\(lib)/Caches/com.apple.helpd/Generated/com.other.help*1.0/")
        let exact = relative(try system.plan("Example").findings, system, tier: .exact)
        XCTAssertTrue(exact.isSuperset(of: expected), "\(exact)")
        XCTAssertFalse(exact.contains { $0.contains("com.other") })
        for folder in [
            "Caches/com.apple.helpd", "Caches/com.apple.helpd/Generated", "Preferences/com.apple.FileProvider", "Audio/Plug-Ins/HAL", "CoreMediaIO/Plug-Ins/DAL"
        ] {
            XCTAssertTrue(Protection.isProtected(system.userLibrary.appending(path: folder).path, roots: system.roots), folder)
        }
        XCTAssertFalse(
            Protection.isProtected(system.userLibrary.appending(path: "Caches/com.apple.dt.Xcode").path, roots: system.roots),
            "a removable Apple app's own caches")
    }

    func testXDGSystemSharedAndHelpNameEvidence() throws {
        let system = try FakeSystem()
        try system.makeApp("Example.app", metadata: ["CFBundleIdentifier": "com.example.app", "CFBundleExecutable": "Example"])
        let paths = [
            "Users/tester/.example/", "Users/tester/Example/", "Users/tester/.local/share/example/", "Users/tester/.cache/Example/",
            "Users/tester/.local/state/example/", "Library/Application Support/Example/",
            "Library/Logs/Example 2/", "Users/Shared/Example/", "Users/tester/Library/Caches/com.apple.helpd/Generated/Example Help*1.0/",
            "Library/Logs/DiagnosticReports/Example_2026-10-26-101010_mac.diag"
        ]
        for path in paths { try system.touch(path) }
        try system.touch("Users/tester/.local/share/other/")
        let plan = try system.plan("Example")
        XCTAssertEqual(relative(plan.findings, system, tier: .name), Set(paths.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }))
        XCTAssertEqual(
            Set(plan.selected().filter { $0.tier == .name }.map(\.path)), Set(plan.findings.filter { $0.tier == .name }.map(\.path)),
            "every displayed name finding is selected")
        XCTAssertEqual(plan.findings.first { $0.path.hasSuffix("Users/Shared/Example") }?.reason, "named after the app, shared by all users")
        XCTAssertEqual(plan.findings.first { $0.path.hasSuffix("Users/tester/Example") }?.reason, "named after the app; may hold your own files")
        for folder in [".local/share", ".local/state", ".local/bin", ".cache", "bin"] {
            XCTAssertTrue(Protection.isProtected(system.home.appending(path: folder).path, roots: system.roots), folder)
        }
    }

    /// Products inside a vendor's folder, named by the app; never the vendor folder.
    func testVendorFolders() throws {
        let system = try FakeSystem()
        try system.makeApp("IntelliJ IDEA.app", metadata: ["CFBundleIdentifier": "com.jetbrains.intellij"])
        try system.makeApp("Google Chrome.app", metadata: ["CFBundleIdentifier": "com.google.Chrome"])
        try system.makeApp("Brave Browser.app", metadata: ["CFBundleIdentifier": "com.brave.Browser"])
        try system.makeApp("Google Drive.app", metadata: ["CFBundleIdentifier": "com.google.drivefs"])
        let support = "Users/tester/Library/Application Support"
        for path in [
            "\(support)/JetBrains/IntelliJIdea2026.2/", "\(support)/JetBrains/IntelliJIdea2025.3/", "\(support)/JetBrains/PyCharm2026.1/",
            "Users/tester/Library/Caches/JetBrains/IntelliJIdea2026.2/",
            "\(support)/Google/Chrome/", "\(support)/Google/Drive/", "\(support)/Google/Chrome Canary/", "\(support)/BraveSoftware/Brave-Browser/",
            "\(support)/BraveSoftware/Brave-Origin/",
            "Users/tester/Library/Logs/JetBrains/IntelliJIdea2026.2/"
        ] {
            try system.touch(path)
        }
        func names(_ app: String) throws -> Set<String> { relative(try system.plan(app).findings, system, tier: .name) }
        XCTAssertEqual(
            try names("IntelliJ IDEA"),
            [
                "\(support)/JetBrains/IntelliJIdea2026.2", "\(support)/JetBrains/IntelliJIdea2025.3",
                "Users/tester/Library/Caches/JetBrains/IntelliJIdea2026.2",
                "Users/tester/Library/Logs/JetBrains/IntelliJIdea2026.2"
            ])
        XCTAssertEqual(try names("Google Chrome"), ["\(support)/Google/Chrome"], "not Chrome Canary, not Drive, never Google itself")
        XCTAssertEqual(try names("Google Drive"), ["\(support)/Google/Drive"])
        XCTAssertEqual(try names("Brave Browser"), ["\(support)/BraveSoftware/Brave-Browser"])
    }

    func testNotesForLargeDataCloudDataDockKextsAndDrivers() throws {
        let system = try FakeSystem()
        let bundle = try makeExample(system)
        var big = Finding(path: system.userLibrary.appending(path: "Containers/com.example.app").path, tier: .exact)
        big.size = 40_000_000_000
        var small = Finding(path: system.userLibrary.appending(path: "Caches/com.example.app").path, tier: .exact)
        small.size = 40_000_000_000
        XCTAssertEqual(PlanNotes.largeData([big, small], roots: system.roots).count, 1, "only data folders, not caches")

        try system.touch("Users/tester/Library/Mobile Documents/iCloud~com~example~app/Documents/notes.txt")
        try system.touch("Users/tester/Library/Mobile Documents/iCloud~com~other~app/")
        try system.touch("Users/tester/Library/CloudStorage/Example-Personal/file")
        try system.touch("Users/tester/Library/CloudStorage/Dropbox/file")
        try system.writePlist(
            ["persistent-apps": [["tile-data": ["file-data": ["_CFURLString": bundle.absoluteString, "_CFURLStringType": 15]]]]],
            to: system.userLibrary.appending(path: "Preferences/com.apple.dock.plist"))
        try system.makeApp("ExampleDriver.kext", in: system.library.appending(path: "Extensions"), metadata: ["CFBundleIdentifier": "com.example.app.driver"])
        try system.makeApp("Example.driver", in: system.library.appending(path: "Audio/Plug-Ins/HAL"), metadata: ["CFBundleIdentifier": "com.example.app.hal"])

        let plan = try system.plan("Example")
        let kept = Dictionary(plan.skipped.map { (URL(filePath: $0.path).lastPathComponent, $0.reason) }, uniquingKeysWith: { first, _ in first })
        XCTAssertTrue(kept["iCloud~com~example~app"]?.contains("syncs to your other devices") ?? false, "\(kept)")
        XCTAssertNil(kept["iCloud~com~other~app"])
        XCTAssertTrue(kept["Example-Personal"]?.contains("your cloud files") ?? false)
        XCTAssertNil(kept["Dropbox"])
        XCTAssertTrue(kept["ExampleDriver.kext"]?.contains("kernel extension") ?? false)
        XCTAssertFalse(plan.selected().contains { $0.path.contains("Mobile Documents") || $0.path.contains("CloudStorage") || $0.path.hasSuffix(".kext") })
        XCTAssertTrue(plan.notes.contains { $0.contains("in your Dock") })
        XCTAssertTrue(plan.notes.contains { $0.contains("coreaudiod") })
        try system.makeApp("Example.vst3", in: system.library.appending(path: "Audio/Plug-Ins/VST3"), metadata: ["CFBundleIdentifier": "com.example.app.vst3"])
        XCTAssertTrue(try system.plan("Example").notes.contains { $0.contains("1 audio plug-in that other music apps load too") })
    }

    /// Office-style suites: a helper every app embeds stays while any of them does; the shared
    /// updater is pointed out once the last app goes.
    func testSuiteHelpersAndUpdaters() throws {
        let system = try FakeSystem()
        for app in ["Microsoft Word", "Microsoft Excel"] {
            try system.makeApp("\(app).app", metadata: ["CFBundleIdentifier": app == "Microsoft Word" ? "com.microsoft.Word" : "com.microsoft.Excel"])
            try system.makeApp(
                "\(app).app/Contents/SharedSupport/Microsoft Error Reporting.app", metadata: ["CFBundleIdentifier": "com.microsoft.errorreporting"])
        }
        // Spotlight finds it in /Library/Application Support/Microsoft/MAU2.0; the fake scan looks in Applications.
        try system.makeApp("Microsoft AutoUpdate.app", metadata: ["CFBundleIdentifier": "com.microsoft.autoupdate2"])
        try system.touch("Users/tester/Library/Containers/com.microsoft.errorreporting/")
        try system.touch("Users/tester/Library/Containers/com.microsoft.Word/")

        var plan = try system.plan("Microsoft Word")
        XCTAssertTrue(plan.findings.contains { $0.path.hasSuffix("Containers/com.microsoft.Word") })
        XCTAssertFalse(plan.findings.contains { $0.path.hasSuffix("com.microsoft.errorreporting") }, "Excel embeds it too")
        XCTAssertTrue(plan.skipped.contains { $0.path.hasSuffix("com.microsoft.errorreporting") && $0.reason.contains("Microsoft Excel") }, "\(plan.skipped)")
        XCTAssertFalse(plan.notes.contains { $0.contains("AutoUpdate") }, "Excel still needs the updater")

        try FileManager.default.removeItem(at: system.applications.appending(path: "Microsoft Excel.app"))
        plan = try system.plan("Microsoft Word")
        XCTAssertTrue(plan.findings.contains { $0.path.hasSuffix("com.microsoft.errorreporting") && $0.tier == .exact }, "the last app takes the helper's data")
        XCTAssertTrue(plan.notes.contains { $0.contains("Microsoft AutoUpdate only updates this vendor's apps") }, "\(plan.notes)")
    }

    /// Embedded helpers are identified by their own bundle identifier, not their carrier app's
    /// vendor prefix. LibreWolf and Tor Browser are a real cross-vendor example: both carry
    /// Mozilla's updater helper.
    func testCrossVendorEmbeddedHelperStaysForAnotherInstalledApp() throws {
        let system = try FakeSystem()
        try system.makeApp("LibreWolf.app", metadata: ["CFBundleIdentifier": "io.gitlab.librewolf-community"])
        try system.makeApp("LibreWolf.app/Contents/SharedSupport/Updater.app", metadata: ["CFBundleIdentifier": "org.mozilla.updater"])
        try system.makeApp("Tor Browser.app", metadata: ["CFBundleIdentifier": "org.torproject.torbrowser"])
        try system.makeApp("Tor Browser.app/Contents/SharedSupport/Updater.app", metadata: ["CFBundleIdentifier": "org.mozilla.updater"])
        try system.touch("Users/tester/Library/Caches/org.mozilla.updater/")

        let plan = try system.plan("LibreWolf")
        XCTAssertFalse(plan.findings.contains { $0.path.hasSuffix("Caches/org.mozilla.updater") }, "\(plan.findings)")
        XCTAssertTrue(plan.skipped.contains { $0.path.hasSuffix("Caches/org.mozilla.updater") && $0.reason.contains("Tor Browser") }, "\(plan.skipped)")
    }

    /// Adobe's layout: product folders inside the vendor's folders, and a "<App> Settings" folder.
    func testAdobeStyleProductFolders() throws {
        let system = try FakeSystem()
        try system.makeApp("Adobe Photoshop 2026/Adobe Photoshop 2026.app", metadata: ["CFBundleIdentifier": "com.adobe.Photoshop"])
        try system.makeApp("Adobe Illustrator 2026/Adobe Illustrator.app", metadata: ["CFBundleIdentifier": "com.adobe.illustrator"])
        let lib = "Users/tester/Library"
        for path in [
            "\(lib)/Preferences/Adobe Photoshop 2026 Settings/", "\(lib)/Application Support/Adobe/Adobe Photoshop 2026/", "\(lib)/Caches/Adobe/Photoshop/",
            "\(lib)/Application Support/Adobe/Illustrator 2026/", "\(lib)/Application Support/Adobe/CoreSync/"
        ] {
            try system.touch(path)
        }
        let names = relative(try system.plan("Adobe Photoshop 2026").findings, system, tier: .name)
        XCTAssertEqual(
            names,
            ["\(lib)/Preferences/Adobe Photoshop 2026 Settings", "\(lib)/Application Support/Adobe/Adobe Photoshop 2026", "\(lib)/Caches/Adobe/Photoshop"],
            "\(names)")
        XCTAssertTrue(
            Protection.isProtected(system.userLibrary.appending(path: "Application Support/Adobe").path, roots: system.roots), "never Adobe's own folder")
    }
}
