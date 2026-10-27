import Foundation
import XCTest
@testable import DeleteCore

final class CompanionTests: XCTestCase {
    /// Developer teams by bundle name, standing in for signatures.
    private func teams(_ map: [String: String]) -> @Sendable (String) -> String? {
        { path in map[URL(filePath: path).deletingPathExtension().lastPathComponent] }
    }

    private func application(_ name: String, in inventory: Inventory) throws -> InstalledApp {
        try XCTUnwrap(inventory.applications.first { $0.name == name })
    }

    /// Apps in the app's own folder go with it; the app never goes with them, and other apps of
    /// the same developer are only mentioned.
    func testAppsInTheAppsFolderAreItsCompanionsOneWay() throws {
        let system = try FakeSystem()
        try system.makeApp("Suite/Suite.app", metadata: ["CFBundleIdentifier": "com.vendor.suite", "CFBundleName": "Suite"])
        try system.makeApp("Suite/Suite Utility.app", metadata: ["CFBundleIdentifier": "com.vendor.utility", "CFBundleName": "Suite Utility"])
        try system.makeApp("Suite/Intruder.app", metadata: ["CFBundleIdentifier": "com.other.intruder", "CFBundleName": "Intruder"])
        try system.makeApp("Other Product.app", metadata: ["CFBundleIdentifier": "com.vendor.other", "CFBundleName": "Other Product"])
        let inventory = Inventory.load(roots: system.roots, sizes: false)
        let team = teams(["Suite": "TEAM1", "Suite Utility": "TEAM1", "Other Product": "TEAM1", "Intruder": "TEAM2"])

        let suite = Companions.find(for: try application("Suite", in: inventory), inventory: inventory, roots: system.roots, team: team)
        XCTAssertEqual(suite.companions.map(\.application.name), ["Suite Utility"])
        XCTAssertEqual(suite.companions.first?.reason, "in Suite's folder")
        XCTAssertEqual(suite.sameDeveloper.map(\.name), ["Other Product"])
        XCTAssertEqual(suite.folder, system.applications.appending(path: "Suite").path)

        let utility = Companions.find(for: try application("Suite Utility", in: inventory), inventory: inventory, roots: system.roots, team: team)
        XCTAssertEqual(utility.companions.map(\.application.name), [])
        XCTAssertEqual(utility.sameDeveloper.map(\.name), ["Other Product"])
        XCTAssertEqual(utility.partOf.map(\.name), ["Suite"])

        // Without a team, nothing is a companion.
        XCTAssertTrue(Companions.find(for: try application("Suite", in: inventory), inventory: inventory, roots: system.roots, team: { _ in nil }).companions.isEmpty)
    }

    /// FL Studio's package installs "FL Cloud Plugins Installer.pkg": FL Cloud Plugins goes with
    /// FL Studio, not the other way round.
    func testAnAppWhosePackageShipsAnotherAppsInstallerTakesThatApp() throws {
        let system = try FakeSystem()
        try system.makeApp("Main.app", metadata: ["CFBundleIdentifier": "com.vendor.main", "CFBundleName": "Main"])
        try system.makeApp("Helper Tool.app", metadata: ["CFBundleIdentifier": "com.vendor.helper", "CFBundleName": "Helper Tool"])
        try system.writePlist(["PackageIdentifier": "com.vendor.pkg.main", "InstallPrefixPath": system.root.path], to: system.receipts.appending(path: "com.vendor.pkg.main.plist"))
        try system.write("", to: system.receipts.appending(path: "com.vendor.pkg.main.bom"))
        try system.write("""
        #!/bin/sh
        case "$*" in
        *-d*) printf '.\\n./Applications\\n./Applications/Main.app\\n./Applications/Main.app/Contents\\n' ;;
        *) printf '.\\n./Applications/Main.app\\n./Applications/Main.app/Contents/Tools/Helper Tool Installer.pkg\\n' ;;
        esac
        """, to: system.tools.appending(path: "lsbom"), executable: true)
        let inventory = Inventory.load(roots: system.roots, sizes: false)
        let team = teams(["Main": "TEAM1", "Helper Tool": "TEAM1"])

        let main = Companions.find(for: try application("Main", in: inventory), inventory: inventory, roots: system.roots, team: team)
        XCTAssertEqual(main.companions.map(\.application.name), ["Helper Tool"])
        XCTAssertEqual(main.companions.first?.reason, "its installer ships with Main")
        XCTAssertNil(main.folder)
        XCTAssertEqual(Companions.find(for: try application("Helper Tool", in: inventory), inventory: inventory, roots: system.roots, team: team).companions.count, 0)
    }

    /// One package installing several apps: they go with the largest, which goes with none.
    func testAppsFromTheSamePackageGoWithTheLargest() throws {
        let system = try FakeSystem()
        let big = try system.makeApp("Big.app", metadata: ["CFBundleIdentifier": "com.vendor.big", "CFBundleName": "Big"])
        try system.write(String(repeating: "x", count: 200_000), to: big.appending(path: "Contents/Resources/data"))
        try system.makeApp("Small.app", metadata: ["CFBundleIdentifier": "com.vendor.small", "CFBundleName": "Small"])
        try system.writePlist(["PackageIdentifier": "com.vendor.pkg.suite", "InstallPrefixPath": system.root.path], to: system.receipts.appending(path: "com.vendor.pkg.suite.plist"))
        try system.write("", to: system.receipts.appending(path: "com.vendor.pkg.suite.bom"))
        try system.write("#!/bin/sh\nprintf '.\\n./Applications\\n./Applications/Big.app\\n./Applications/Small.app\\n'\n", to: system.tools.appending(path: "lsbom"), executable: true)
        let inventory = Inventory.load(roots: system.roots, sizes: true)
        let team = teams(["Big": "TEAM1", "Small": "TEAM1"])

        let found = Companions.find(for: try application("Big", in: inventory), inventory: inventory, roots: system.roots, team: team)
        XCTAssertEqual(found.companions.map(\.application.name), ["Small"])
        XCTAssertEqual(found.companions.first?.reason, "installed by the same package (com.vendor.pkg.suite)")
        XCTAssertEqual(Companions.find(for: try application("Small", in: inventory), inventory: inventory, roots: system.roots, team: team).companions.count, 0)

        // Planned together, the package belongs to the group instead of being kept for Small.
        let group: Set<String> = [try application("Big", in: inventory).path, try application("Small", in: inventory).path]
        let plan = try EvidenceFinder(roots: system.roots).plan(for: try application("Big", in: inventory), inventory: inventory, group: group)
        XCTAssertEqual(plan.packages, ["com.vendor.pkg.suite"])
        XCTAssertTrue(plan.skipped.isEmpty, "\(plan.skipped)")
    }

    /// `brew uninstall` removes every app of a cask: they go together whichever is named, and
    /// even --no-companions can't keep them.
    func testAppsOfOneHomebrewCaskAlwaysGoTogether() throws {
        let system = try FakeSystem()
        try system.makeApp("Viewer.app", metadata: ["CFBundleIdentifier": "net.tool.viewer", "CFBundleName": "Viewer"])
        try system.makeApp("Merge.app", metadata: ["CFBundleIdentifier": "net.tool.merge", "CFBundleName": "Merge"])
        let metadata = system.homebrew.appending(path: "Caskroom/tool/.metadata")
        try system.writeJSON(["uninstall_artifacts": [["app": ["Viewer.app"]], ["app": ["Merge.app"]]]], to: metadata.appending(path: "INSTALL_RECEIPT.json"))
        try system.writeJSON(["default": ["appdir": system.applications.path]], to: metadata.appending(path: "config.json"))
        let inventory = Inventory.load(roots: system.roots, sizes: false)

        // No signatures at all: the cask alone ties them.
        let merge = Companions.find(for: try application("Merge", in: inventory), inventory: inventory, roots: system.roots, team: { _ in nil })
        XCTAssertEqual(merge.companions.map(\.application.name), ["Viewer"])
        XCTAssertEqual(merge.companions.first?.inseparable, true)
        XCTAssertEqual(Companions.find(for: try application("Viewer", in: inventory), inventory: inventory, roots: system.roots, team: { _ in nil }).companions.map(\.application.name), ["Merge"])

        // Planned together, one brew uninstall runs and the other app counts as removed by it.
        let group: Set<String> = [try application("Merge", in: inventory).path, try application("Viewer", in: inventory).path]
        let finder = EvidenceFinder(roots: system.roots)
        let plans = RemovalPlan.deduplicated([try finder.plan(for: try application("Merge", in: inventory), inventory: inventory, group: group),
                                              try finder.plan(for: try application("Viewer", in: inventory), inventory: inventory, group: group)])
        XCTAssertEqual(plans.map(\.homebrewCask), ["tool", nil])
        XCTAssertEqual(plans.map(\.removedWithCask), [nil, "tool"])
    }

    /// One receipt installing equal peers has no main app: none takes another. A receipt named
    /// after one of its apps makes that one the main app, whatever the sizes.
    func testPackageGroupsNeedAClearMainApp() throws {
        let system = try FakeSystem()
        for name in ["Alpha", "Beta"] {
            let bundle = try system.makeApp("\(name).app", metadata: ["CFBundleIdentifier": "com.vendor.\(name.lowercased())", "CFBundleName": name])
            try system.write(String(repeating: "x", count: 100_000), to: bundle.appending(path: "Contents/Resources/data"))
        }
        try system.makeApp("Keyboard Tool.app", metadata: ["CFBundleIdentifier": "org.keys.tool", "CFBundleName": "Keyboard Tool"])
        try system.makeApp("Keyboard Tool Viewer.app", metadata: ["CFBundleIdentifier": "org.keys.viewer", "CFBundleName": "Keyboard Tool Viewer"])
        for (package, apps) in [("com.vendor.pkg.suite", ["Alpha", "Beta"]), ("org.keys.keyboard-tool", ["Keyboard Tool", "Keyboard Tool Viewer"])] {
            try system.writePlist(["PackageIdentifier": package, "InstallPrefixPath": system.root.path], to: system.receipts.appending(path: "\(package).plist"))
            try system.write(apps.map { "./Applications/\($0).app" }.joined(separator: "\n"), to: system.receipts.appending(path: "\(package).bom"))
        }
        try system.write("#!/bin/sh\nfor last; do :; done\nprintf '.\\n./Applications\\n'; cat \"$last\"; echo\n", to: system.tools.appending(path: "lsbom"), executable: true)
        let inventory = Inventory.load(roots: system.roots, sizes: true)
        let team = teams(["Alpha": "T", "Beta": "T", "Keyboard Tool": "K", "Keyboard Tool Viewer": "K"])

        let alpha = Companions.find(for: try application("Alpha", in: inventory), inventory: inventory, roots: system.roots, team: team)
        XCTAssertEqual(alpha.companions.count, 0)
        XCTAssertEqual(alpha.sameDeveloper.map(\.name), ["Beta"])
        let tool = Companions.find(for: try application("Keyboard Tool", in: inventory), inventory: inventory, roots: system.roots, team: team)
        XCTAssertEqual(tool.companions.map(\.application.name), ["Keyboard Tool Viewer"])
        let viewer = Companions.find(for: try application("Keyboard Tool Viewer", in: inventory), inventory: inventory, roots: system.roots, team: team)
        XCTAssertEqual(viewer.companions.count, 0)
        XCTAssertEqual(viewer.partOf.map(\.name), ["Keyboard Tool"])
    }

    func testUninstallersGoWithTheAppTheyreNamedAfter() throws {
        let system = try FakeSystem()
        try system.makeApp("Studio 6.app", metadata: ["CFBundleIdentifier": "org.studio.app", "CFBundleName": "Studio 6"])
        try system.makeApp("Vendor/Studio 6 Uninstaller.app", metadata: ["CFBundleIdentifier": "org.studio.uninstaller", "CFBundleName": "Studio 6 Uninstaller"])
        try system.makeApp("Uninstall Other.app", metadata: ["CFBundleIdentifier": "net.else.uninstall", "CFBundleName": "Uninstall Other"])
        let inventory = Inventory.load(roots: system.roots, sizes: false)
        let found = Companions.find(for: try application("Studio 6", in: inventory), inventory: inventory, roots: system.roots, team: teams(["Studio 6": "S", "Studio 6 Uninstaller": "S", "Uninstall Other": "S"]))
        XCTAssertEqual(found.companions.map(\.application.name), ["Studio 6 Uninstaller"])
        XCTAssertEqual(Companions.uninstalledName("Uninstaller for Vuze"), "vuze")
        XCTAssertEqual(Companions.uninstalledName("App Uninstaller"), nil, "too short to name an app")
        XCTAssertEqual(Companions.uninstalledName("Uninstall Resolve"), "resolve")
        XCTAssertNil(Companions.uninstalledName("Studio 6"))
    }

    /// Folders named after their main app, even loosely ("Adobe Acrobat DC" holding "Adobe
    /// Acrobat", "Burn.localized"); a folder named after none of its apps takes nothing.
    func testFolderMainApps() {
        func apps(_ names: [String]) -> [InstalledApp] { names.map { app($0, id: "com.v.\(Companions.normalized($0))", path: "/Applications/F/\($0).app") } }
        XCTAssertEqual(Companions.mainApp(of: apps(["Acrobat Distiller", "Adobe Acrobat", "Acrobat Uninstaller"]), label: "Adobe Acrobat DC", isFolder: true)?.name, "Adobe Acrobat")
        XCTAssertEqual(Companions.mainApp(of: apps(["Burn"]) + apps(["Burn Helper"]), label: "Burn.localized", isFolder: true)?.name, "Burn")
        XCTAssertEqual(Companions.mainApp(of: apps(["Skint", "SkintM"]), label: "skint109", isFolder: true)?.name, "Skint")
        XCTAssertNil(Companions.mainApp(of: apps(["jbrk", "jqt", "jcon"]), label: "j9.7", isFolder: true))
        XCTAssertNil(Companions.mainApp(of: apps(["Wacom Center", "Wacom Tablet Utility"]), label: "Wacom Tablet.localized", isFolder: true))
        XCTAssertNil(Companions.mainApp(of: apps(["Microsoft Word", "Microsoft Excel"]), label: "Microsoft Office 2011", isFolder: true))
    }

    /// Each item in one plan only: a companion keeps its own bundle, and what an earlier plan
    /// deletes (or a folder holding it) isn't repeated.
    func testGroupPlansShareNothing() {
        func plan(_ name: String, _ paths: [String], packages: [String] = []) -> RemovalPlan {
            RemovalPlan(application: app(name, id: "com.vendor.\(name.lowercased())", path: "/Applications/\(name).app"), identifiers: [], findings: paths.map { Finding(path: $0, tier: .exact) },
                        skipped: [], launchItems: [], packages: packages, unreadable: [], notes: [], running: false, homebrewCask: nil)
        }
        let main = plan("Main", ["/Applications/Main.app", "/Applications/Helper.app", "/Library/Vendor/Shared"], packages: ["com.vendor.pkg"])
        let helper = plan("Helper", ["/Applications/Helper.app", "/Library/Vendor/Shared/cache", "/Users/me/Library/Caches/com.vendor.helper"], packages: ["com.vendor.pkg"])
        let result = RemovalPlan.deduplicated([main, helper])
        XCTAssertEqual(result[0].findings.map(\.path), ["/Applications/Main.app", "/Library/Vendor/Shared"])
        XCTAssertEqual(result[1].findings.map(\.path), ["/Applications/Helper.app", "/Users/me/Library/Caches/com.vendor.helper"])
        XCTAssertEqual(result[1].packages, [])
    }

    func testFingerprintChangesWithWhatIsDeleted() {
        var plan = RemovalPlan(application: app("Main", id: "com.vendor.main", path: "/Applications/Main.app"), identifiers: [], findings: [Finding(path: "/Applications/Main.app", tier: .exact)],
                               skipped: [], launchItems: [], packages: [], unreadable: [], notes: [], running: false, homebrewCask: nil)
        let before = RemovalPlan.fingerprint([plan], includeNameMatches: false)
        plan.findings.append(Finding(path: "/Users/me/.main", tier: .name))
        XCTAssertEqual(RemovalPlan.fingerprint([plan], includeNameMatches: false), before, "a name match not selected changes nothing")
        XCTAssertNotEqual(RemovalPlan.fingerprint([plan], includeNameMatches: true), before)
        plan.packages = ["com.vendor.pkg"]
        XCTAssertNotEqual(RemovalPlan.fingerprint([plan], includeNameMatches: false), before)
    }

    func testCompanionAndSudoRerunOptions() throws {
        let invocation = try Invocation(arguments: ["--approved", "abc123", "--no-companions", "--", "/Applications/Main.app"])
        XCTAssertEqual(invocation.command, .remove("/Applications/Main.app"))
        XCTAssertEqual(invocation.approved, "abc123")
        XCTAssertFalse(invocation.withCompanions)
        XCTAssertTrue(try Invocation(arguments: ["Main"]).withCompanions)
        XCTAssertThrowsError(try Invocation(arguments: ["--approved"]))
        XCTAssertThrowsError(try Invocation(arguments: ["--approved", "abc", "--dry-run", "Main"]))
        XCTAssertThrowsError(try Invocation(arguments: ["list", "--no-companions"]))
    }
}
