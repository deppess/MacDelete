import Foundation
import XCTest
@testable import DeleteCore

final class OwnershipTests: XCTestCase {
    let ownership = Ownership(
        targetPath: "/Applications/App.app",
        targetIdentifiers: ["com.example.app", "com.example.AppHelper", "com.vendor"],
        otherApplications: [app("App Pro", id: "com.example.app.pro"), app("Twin", id: "com.example.twin"), app("Twin Beta", id: "com.example.twin", path: "/Applications/Twin Beta.app")]
    )

    func testWholeNamesSuffixesAndSubIdentifiers() {
        XCTAssertEqual(ownership.owner(ofItemNamed: "com.example.app"), .target)
        XCTAssertEqual(ownership.owner(ofItemNamed: "COM.EXAMPLE.APP.plist"), .target, "case is ignored")
        XCTAssertEqual(ownership.owner(ofItemNamed: "com.example.app.savedState"), .target)
        XCTAssertEqual(ownership.owner(ofItemNamed: "com.example.app.F3A1B2C4-0000-0000-0000-000000000000.plist"), .target, "ByHost")
        XCTAssertEqual(ownership.owner(ofItemNamed: "com.example.app.ShareExtension"), .target)
        XCTAssertEqual(ownership.owner(ofItemNamed: "com.example.apphelper"), .target, "an embedded identifier")
        XCTAssertEqual(ownership.owner(ofItemNamed: "com.example.app.code_sign_clone"), .target)
    }

    func testTheMostSpecificInstalledIdentifierWins() {
        XCTAssertEqual(ownership.owner(ofItemNamed: "com.example.app.pro.plist"), .other("/Applications/App Pro.app"))
        XCTAssertEqual(ownership.owner(ofItemNamed: "com.example.application"), nil, "not a dot boundary")
        XCTAssertEqual(ownership.owner(ofItemNamed: "com.example.other"), nil)
    }

    func testTwoComponentIdentifiersOnlyMatchWholeNames() {
        XCTAssertEqual(ownership.owner(ofItemNamed: "com.vendor.plist"), .target)
        XCTAssertEqual(ownership.owner(ofItemNamed: "com.vendor.otherproduct"), nil)
    }

    func testSharedIdentifier() {
        let twin = Ownership(targetPath: "/Applications/Twin.app", targetIdentifiers: ["com.example.twin"], otherApplications: [app("Twin Beta", id: "com.example.twin", path: "/Applications/Twin Beta.app")])
        XCTAssertEqual(twin.owner(ofItemNamed: "com.example.twin.plist"), .shared("/Applications/Twin Beta.app"))
    }
}

final class FinderTests: XCTestCase {
    /// An app with an extension and a login item, a sibling product, and leftovers everywhere.
    func makeExample(_ system: FakeSystem) throws -> URL {
        let bundle = try system.makeApp("Example.app", metadata: ["CFBundleIdentifier": "com.example.app", "CFBundleExecutable": "Example"])
        try system.makeApp("Example.app/Contents/PlugIns/Share.appex", metadata: ["CFBundleIdentifier": "com.example.app.Share"])
        try system.makeApp("Example.app/Contents/Library/LoginItems/Launcher.app", metadata: ["CFBundleIdentifier": "com.example.Launcher"])
        try system.makeApp("Example.app/Contents/Frameworks/Sparkle.framework/XPCServices/Downloader.xpc", metadata: ["CFBundleIdentifier": "org.sparkle-project.Downloader"])
        try system.makeApp("Example Pro.app", metadata: ["CFBundleIdentifier": "com.example.app.pro"])
        return bundle
    }

    func testFindsExactLeftoversAcrossTheFixedFolders() throws {
        let system = try FakeSystem()
        try makeExample(system)
        let lib = "Users/tester/Library"
        try system.touch("\(lib)/Application Support/com.example.app/data.db")
        try system.touch("\(lib)/Caches/com.example.app/")
        try system.touch("\(lib)/Preferences/com.example.app.plist")
        try system.touch("\(lib)/Preferences/ByHost/com.example.app.0000-1111.plist")
        try system.touch("\(lib)/Preferences/com.example.app.pro.plist")
        try system.touch("\(lib)/Containers/com.example.app.Share/")
        try system.touch("\(lib)/Containers/com.example.Launcher/")
        try system.touch("\(lib)/Saved Application State/com.example.app.savedState/")
        try system.touch("\(lib)/Cookies/com.example.app.binarycookies")
        try system.touch("\(lib)/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.example.app.sfl4")
        try system.touch("\(lib)/Caches/org.sparkle-project.Downloader/")
        try system.touch("private/var/folders/zz/hash/C/com.example.app/")
        try system.touch("private/var/folders/zz/hash/X/com.example.app.code_sign_clone/")
        try system.touch("Library/Preferences/com.example.app.plist")

        let plan = try system.plan("Example")
        let exact = Set(plan.findings.filter { $0.tier == .exact }.map { $0.path.replacingOccurrences(of: system.root.path + "/", with: "") })
        XCTAssertEqual(exact, [
            "Applications/Example.app",
            "\(lib)/Application Support/com.example.app",
            "\(lib)/Caches/com.example.app",
            "\(lib)/Preferences/com.example.app.plist",
            "\(lib)/Preferences/ByHost/com.example.app.0000-1111.plist",
            "\(lib)/Containers/com.example.app.Share",
            "\(lib)/Containers/com.example.Launcher",
            "\(lib)/Saved Application State/com.example.app.savedState",
            "\(lib)/Cookies/com.example.app.binarycookies",
            "\(lib)/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.example.app.sfl4",
            "private/var/folders/zz/hash/C/com.example.app",
            "private/var/folders/zz/hash/X/com.example.app.code_sign_clone",
            "Library/Preferences/com.example.app.plist",
        ], "the sibling product's preferences and Sparkle's shared service stay")
        XCTAssertEqual(plan.findings.first { $0.path.hasSuffix("Containers/com.example.Launcher") }?.reason, "login item")
        XCTAssertEqual(plan.findings.first { $0.path.hasSuffix("com.example.app.code_sign_clone") }?.reason, "code-signing copy")
        XCTAssertTrue(plan.identifiers.contains("com.example.app.Share") && !plan.identifiers.contains("org.sparkle-project.Downloader"))
    }

    func testUUIDContainersAreMatchedByTheirMetadata() throws {
        let system = try FakeSystem()
        try makeExample(system)
        let containers = system.userLibrary.appending(path: "Containers")
        try system.writePlist(["MCMMetadataIdentifier": "com.example.app"], to: containers.appending(path: "2E2C8A0B-6C4D-4F7A-9C1E-0123456789AB/.com.apple.containermanagerd.metadata.plist"))
        try system.writePlist(["MCMMetadataIdentifier": "com.other.app"], to: containers.appending(path: "11111111-2222-3333-4444-555555555555/.com.apple.containermanagerd.metadata.plist"))

        let paths = try system.plan("Example").findings.map(\.path)
        XCTAssertTrue(paths.contains { $0.hasSuffix("2E2C8A0B-6C4D-4F7A-9C1E-0123456789AB") })
        XCTAssertFalse(paths.contains { $0.hasSuffix("11111111-2222-3333-4444-555555555555") })
    }

    func testLaunchItemsByLabelAssociationAndProgram() throws {
        let system = try FakeSystem()
        let bundle = try makeExample(system)
        let agents = system.userLibrary.appending(path: "LaunchAgents")
        try system.writePlist(["Label": "COM.EXAMPLE.APP.agent", "Program": "/usr/bin/true"], to: agents.appending(path: "a.plist"))
        try system.writePlist(["Label": "net.unrelated.updater", "AssociatedBundleIdentifiers": ["com.example.app"]], to: agents.appending(path: "b.plist"))
        try system.writePlist(["Label": "org.helper", "ProgramArguments": [bundle.path + "/Contents/MacOS/Example", "--background"]], to: agents.appending(path: "c.plist"))
        try system.writePlist(["Label": "com.other.thing", "Program": "/usr/bin/true"], to: agents.appending(path: "d.plist"))
        let helper = system.library.appending(path: "Application Support/Example Co/Example/Components/com.example.app.daemon.bundle/Contents/MacOS/daemon")
        try system.write("bin", to: helper)
        try system.writePlist(["Label": "com.example.app.daemon", "Program": helper.path], to: system.library.appending(path: "LaunchDaemons/com.example.app.daemon.plist"))
        try system.write("tool", to: system.library.appending(path: "PrivilegedHelperTools/com.example.app.installer"))
        try system.writePlist(["Label": "com.example.app.installer", "Program": system.library.appending(path: "PrivilegedHelperTools/com.example.app.installer").path], to: system.library.appending(path: "LaunchDaemons/com.example.app.installer.plist"))

        let plan = try system.plan("Example")
        XCTAssertEqual(Set(plan.launchItems.map(\.label)), ["COM.EXAMPLE.APP.agent", "net.unrelated.updater", "org.helper", "com.example.app.daemon", "com.example.app.installer"])
        XCTAssertEqual(plan.launchItems.first { $0.label == "com.example.app.daemon" }?.domain, .system)
        let byPath = Dictionary(plan.findings.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byPath[system.library.appending(path: "Application Support/Example Co/Example/Components/com.example.app.daemon.bundle").path]?.tier, .exact)
        XCTAssertEqual(byPath[system.library.appending(path: "Application Support/Example Co/Example").path]?.tier, .name, "the vendor folder is only name evidence")
        XCTAssertEqual(byPath[system.library.appending(path: "PrivilegedHelperTools/com.example.app.installer").path]?.tier, .exact)
        XCTAssertNil(byPath[agents.appending(path: "d.plist").path])
    }

    /// A job's log files are the app's, unless they're not regular files or another job writes them too.
    func testLaunchItemLogsAreTheAppsUnlessShared() throws {
        let system = try FakeSystem()
        try makeExample(system)
        let own = try system.touch("Library/Application Support/Example Helper.log")
        let shared = try system.touch("Library/Logs/shared.log")
        try system.writePlist(["Label": "com.example.app.daemon", "Program": "/usr/bin/true", "StandardOutPath": own.path, "StandardErrorPath": "/dev/null"],
                              to: system.library.appending(path: "LaunchDaemons/com.example.app.daemon.plist"))
        try system.writePlist(["Label": "com.example.app.agent", "Program": "/usr/bin/true", "StandardErrorPath": shared.path], to: system.library.appending(path: "LaunchAgents/com.example.app.agent.plist"))
        try system.writePlist(["Label": "com.other.agent", "Program": "/usr/bin/true", "StandardOutPath": shared.path], to: system.library.appending(path: "LaunchAgents/com.other.agent.plist"))

        let paths = try system.plan("Example").findings.filter { $0.tier == .exact }.map(\.path)
        XCTAssertTrue(paths.contains(own.path))
        XCTAssertFalse(paths.contains(shared.path))
        XCTAssertFalse(paths.contains("/dev/null"))
    }

    /// A package installed into the bundle itself is found by the receipts, not `pkgutil
    /// --file-info`; one that installed only items the plan deletes is forgotten too, and one
    /// that installed anything else isn't.
    func testReceiptsInstalledIntoTheBundleOrCoveredByThePlanAreForgotten() throws {
        let system = try FakeSystem()
        let bundle = try makeExample(system)
        let daemons = system.library.appending(path: "LaunchDaemons")
        try system.writePlist(["Label": "com.example.app.daemon", "Program": bundle.path + "/Contents/MacOS/Example"], to: daemons.appending(path: "com.example.app.daemon.plist"))
        try system.touch("Library/LaunchDaemons/net.vendor.unrelated.plist")
        for (package, prefix) in [("com.example.pkg.app", bundle.path), ("com.example.pkg.daemon", daemons.path), ("com.example.pkg.extra", daemons.path)] {
            try system.writePlist(["PackageIdentifier": package, "InstallPrefixPath": prefix], to: system.receipts.appending(path: "\(package).plist"))
            try system.write("", to: system.receipts.appending(path: "\(package).bom"))
        }
        try system.write("""
        #!/bin/sh
        case "$*" in
        *pkg.app*) printf '.\\n./Contents\\n' ;;
        *-d*) printf '.\\n' ;;
        *pkg.daemon*) printf '.\\n./com.example.app.daemon.plist\\n' ;;
        *pkg.extra*) printf '.\\n./com.example.app.daemon.plist\\n./net.vendor.unrelated.plist\\n' ;;
        esac
        """, to: system.tools.appending(path: "lsbom"), executable: true)

        let plan = try system.plan("Example")
        XCTAssertEqual(plan.application.source, .installerPackage(identifiers: ["com.example.pkg.app"]))
        XCTAssertEqual(plan.packages.sorted(), ["com.example.pkg.app", "com.example.pkg.daemon"])
    }

    func testNameEvidenceSkipsGenericAndSharedNames() throws {
        let system = try FakeSystem()
        try makeExample(system)
        try system.makeApp("Agent.app", metadata: ["CFBundleIdentifier": "com.generic.agent"])
        try system.touch("Users/tester/Library/Application Support/Example/")
        try system.touch("Users/tester/Library/Caches/example/")
        try system.touch("Users/tester/.config/example/")
        try system.touch("Users/tester/.example")
        try system.touch("Users/tester/Library/Logs/DiagnosticReports/Example-2026-10-26-101010.ips")
        try system.touch("Users/tester/Library/Logs/DiagnosticReports/ExampleOther-2026-10-26.ips")
        try system.touch("Users/tester/Library/Application Support/Agent/")
        try system.touch("Users/tester/Library/Logs/Example.log")
        try system.touch("Users/tester/Library/Logs/Example 2/")
        try system.touch("Users/tester/Library/Preferences/example.plist")
        try system.touch("Users/tester/Library/Logs/Example Old/")

        let plan = try system.plan("Example")
        let names = Set(plan.findings.filter { $0.tier == .name }.map { $0.path.replacingOccurrences(of: system.home.path + "/", with: "~/") })
        XCTAssertEqual(names, ["~/Library/Application Support/Example", "~/Library/Caches/example", "~/.config/example", "~/.example", "~/Library/Logs/DiagnosticReports/Example-2026-10-26-101010.ips",
                               "~/Library/Logs/Example.log", "~/Library/Logs/Example 2", "~/Library/Preferences/example.plist"])
        XCTAssertTrue(plan.selected(includeNameMatches: false).allSatisfy { $0.tier == .exact })
        let agentPlan = try system.plan("Agent")
        XCTAssertFalse(agentPlan.findings.contains { $0.tier == .name }, "\"Agent\" is too generic to be evidence")
    }

    func testNameVariantsDropATrailingVersionOrLetter() throws {
        let system = try FakeSystem()
        try system.makeApp("Shot X.app", metadata: ["CFBundleIdentifier": "com.example.shot"])
        try system.touch("Users/tester/Library/Application Support/Shot/")
        XCTAssertTrue(try system.plan("Shot X").findings.contains { $0.path.hasSuffix("Application Support/Shot") && $0.tier == .name })
    }

    func testProtectedSymlinkedAndSharedItemsAreKept() throws {
        let system = try FakeSystem()
        try makeExample(system)
        try system.makeApp("Example Beta.app", metadata: ["CFBundleIdentifier": "com.example.app"])
        try system.touch("Users/tester/Library/Preferences/com.example.app.plist")
        // Logs reached through a link to somewhere else.
        let elsewhere = try system.touch("elsewhere/")
        try system.touch("elsewhere/com.example.app/")
        try FileManager.default.createSymbolicLink(at: system.userLibrary.appending(path: "Logs"), withDestinationURL: elsewhere)

        let plan = try system.plan("/Applications/Example.app".replacingOccurrences(of: "/Applications", with: system.applications.path))
        XCTAssertTrue(plan.skipped.contains { $0.path.hasSuffix("Preferences/com.example.app.plist") && $0.reason.contains("also belongs to") }, "\(plan.skipped)")
        XCTAssertFalse(plan.findings.contains { $0.path.contains("Logs/com.example.app") })
    }

    func testProtection() throws {
        let system = try FakeSystem()
        let roots = system.roots
        let home = system.home.path
        for path in ["\(home)/Documents/Example", "\(home)/Library/Application Support/Steam/steamapps", "\(home)/Library/Caches", "\(home)/Library/Preferences/ByHost",
                     "\(home)/.config", system.library.path, system.library.appending(path: "Application Support").path, "/System/Library/Foo", home] {
            XCTAssertTrue(Protection.isProtected(path, roots: roots), path)
        }
        for path in ["\(home)/Library/Caches/com.example.app", "\(home)/.config/example", system.library.appending(path: "Application Support/Example").path] {
            XCTAssertFalse(Protection.isProtected(path, roots: roots), path)
        }

        var xcode = app("Xcode", id: "com.apple.dt.Xcode")
        XCTAssertNil(Protection.refusal(for: xcode))
        xcode.path = "/Applications/Xcode-link.app"
        XCTAssertNotNil(Protection.refusal(for: xcode), "a link to an Apple app isn't the app")
        XCTAssertNotNil(Protection.refusal(for: app("Mail", id: "com.apple.mail")))
        XCTAssertNotNil(Protection.refusal(for: app("Safari", id: "com.apple.Safari", classification: .system)))
        XCTAssertTrue(Protection.refusal(for: app("Falcon", id: "com.crowdstrike.falcon.App"))?.message.contains("CrowdStrike") ?? false)
        XCTAssertNil(Protection.refusal(for: app("Raycast", id: "com.raycast.macos")))
        var idle = app("IDLE", id: "org.python.IDLE", path: "/Applications/MacPorts/Python 3.13/IDLE.app")
        XCTAssertEqual(Protection.refusal(for: idle)?.message, "IDLE was installed by MacPorts. Remove it with \"sudo port uninstall <port>\" (\"port provides '/Applications/MacPorts/Python 3.13/IDLE.app/Contents/Info.plist'\" names the port).",
                       "refused in dry runs and completion too, not only when deleting")
        idle.path = "/Applications/IDLE.app"; idle.bundlePath = idle.path; idle.source = .macPorts
        XCTAssertNotNil(Protection.refusal(for: idle))
    }

    func testRefusedAppsHaveNoPlan() throws {
        let system = try FakeSystem()
        try system.makeApp("Mail.app", metadata: ["CFBundleIdentifier": "com.apple.mail"])
        XCTAssertThrowsError(try system.plan("Mail"))
    }
}

final class PackageTests: XCTestCase {
    func testOwnedItemsDescendIntoSharedFolders() {
        let paths = ["/Applications", "/Applications/Suite", "/Applications/Suite/Tool.app", "/Applications/Suite/Manual.pdf",
                     "/Library", "/Library/Application Support", "/Library/Application Support/Vendor", "/Library/Application Support/Vendor/Product",
                     "/Library/Application Support/Vendor/Product/data", "/Library/LaunchDaemons", "/Library/LaunchDaemons/com.vendor.daemon.plist",
                     "/usr/local/bin/tool"]
        let owned = PackageEvidence.ownedItems(paths, sharedFolders: ["/applications/suite", "/library/application support/vendor"])
        XCTAssertEqual(owned, ["/Applications/Suite/Manual.pdf", "/Applications/Suite/Tool.app", "/Library/Application Support/Vendor/Product", "/Library/LaunchDaemons/com.vendor.daemon.plist", "/usr/local/bin/tool"])
        XCTAssertEqual(PackageEvidence.ownedItems(["/fake/Library", "/fake/Library/Fonts", "/fake/Library/Fonts/Font.otf"], sharedFolders: [], root: "/fake"), ["/fake/Library/Fonts/Font.otf"])
    }

    func testReceiptIsKeptWhenThePackageAlsoInstalledAnotherApp() throws {
        let system = try FakeSystem()
        try system.makeApp("Suite.app", metadata: ["CFBundleIdentifier": "com.vendor.suite"])
        try system.makeApp("Companion.app", metadata: ["CFBundleIdentifier": "com.vendor.companion"])
        try system.touch("Library/Application Support/Vendor Suite/data")
        for package in ["com.vendor.pkg.suite", "com.vendor.pkg.extras"] {
            try system.writePlist(["PackageIdentifier": package, "InstallPrefixPath": system.root.path], to: system.receipts.appending(path: "\(package).plist"))
            try system.write("", to: system.receipts.appending(path: "\(package).bom"))
        }
        try system.write("#!/bin/sh\nprintf 'pkgid: com.vendor.pkg.suite\\npkgid: com.vendor.pkg.extras\\n'\n", to: system.tools.appending(path: "pkgutil"), executable: true)
        try system.write("""
        #!/bin/sh
        case "$*" in
        *-d*) exit 0 ;;
        *suite*) printf '.\\n./Applications\\n./Applications/Suite.app\\n./Applications/Suite.app/Contents\\n./Library\\n./Library/Application Support\\n./Library/Application Support/Vendor Suite\\n./Library/Application Support/Vendor Suite/data\\n' ;;
        *extras*) printf '.\\n./Applications\\n./Applications/Companion.app\\n' ;;
        esac
        """, to: system.tools.appending(path: "lsbom"), executable: true)

        let plan = try system.plan("Suite")
        XCTAssertEqual(plan.packages, ["com.vendor.pkg.suite"])
        XCTAssertTrue(plan.findings.contains { $0.path == system.library.appending(path: "Application Support/Vendor Suite").path && $0.reason == "installed by package com.vendor.pkg.suite" })
        XCTAssertTrue(plan.skipped.contains { $0.reason == "package com.vendor.pkg.extras also installed Companion.app, so its files stay while that app is installed" }, "\(plan.skipped)")
        XCTAssertFalse(plan.findings.contains { $0.path.hasSuffix("Companion.app") })
    }

    /// One package installing two apps and shared files: deleting either app leaves the files.
    func testSuitePackageFilesStayWhileAnotherOfItsAppsRemains() throws {
        let system = try FakeSystem()
        try system.makeApp("Suite/Editor.app", metadata: ["CFBundleIdentifier": "com.vendor.editor"])
        try system.makeApp("Suite/Converter.app", metadata: ["CFBundleIdentifier": "com.vendor.converter"])
        try system.touch("Library/Application Support/Vendor/LUT/table")
        try system.writePlist(["PackageIdentifier": "com.vendor.pkg.suite", "InstallPrefixPath": system.root.path], to: system.receipts.appending(path: "com.vendor.pkg.suite.plist"))
        try system.write("", to: system.receipts.appending(path: "com.vendor.pkg.suite.bom"))
        try system.write("#!/bin/sh\nprintf 'pkgid: com.vendor.pkg.suite\\n'\n", to: system.tools.appending(path: "pkgutil"), executable: true)
        try system.write("#!/bin/sh\ncase \"$*\" in *-d*) exit 0;; esac\nprintf '.\\n./Applications\\n./Applications/Suite\\n./Applications/Suite/Editor.app\\n./Applications/Suite/Converter.app\\n./Library\\n./Library/Application Support\\n./Library/Application Support/Vendor\\n./Library/Application Support/Vendor/LUT\\n'\n", to: system.tools.appending(path: "lsbom"), executable: true)

        let plan = try system.plan("Editor")
        XCTAssertEqual(plan.packages, [])
        XCTAssertFalse(plan.findings.contains { $0.path.contains("Vendor") }, "\(plan.findings.map(\.path))")
        XCTAssertEqual(plan.findings.filter { $0.tier == .exact }.map { URL(filePath: $0.path).lastPathComponent }, ["Editor.app"])
    }
}

final class HomebrewZapTests: XCTestCase {
    func testCatalogScannerReadsOnlyMatchingCasks() throws {
        let casks: [String: Any] = [
            "example": ["raw_artifacts": [[":app", ["Example.app"]], [":zap", [":trash": ["~/Library/Example", "~/Library/Caches/{a,b}"]]], [":uninstall", [":quit": "com.example.app"]]]],
            "other": ["raw_artifacts": [[":app", ["Other.app"]]], "desc": "braces } and \"quotes\" and \\u00e9"],
        ]
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["formulae": ["x": ["y": 1]], "casks": casks]), as: UTF8.self)
        let file = try JSONSerialization.data(withJSONObject: ["payload": payload, "signatures": []])
        XCTAssertEqual(CatalogScanner.unescapedPayload(file).map { String(decoding: $0, as: UTF8.self) }, payload)
        let found = try XCTUnwrap(CatalogScanner.casks(in: file, mentioning: ["Example.app"]))
        XCTAssertEqual(found.map(\.token), ["example"])

        let system = try FakeSystem()
        let catalog = system.home.appending(path: "Library/Caches/Homebrew/api")
        try system.write(String(decoding: file, as: UTF8.self), to: catalog.appending(path: "internal/packages.arm64_test.jws.json"))
        let match = try XCTUnwrap(HomebrewZap.catalogPaths(for: app("Example", id: "com.example.app"), catalog: catalog))
        XCTAssertEqual(match.token, "example")
        XCTAssertEqual(match.paths, ["~/Library/Example", "~/Library/Caches/{a,b}"])
        XCTAssertNil(HomebrewZap.catalogPaths(for: app("Missing", id: "com.missing"), catalog: catalog))
    }

    func testCatalogEntriesAreNameEvidenceAndSkipPersonalFolders() throws {
        let system = try FakeSystem()
        try system.makeApp("Example.app", metadata: ["CFBundleIdentifier": "com.example.app"])
        try system.touch("Users/tester/Library/Example Data/")
        try system.touch("Users/tester/Documents/Example Projects/")
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["casks": ["example": ["raw_artifacts": [[":app", ["Example.app"]], [":zap", [":trash": ["~/Library/Example Data", "~/Documents/Example Projects"]]]]]]]), as: UTF8.self)
        try system.write(String(decoding: try JSONSerialization.data(withJSONObject: ["payload": payload]), as: UTF8.self), to: system.home.appending(path: "Library/Caches/Homebrew/api/internal/packages.test.jws.json"))

        let plan = try system.plan("Example")
        XCTAssertEqual(plan.findings.first { $0.path.hasSuffix("Example Data") }?.tier, .name)
        XCTAssertFalse(plan.findings.contains { $0.path.contains("Documents") })
    }

    func testInstalledCaskZapIsExactAndHandedToHomebrew() throws {
        let system = try FakeSystem()
        try system.makeApp("Example.app", metadata: ["CFBundleIdentifier": "com.example.app"])
        try system.touch("Users/tester/Library/Example Data/")
        let metadata = system.homebrew.appending(path: "Caskroom/example/.metadata")
        try system.writeJSON(["uninstall_artifacts": [["app": ["Example.app"]], ["zap": [["trash": ["~/Library/Example Data"]]]]]], to: metadata.appending(path: "INSTALL_RECEIPT.json"))
        try system.writeJSON(["default": ["appdir": system.applications.path]], to: metadata.appending(path: "config.json"))

        let plan = try system.plan("Example")
        XCTAssertEqual(plan.homebrewCask, "example")
        XCTAssertEqual(plan.findings.first { $0.path.hasSuffix("Example Data") }?.reason, "Homebrew zap")
        XCTAssertEqual(plan.findings.first { $0.path.hasSuffix("Example Data") }?.tier, .exact)
    }

    /// `rmdir` in a zap list means "only if empty" (the claude-code cask names ~/.claude this way):
    /// such a folder is never deleted with what's in it.
    func testZapRmdirFoldersGoOnlyWhenEmpty() throws {
        let system = try FakeSystem()
        try system.makeApp("Example.app", metadata: ["CFBundleIdentifier": "com.example.app"])
        try system.touch("Users/tester/.example/history.jsonl")
        try system.touch("Users/tester/Library/Application Support/Vendor/Example/state")
        try system.touch("Users/tester/Library/Application Support/Vendor/Other Product/data")
        try system.touch("Users/tester/Library/Application Support/Lonely/Example/cache")
        let metadata = system.homebrew.appending(path: "Caskroom/example/.metadata")
        try system.writeJSON(["uninstall_artifacts": [["app": ["Example.app"]], ["zap": [
            ["trash": ["~/Library/Application Support/Vendor/Example", "~/Library/Application Support/Lonely/Example"],
             "rmdir": ["~/.example", "~/Library/Application Support/Vendor", "~/Library/Application Support/Lonely"]],
        ]]]], to: metadata.appending(path: "INSTALL_RECEIPT.json"))
        try system.writeJSON(["default": ["appdir": system.applications.path]], to: metadata.appending(path: "config.json"))

        let plan = try system.plan("Example")
        let support = system.userLibrary.appending(path: "Application Support")
        XCTAssertFalse(plan.findings.contains { $0.path.hasSuffix("/.example") || $0.path == support.appending(path: "Vendor").path || $0.path == support.appending(path: "Lonely").path },
                       "\(plan.findings.map(\.path))")
        XCTAssertEqual(Set(plan.emptyFolders), [system.home.appending(path: ".example").path, support.appending(path: "Vendor").path, support.appending(path: "Lonely").path])

        let report = Executor(actions: RecordingSystemActions(), allowedRoot: system.root.path, home: system.home)
            .run(plan, targets: Executor.targets(for: plan.selected(includeNameMatches: false)), isRoot: false, casks: [])
        XCTAssertNil(report.stopped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: system.home.appending(path: ".example/history.jsonl").path), "a folder with contents stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appending(path: "Vendor/Other Product/data").path), "another product's data stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appending(path: "Vendor/Example").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appending(path: "Lonely").path), "emptied by the zap list, so it goes")
        XCTAssertTrue(PlanRenderer.text(plan, includeNameMatches: false, isRoot: false, home: system.home).contains("removes 3 folders once they're empty"))
    }

    func testRemoveIfEmptyLeavesContentsLinksAndStandardFolders() throws {
        let system = try FakeSystem()
        let full = try system.touch("Users/tester/full/")
        try system.touch("Users/tester/full/file")
        let tidy = try system.touch("Users/tester/tidy/")
        try system.touch("Users/tester/tidy/.DS_Store")
        let target = try system.touch("Users/tester/target/")
        let link = system.home.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let caches = try system.touch("Users/tester/Library/Caches/")
        let root = system.root.path
        XCTAssertFalse(Remover.removeIfEmpty(full.path, allowedRoot: root, home: system.home))
        XCTAssertTrue(Remover.removeIfEmpty(tidy.path, allowedRoot: root, home: system.home), "only a .DS_Store counts as empty")
        XCTAssertFalse(Remover.removeIfEmpty(link.path, allowedRoot: root, home: system.home))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(Remover.removeIfEmpty(caches.path, allowedRoot: root, home: system.home), "a standard Library folder, even empty")
        XCTAssertFalse(Remover.removeIfEmpty(system.home.path, allowedRoot: root, home: system.home))
        let other = try FakeSystem()
        XCTAssertFalse(Remover.removeIfEmpty(other.root.path, allowedRoot: root, home: system.home), "outside the allowed root")
    }
}

final class SteamAndAppleTests: XCTestCase {
    func testSteamGameIncludesFolderManifestAndShortcut() throws {
        let system = try FakeSystem()
        let steamapps = system.userLibrary.appending(path: "Application Support/Steam/steamapps")
        try system.makeApp("Balatro.app", in: steamapps.appending(path: "common/Balatro"), metadata: ["CFBundleIdentifier": "com.playstack.balatro"])
        try system.write("\"AppState\"\n{\n\t\"appid\"\t\t\"2379780\"\n\t\"installdir\"\t\t\"Balatro\"\n}\n", to: steamapps.appending(path: "appmanifest_2379780.acf"))
        try system.write("other", to: steamapps.appending(path: "libraryfolders.vdf"))
        let shortcut = try system.makeApp("Balatro.app", in: system.home.appending(path: "Applications"), metadata: ["CFBundleExecutable": "run"])
        try system.write("#!/bin/sh\nopen steam://run/2379780\n", to: shortcut.appending(path: "Contents/MacOS/run"), executable: true)

        let inventory = Inventory.load(roots: system.roots, sizes: false)
        XCTAssertEqual(Inventory.foldingSteamShortcuts(inventory.applications.filter { $0.classification == .user }).map(\.name), ["Balatro"])
        let plan = try system.plan("Balatro")
        let paths = Set(plan.findings.map { $0.path.replacingOccurrences(of: system.home.path + "/", with: "~/") })
        XCTAssertEqual(paths, ["~/Library/Application Support/Steam/steamapps/common/Balatro", "~/Library/Application Support/Steam/steamapps/appmanifest_2379780.acf", "~/Applications/Balatro.app"])
    }

    /// Stardew Valley's whole folder is its bundle, with no `.app` extension.
    func testSteamGameWhoseFolderIsTheBundle() throws {
        let system = try FakeSystem()
        let steamapps = system.userLibrary.appending(path: "Application Support/Steam/steamapps")
        try system.makeApp("Stardew Valley 1.6", in: steamapps.appending(path: "common"), metadata: ["CFBundleIdentifier": "com.concernedape.stardewvalley"])
        try system.touch("Users/tester/Library/Application Support/Steam/steamapps/common/Notes/readme.txt")
        try system.makeApp("Deep", in: steamapps.appending(path: "common/Notes"), metadata: ["CFBundleIdentifier": "com.example.deep"])
        try system.write("\"AppState\"\n{\n\t\"appid\"\t\t\"413150\"\n\t\"installdir\"\t\t\"Stardew Valley 1.6\"\n}\n", to: steamapps.appending(path: "appmanifest_413150.acf"))
        let shortcut = try system.makeApp("Stardew Valley.app", in: system.home.appending(path: "Applications"), metadata: ["CFBundleExecutable": "run"])
        try system.write("#!/bin/sh\nopen steam://run/413150\n", to: shortcut.appending(path: "Contents/MacOS/run"), executable: true)
        try system.touch("Users/tester/Library/Preferences/com.concernedape.stardewvalley.plist")

        let inventory = Inventory.load(roots: system.roots, sizes: false)
        XCTAssertEqual(Inventory.foldingSteamShortcuts(inventory.applications.filter { $0.classification == .user }).map(\.name), ["Stardew Valley 1.6"], "a folder bundle only directly inside common")
        let plan = try system.plan("Stardew Valley 1.6")
        let paths = Set(plan.findings.map { $0.path.replacingOccurrences(of: system.home.path + "/", with: "~/") })
        XCTAssertEqual(paths, ["~/Library/Application Support/Steam/steamapps/common/Stardew Valley 1.6", "~/Library/Application Support/Steam/steamapps/appmanifest_413150.acf",
                               "~/Applications/Stardew Valley.app", "~/Library/Preferences/com.concernedape.stardewvalley.plist"])
    }

    /// A shortcut whose game the scan didn't find still reaches the game through its manifest.
    func testSteamShortcutFindsItsGameThroughTheManifest() throws {
        let system = try FakeSystem()
        let steamapps = system.userLibrary.appending(path: "Application Support/Steam/steamapps")
        try system.touch("Users/tester/Library/Application Support/Steam/steamapps/common/Some Game/data.pak")
        try system.write("\"AppState\"\n{\n\t\"appid\"\t\t\"12345\"\n\t\"installdir\"\t\t\"Some Game\"\n}\n", to: steamapps.appending(path: "appmanifest_12345.acf"))
        try system.write("\"AppState\"\n{\n\t\"appid\"\t\t\"777\"\n\t\"installdir\"\t\t\"..\"\n}\n", to: steamapps.appending(path: "appmanifest_777.acf"))
        let shortcut = try system.makeApp("Some Game.app", in: system.home.appending(path: "Applications"), metadata: ["CFBundleExecutable": "run"])
        try system.write("#!/bin/sh\nopen steam://run/12345\n", to: shortcut.appending(path: "Contents/MacOS/run"), executable: true)
        let escaping = try system.makeApp("Escape.app", in: system.home.appending(path: "Applications"), metadata: ["CFBundleExecutable": "run"])
        try system.write("#!/bin/sh\nopen steam://run/777\n", to: escaping.appending(path: "Contents/MacOS/run"), executable: true)

        let paths = Set(try system.plan("Some Game").findings.map { $0.path.replacingOccurrences(of: system.home.path + "/", with: "~/") })
        XCTAssertEqual(paths, ["~/Applications/Some Game.app", "~/Library/Application Support/Steam/steamapps/common/Some Game", "~/Library/Application Support/Steam/steamapps/appmanifest_12345.acf"])
        XCTAssertEqual(try system.plan("Escape").findings.map(\.path), [escaping.path], "a manifest naming .. is ignored")
    }

    /// Deleting Steam takes all of Steam's own data, its folder included, but never a game that is
    /// still installed; with no games left, the folder goes too.
    func testSteamItselfTakesItsDataButNoInstalledGame() throws {
        for withGame in [true, false] {
            let system = try FakeSystem()
            try system.makeApp("Steam.app", metadata: ["CFBundleIdentifier": "com.valvesoftware.steam"])
            let steam = "Users/tester/Library/Application Support/Steam"
            for path in ["\(steam)/Steam.AppBundle/Steam/Contents/MacOS/steam_osx", "\(steam)/userdata/1/config.vdf", "\(steam)/appcache/x", "\(steam)/registry.vdf",
                         "\(steam)/steamapps/shadercache/1/x", "\(steam)/steamapps/common/Gone Game/data", "\(steam)/steamapps/libraryfolders.vdf", "Users/tester/Library/Caches/Steam/x"] {
                try system.touch(path)
            }
            try system.write("\"AppState\"\n{\n\t\"appid\"\t\t\"999\"\n\t\"installdir\"\t\t\"Vanished\"\n}\n", to: system.root.appending(path: "\(steam)/steamapps/appmanifest_999.acf"))
            if withGame {
                try system.makeApp("Game.app", in: system.root.appending(path: "\(steam)/steamapps/common/Game"), metadata: ["CFBundleIdentifier": "com.studio.game"])
                try system.write("\"AppState\"\n{\n\t\"appid\"\t\t\"42\"\n\t\"installdir\"\t\t\"Game\"\n}\n", to: system.root.appending(path: "\(steam)/steamapps/appmanifest_42.acf"))
            }
            try system.writePlist(["Label": "com.valvesoftware.steamclean", "Program": "/usr/bin/true"], to: system.userLibrary.appending(path: "LaunchAgents/com.valvesoftware.steamclean.plist"))

            let plan = try system.plan("Steam")
            let exact = relative(plan.findings, system, tier: .exact)
            XCTAssertTrue(exact.isSuperset(of: ["\(steam)/Steam.AppBundle", "\(steam)/userdata", "\(steam)/appcache", "\(steam)/registry.vdf", "\(steam)/steamapps/shadercache",
                                                "\(steam)/steamapps/common/Gone Game", "\(steam)/steamapps/appmanifest_999.acf", "\(steam)/steamapps/libraryfolders.vdf",
                                                "Users/tester/Library/Caches/Steam", "Users/tester/Library/LaunchAgents/com.valvesoftware.steamclean.plist"]), "\(exact)")
            XCTAssertTrue(plan.launchItems.contains { $0.label == "com.valvesoftware.steamclean" })
            XCTAssertFalse(exact.contains { $0.contains("common/Game") || $0.hasSuffix("appmanifest_42.acf") }, "an installed game is never Steam's")
            XCTAssertEqual(plan.skipped.contains { $0.path.hasSuffix("common/Game") && $0.reason.hasPrefix("Game is installed") }, withGame)

            let report = Executor(actions: RecordingSystemActions(), allowedRoot: system.root.path, home: system.home)
                .run(plan, targets: Executor.targets(for: plan.selected(includeNameMatches: false)), isRoot: false, casks: [])
            XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
            let folder = system.root.appending(path: steam).path
            if withGame {
                XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/steamapps/common/Game/Game.app"))
                XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/steamapps/appmanifest_42.acf"))
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder), ["steamapps"])
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder), "nothing of Steam's is left")
            }
        }
    }

    /// Older Steam installs spell it "SteamApps": its games must stay all the same.
    func testSteamItselfWithAnOldStyleSteamAppsFolder() throws {
        let system = try FakeSystem()
        try system.makeApp("Steam.app", metadata: ["CFBundleIdentifier": "com.valvesoftware.steam"])
        let steam = "Users/tester/Library/Application Support/Steam"
        try system.touch("\(steam)/Steam.AppBundle/x")
        try system.makeApp("Game.app", in: system.root.appending(path: "\(steam)/SteamApps/common/Game"), metadata: ["CFBundleIdentifier": "com.studio.game"])
        try system.write("\"AppState\"\n{\n\t\"appid\"\t\t\"42\"\n\t\"installdir\"\t\t\"Game\"\n}\n", to: system.root.appending(path: "\(steam)/SteamApps/appmanifest_42.acf"))
        try system.touch("\(steam)/SteamApps/shadercache/x")

        let plan = try system.plan("Steam")
        let selected = plan.selected(includeNameMatches: true).map { $0.path.replacingOccurrences(of: system.root.path + "/", with: "") }
        XCTAssertFalse(selected.contains { $0.hasSuffix("/SteamApps") || $0.contains("SteamApps/common") || $0.hasSuffix("appmanifest_42.acf") }, "\(selected)")
        XCTAssertTrue(selected.contains("\(steam)/SteamApps/shadercache"))
        XCTAssertTrue(selected.contains("\(steam)/Steam.AppBundle"))
        XCTAssertTrue(plan.skipped.contains { $0.path.hasSuffix("SteamApps/common/Game") })
    }

    func testXcodeBuildDataIsKeptWhileAnotherXcodeRemains() throws {
        let system = try FakeSystem()
        try system.makeApp("Xcode.app", metadata: ["CFBundleIdentifier": "com.apple.dt.Xcode"])
        try system.touch("Users/tester/Library/Developer/Xcode/DerivedData/Project-abc/")
        try system.touch("Users/tester/Library/Developer/Xcode/Archives/")
        XCTAssertTrue(try system.plan("Xcode").findings.contains { $0.path.hasSuffix("DerivedData") && $0.reason == "Xcode build data" })
        XCTAssertFalse(try system.plan("Xcode").findings.contains { $0.path.contains("Archives") })

        try system.makeApp("Xcode-beta.app", metadata: ["CFBundleIdentifier": "com.apple.dt.Xcode"])
        let plan = try system.plan(system.applications.appending(path: "Xcode.app").path)
        XCTAssertTrue(plan.skipped.contains { $0.path.hasSuffix("DerivedData") && $0.reason == "another Xcode is still installed" })
    }
}

final class PlanRendererTests: XCTestCase {
    func testSectionsAndQuestion() {
        var exact = Finding(path: "/Applications/Example.app", tier: .exact)
        exact.size = 298_000_000
        var support = Finding(path: "/Users/tester/Library/Application Support/com.example.app", tier: .exact)
        support.size = 12_000_000
        var daemon = Finding(path: "/Library/LaunchDaemons/com.example.app.daemon.plist", tier: .exact, reason: "launch daemon")
        daemon.size = 4_096
        daemon.needsRoot = true
        var named = Finding(path: "/Users/tester/Library/Application Support/Example", tier: .name, reason: "named after the app")
        named.size = 3_000_000
        var application = app("Example", id: "com.example.app")
        application.version = "1.0"
        let plan = RemovalPlan(application: application, identifiers: ["com.example.app"], findings: [exact, support, daemon, named],
                               skipped: [Skipped(path: "/Users/tester/Library/Group Containers/T.group", reason: "app group shared with Other")],
                               launchItems: [LaunchItem(label: "com.example.app.daemon", plist: daemon.path, domain: .system)], packages: [], unreadable: [], notes: [], running: false, homebrewCask: nil)
        let text = PlanRenderer.text(plan, includeNameMatches: false, isRoot: false, home: URL(filePath: "/Users/tester"))
        XCTAssertEqual(text, """
        Example   1.0   310 MB   (Download)

          /Applications/Example.app                            298 MB
          ~/Library/Application Support/com.example.app         12 MB

          Needs administrator rights (run with sudo to include these):
          /Library/LaunchDaemons/com.example.app.daemon.plist    4 KB   launch daemon

          Not included (matched by name only; add with --include-name-matches):
          ~/Library/Application Support/Example                3.0 MB   named after the app

          Kept:
          ~/Library/Group Containers/T.group   app group shared with Other

          Also: stops 1 launch item first; resets its privacy permissions.
        """)
        XCTAssertEqual(PlanRenderer.question(plan, includeNameMatches: false, isRoot: false), "Permanently delete 2 items (310 MB)? [y/N] ")
        XCTAssertEqual(PlanRenderer.question(plan, includeNameMatches: true, isRoot: true), "Permanently delete 4 items (313 MB)? [y/N] ")
    }
}
