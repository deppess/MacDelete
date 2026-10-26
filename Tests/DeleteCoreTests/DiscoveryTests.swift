import Foundation
import XCTest
@testable import DeleteCore

final class ScannerTests: XCTestCase {
    func testFindsTopLevelAppsAndSkipsNestedOnes() throws {
        let system = try FakeSystem()
        try system.makeApp("Raycast.app", metadata: ["CFBundleIdentifier": "com.raycast.macos", "CFBundleShortVersionString": "1.98.2", "CFBundleName": "Raycast"])
        try system.makeApp("DaVinci Resolve/DaVinci Resolve.app", metadata: ["CFBundleIdentifier": "com.blackmagic-design.DaVinciResolve"])
        try system.makeApp("Raycast.app/Contents/Library/LoginItems/Helper.app", metadata: ["CFBundleIdentifier": "com.raycast.helper"])
        try system.makeApp("Tool.framework/Versions/A/Resources/Inner.app", metadata: ["CFBundleIdentifier": "com.example.inner"])
        try FileManager.default.createDirectory(at: system.applications.appending(path: "Empty.app"), withIntermediateDirectories: true)
        try system.makeApp(".Hidden.app", metadata: ["CFBundleIdentifier": "com.example.hidden"])

        let result = AppScanner(roots: system.roots).scan()
        XCTAssertTrue(result.complete, result.warnings.joined())
        XCTAssertEqual(result.applications.map(\.name).sorted(), ["DaVinci Resolve", "Raycast"])
        let raycast = try XCTUnwrap(result.applications.first { $0.name == "Raycast" })
        XCTAssertEqual(raycast.bundleIdentifier, "com.raycast.macos")
        XCTAssertEqual(raycast.version, "1.98.2")
        XCTAssertEqual(raycast.alternateNames, [], "a CFBundleName equal to the file name is not an alternate")
        XCTAssertEqual(raycast.classification, .user)
    }

    func testLinkedBundleIsClassifiedByWhereItLivesAndCountedOnce() throws {
        let system = try FakeSystem()
        let real = try system.makeApp("Safari.app", in: system.systemApplications, metadata: ["CFBundleIdentifier": "com.apple.Safari"])
        try FileManager.default.createSymbolicLink(at: system.applications.appending(path: "Safari.app"), withDestinationURL: real)

        let applications = AppScanner(roots: system.roots).scan().applications
        XCTAssertEqual(applications.count, 1, "the link and its destination are one bundle")
        XCTAssertEqual(applications.first?.classification, .system)
    }

    func testReadsAlternateNamesIOSWrappersAndSteamShortcuts() throws {
        let system = try FakeSystem()
        try system.makeApp("Visual Studio Code.app", metadata: ["CFBundleIdentifier": "com.microsoft.VSCode", "CFBundleName": "Code"])

        let wrapper = system.applications.appending(path: "Pocket Game.app", directoryHint: .isDirectory)
        let inner = wrapper.appending(path: "Wrapper/PocketGame.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.pocketgame", "CFBundleShortVersionString": "2.0"], format: .xml, options: 0).write(to: inner.appending(path: "Info.plist"))
        try FileManager.default.createSymbolicLink(atPath: wrapper.appending(path: "WrappedBundle").path, withDestinationPath: "Wrapper/PocketGame.app")

        let shortcut = try system.makeApp("Balatro.app", in: system.home.appending(path: "Applications"), metadata: ["CFBundleExecutable": "run.sh"])
        try system.write("#!/bin/sh\nopen steam://run/2379780\n", to: shortcut.appending(path: "Contents/MacOS/run.sh"), executable: true)

        let applications = AppScanner(roots: system.roots).scan().applications
        let code = try XCTUnwrap(applications.first { $0.name == "Visual Studio Code" })
        XCTAssertEqual(code.alternateNames, ["Code"])
        let pocket = try XCTUnwrap(applications.first { $0.name == "Pocket Game" })
        XCTAssertTrue(pocket.isIOSApp)
        XCTAssertTrue(pocket.hasAppStoreReceipt)
        XCTAssertEqual(pocket.version, "2.0")
        XCTAssertTrue(try XCTUnwrap(applications.first { $0.name == "Balatro" }).isSteamShortcut)
    }

    func testMissingRequiredRootMakesTheScanIncomplete() throws {
        let system = try FakeSystem()
        try FileManager.default.removeItem(at: system.systemApplications)
        let result = AppScanner(roots: system.roots).scan()
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.warnings.count, 1)
    }
}

final class SourceTests: XCTestCase {
    func testCaskroomReceiptsGiveAppsTargetsSuitesAndPackages() throws {
        let system = try FakeSystem()
        let metadata = system.homebrew.appending(path: "Caskroom/raycast/.metadata")
        try system.writeJSON(["source": ["version": "1.98.2"], "uninstall_artifacts": [
            ["app": ["Raycast.app"]],
            ["app": ["Nested/Other.app", ["target": "Renamed.app"]]],
            ["suite": ["Raycast Tools"]],
            ["uninstall": [["pkgutil": ["com.raycast.pkg", "com.raycast.driver.*"], "quit": "com.raycast.macos"]]],
        ]], to: metadata.appending(path: "INSTALL_RECEIPT.json"))
        try system.writeJSON(["default": ["appdir": "~/Applications"]], to: metadata.appending(path: "config.json"))

        let casks = Caskroom.installedCasks(prefixes: [system.homebrew], home: system.home)
        XCTAssertEqual(casks.count, 1)
        let cask = try XCTUnwrap(casks.first)
        XCTAssertEqual(cask.version, "1.98.2")
        XCTAssertEqual(cask.appPaths, [system.home.appending(path: "Applications/Raycast.app").path, system.home.appending(path: "Applications/Renamed.app").path])
        XCTAssertEqual(cask.suitePaths, [system.home.appending(path: "Applications/Raycast Tools").path])
        XCTAssertEqual(cask.packagePatterns, ["com.raycast.pkg", "com.raycast.driver.*"])
        XCTAssertTrue(Caskroom.package("com.raycast.driver.hid", matches: "com.raycast.driver.*"))
        XCTAssertFalse(Caskroom.package("com.raycast.pkgextra", matches: "com.raycast.pkg"))
    }

    func testCaskWithoutAppdirConfigUsesApplications() throws {
        let system = try FakeSystem()
        try system.writeJSON(["uninstall_artifacts": [["app": ["GIMP.app"]]]], to: system.homebrew.appending(path: "Caskroom/gimp/.metadata/INSTALL_RECEIPT.json"))
        XCTAssertEqual(Caskroom.installedCasks(prefixes: [system.homebrew], home: system.home).first?.appPaths, ["/Applications/GIMP.app"])
    }

    func testBOMListingYieldsTopLevelApplications() {
        let listing = Data(".\n./Applications\n./Applications/Vital.app\n./Applications/Vital.app/Contents\n./Applications/Vital.app/Contents/Helpers/Helper.app\n./Applications/DaVinci Resolve/DaVinci Resolve.app\n./Library/Audio\n".utf8)
        XCTAssertEqual(PackageReceipts.applicationPaths(bomOutput: listing, installPrefix: "/"), ["/Applications/Vital.app", "/Applications/DaVinci Resolve/DaVinci Resolve.app"])
        XCTAssertEqual(PackageReceipts.applicationPaths(bomOutput: Data(".\n./Contents\n".utf8), installPrefix: "Applications/FL Cloud Plugins.app"), ["/Applications/FL Cloud Plugins.app"])
    }

    func testReceiptsSkipApplePackagesAndMapAppsToPackages() throws {
        let system = try FakeSystem()
        for identifier in ["audio.vital.synth", "com.apple.pkg.Xcode"] {
            try PropertyListSerialization.data(fromPropertyList: ["PackageIdentifier": identifier, "InstallPrefixPath": "/"], format: .xml, options: 0).write(to: system.receipts.appending(path: "\(identifier).plist"))
            try system.write("", to: system.receipts.appending(path: "\(identifier).bom"))
        }
        let lsbom = system.root.appending(path: "bin/lsbom")
        try system.write("#!/bin/sh\ncase \"$3\" in *Xcode*) printf './Applications/Xcode.app\\n';; *) printf './Applications/Vital.app\\n';; esac\n", to: lsbom, executable: true)

        let receipts = PackageReceipts.read(directory: system.receipts, lsbom: lsbom)
        XCTAssertEqual(receipts.packages(for: "/Applications/Vital.app"), ["audio.vital.synth"])
        XCTAssertEqual(receipts.packages(for: "/applications/vital.app"), ["audio.vital.synth"], "paths compare case-insensitively")
        XCTAssertEqual(receipts.packages(for: "/Applications/Xcode.app"), [], "Apple's packages are skipped")
    }

    func testSourcePriority() {
        let cask = InstalledCask(token: "raycast", prefix: "/opt/homebrew", version: nil, appPaths: ["/Applications/Raycast.app"], suitePaths: [], packagePatterns: ["org.pqrs.*"])
        let receipts = PackageReceipts(packagesByApplication: ["/applications/karabiner-elements.app": ["org.pqrs.Karabiner-Elements"], "/applications/vital.app": ["audio.vital.synth"]])
        func source(_ application: InstalledApp) -> AppSource { Inventory.source(of: application, casks: [cask], receipts: receipts) }

        XCTAssertEqual(source(app("Raycast")), .homebrew(token: "raycast", declared: true))
        XCTAssertEqual(source(app("Karabiner-Elements")), .homebrew(token: "raycast", declared: true), "installed by a package the cask names")
        var linked = app("Claude Code URL Handler", path: "/Users/tester/Applications/Claude Code URL Handler.app")
        linked.linkTargets = ["/opt/homebrew/Caskroom/raycast/2.1/claude"]
        XCTAssertEqual(source(linked), .homebrew(token: "raycast", declared: false))
        var store = app("Xcode")
        store.hasAppStoreReceipt = true
        XCTAssertEqual(source(store), .appStore)
        XCTAssertEqual(source(app("Balatro", path: "/Users/tester/Library/Application Support/Steam/steamapps/common/Balatro/Balatro.app")), .steam)
        XCTAssertEqual(source(app("CleanMyMac", path: "/Applications/Setapp/CleanMyMac.app")), .setapp)
        XCTAssertEqual(source(app("IDLE", path: "/Applications/MacPorts/Python 3.14/IDLE.app")), .macPorts)
        XCTAssertEqual(source(app("Vital")), .installerPackage(identifiers: ["audio.vital.synth"]))
        XCTAssertEqual(source(app("AltTab")), .download)
        XCTAssertEqual(source(app("Safari", classification: .system)), .macOS)
    }

    func testInventoryCombinesEverything() throws {
        let system = try FakeSystem()
        try system.makeApp("GIMP.app", metadata: ["CFBundleIdentifier": "org.gimp.gimp-3.2"])
        try system.makeApp("AltTab.app", metadata: ["CFBundleIdentifier": "com.lwouis.alt-tab-macos"])
        try system.write(String(repeating: "x", count: 10_000), to: system.applications.appending(path: "AltTab.app/Contents/MacOS/AltTab"))
        try system.writeJSON(["uninstall_artifacts": [["app": ["GIMP.app"]]]], to: system.homebrew.appending(path: "Caskroom/gimp/.metadata/INSTALL_RECEIPT.json"))
        try system.writeJSON(["default": ["appdir": system.applications.path]], to: system.homebrew.appending(path: "Caskroom/gimp/.metadata/config.json"))

        let inventory = Inventory.load(roots: system.roots)
        XCTAssertEqual(inventory.applications.first { $0.name == "GIMP" }?.source, .homebrew(token: "gimp", declared: true))
        XCTAssertEqual(inventory.applications.first { $0.name == "AltTab" }?.source, .download)
        XCTAssertGreaterThanOrEqual(inventory.applications.first { $0.name == "AltTab" }?.size ?? 0, 10_000, "sizes Spotlight lacks are walked")
    }
}

final class MatcherTests: XCTestCase {
    let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
    let applications = [
        app("Raycast", id: "com.raycast.macos"),
        app("Visual Studio Code", id: "com.microsoft.VSCode", alternateNames: ["Code"]),
        app("Codex", id: "com.openai.codex"),
        app("Safari", id: "com.apple.Safari", classification: .system),
        app("Watchdog", id: "dev.watchdog", path: "/Users/tester/Projects/watchdog/dist/Watchdog.app", classification: .auxiliary),
        app("Watchdog", id: "dev.watchdog"),
        app("Settings Helper", id: "com.example.settingshelper", path: "/Library/Application Support/Example/Settings Helper.app", classification: .auxiliary),
    ]

    func name(_ result: MatchResult) -> String? {
        if case let .found(application) = result { return application.path }
        return nil
    }

    func testExactNamesIdentifiersAndExtensions() {
        XCTAssertEqual(name(AppMatcher.match("raycast", in: applications, home: home)), "/Applications/Raycast.app")
        XCTAssertEqual(name(AppMatcher.match("Raycast.app", in: applications, home: home)), "/Applications/Raycast.app")
        XCTAssertEqual(name(AppMatcher.match("COM.RAYCAST.MACOS", in: applications, home: home)), "/Applications/Raycast.app")
        XCTAssertEqual(name(AppMatcher.match("code", in: applications, home: home)), "/Applications/Visual Studio Code.app", "an exact alternate name beats the Codex prefix")
        XCTAssertEqual(name(AppMatcher.match("safari", in: applications, home: home)), "/Applications/Safari.app", "found, so the caller can refuse it by name")
    }

    func testInstalledAppOutranksSameNamedCopy() {
        XCTAssertEqual(name(AppMatcher.match("watchdog", in: applications, home: home)), "/Applications/Watchdog.app")
    }

    func testPrefixesMustBeUniqueAndOnlyCoverUserApps() {
        XCTAssertEqual(name(AppMatcher.match("ray", in: applications, home: home)), "/Applications/Raycast.app")
        guard case let .ambiguous(candidates) = AppMatcher.match("co", in: applications, home: home) else { return XCTFail("expected ambiguity") }
        XCTAssertEqual(Set(candidates.map(\.name)), ["Visual Studio Code", "Codex"])
        guard case .notFound = AppMatcher.match("settings", in: applications, home: home) else { return XCTFail("a prefix never lands on a helper") }
        guard case .notFound = AppMatcher.match("nothing", in: applications, home: home) else { return XCTFail() }
    }

    /// Without the question (-y), a prefix never picks the app.
    func testPrefixesAreRefusedWhenThereIsNoQuestion() {
        guard case let .prefixOnly(application) = AppMatcher.match("ray", in: applications, home: home, allowPrefix: false) else { return XCTFail("expected a refused prefix") }
        XCTAssertEqual(application.name, "Raycast")
        XCTAssertEqual(name(AppMatcher.match("raycast", in: applications, home: home, allowPrefix: false)), "/Applications/Raycast.app", "the full name still works")
        XCTAssertEqual(name(AppMatcher.match("com.raycast.macos", in: applications, home: home, allowPrefix: false)), "/Applications/Raycast.app")
        guard case .ambiguous = AppMatcher.match("co", in: applications, home: home, allowPrefix: false) else { return XCTFail("ambiguity is still reported") }
    }

    func testTheSameNameInTwoUserFoldersIsAmbiguous() {
        let twins = [app("Notes Pro", id: "com.example.notes"), app("Notes Pro", id: "com.example.notes", path: "/Users/tester/Applications/Notes Pro.app")]
        guard case let .ambiguous(candidates) = AppMatcher.match("notes pro", in: twins, home: home) else { return XCTFail("expected ambiguity") }
        XCTAssertEqual(candidates.count, 2)
        guard case .ambiguous = AppMatcher.match("com.example.notes", in: twins, home: home) else { return XCTFail("the identifier is shared too") }
        XCTAssertEqual(name(AppMatcher.match("/Users/tester/Applications/Notes Pro.app", in: twins, home: home)), "/Users/tester/Applications/Notes Pro.app", "a path settles it")
    }

    func testWhitespaceIsTrimmedAndIdentifiersNeedTheWholeIdentifier() {
        XCTAssertEqual(name(AppMatcher.match("  Raycast \n", in: applications, home: home)), "/Applications/Raycast.app")
        guard case .notFound = AppMatcher.match("com.raycast", in: applications, home: home) else { return XCTFail("an identifier prefix isn't a match") }
        guard case .notFound = AppMatcher.match("   ", in: applications, home: home) else { return XCTFail() }
        guard case .notFound = AppMatcher.match("saf", in: applications, home: home) else { return XCTFail("a prefix never lands on a system app") }
    }

    func testPaths() throws {
        let system = try FakeSystem()
        let url = try system.makeApp("Loose.app", in: system.home.appending(path: "Downloads"), metadata: ["CFBundleIdentifier": "com.example.loose"])
        guard case let .found(application) = AppMatcher.match("~/Downloads/Loose.app", in: [], home: system.home) else { return XCTFail("a bundle outside the scan is read directly") }
        XCTAssertEqual(application.path, url.standardizedFileURL.path)
        XCTAssertEqual(application.bundleIdentifier, "com.example.loose")
        XCTAssertEqual(application.classification, .auxiliary)
        guard case .notFound = AppMatcher.match(system.home.appending(path: "Downloads").path, in: [], home: system.home) else { return XCTFail("a folder isn't an app") }
    }
}
