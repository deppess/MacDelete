import Darwin
import Foundation
import XCTest
@testable import DeleteCore

/// Hostile and broken input: every source of evidence is data from somewhere else (receipts,
/// zap lists, plists, file names), so none of it may widen what's selected.
final class RobustnessTests: XCTestCase {
    func selectedPaths(_ plan: RemovalPlan) -> [String] { plan.selected(includeNameMatches: true).map(\.path) }

    /// Nothing protected, nothing containing the user's home, nothing that is a standard folder.
    func assertSafe(_ plan: RemovalPlan, _ system: FakeSystem, file: StaticString = #filePath, line: UInt = #line) {
        let roots = system.roots
        for finding in plan.selected(includeNameMatches: true) where !plan.isOwn(finding) {
            XCTAssertFalse(Protection.isProtected(finding.path, roots: roots), "protected: \(finding.path)", file: file, line: line)
            XCTAssertFalse(system.home.path.hasPrefix(finding.path + "/") || finding.path == system.home.path, "contains home: \(finding.path)", file: file, line: line)
            XCTAssertFalse(Remover.isNeverDeletable(String(finding.path.dropFirst(system.root.path.count)), home: system.home, root: system.root.path), "never deletable: \(finding.path)", file: file, line: line)
        }
    }

    func makeCask(_ system: FakeSystem, zap: [String: Any]) throws {
        try system.makeApp("Example.app", metadata: ["CFBundleIdentifier": "com.example.app"])
        let metadata = system.homebrew.appending(path: "Caskroom/example/.metadata")
        try system.writeJSON(["uninstall_artifacts": [["app": ["Example.app"]], ["zap": [zap]]]], to: metadata.appending(path: "INSTALL_RECEIPT.json"))
        try system.writeJSON(["default": ["appdir": system.applications.path]], to: metadata.appending(path: "config.json"))
    }

    /// A zap list is the cask maintainers' data. Broad patterns must not sweep up everything.
    func testHostileZapListsSelectNothingBroad() throws {
        let system = try FakeSystem()
        for folder in ["Users/tester/Library/Application Support/com.other.app/", "Users/tester/Library/Application Support/Precious/", "Users/tester/Library/Preferences/com.other.app.plist",
                       "Users/tester/Documents/thesis.txt", "Users/tester/Library/Caches/com.other.cache/", "Users/tester/.ssh/id_ed25519", "Users/tester/Library/Application Support/com.example.app/data"] {
            try system.touch(folder)
        }
        try system.makeApp("Other.app", metadata: ["CFBundleIdentifier": "com.other.app"])
        try makeCask(system, zap: ["trash": ["~", "~/", "~/Library", "~/Library/*", "~/Library/Application Support/*", "~/Library/Preferences/*.plist", "~/Library/Caches/*",
                                             "/", "/Applications", "/Applications/*", "~/Documents", "~/Documents/*", "~/.ssh", "~/../../etc", "~/Library/Application Support/../../Documents",
                                             "~/Library/Application Support/com.example.app"],
                                   "delete": ["/Library", "/Library/*", "/usr", "~/Library/Application Support/?"]])
        let plan = try system.plan("Example")
        assertSafe(plan, system)
        let paths = selectedPaths(plan).map { $0.replacingOccurrences(of: system.root.path + "/", with: "") }
        XCTAssertEqual(Set(paths), ["Applications/Example.app", "Users/tester/Library/Application Support/com.example.app"], "only the specific item survives")
    }

    /// An installer receipt listing system folders, the home folder or everything in /Library.
    func testHostileReceiptsSelectOnlyOwnedItems() throws {
        let system = try FakeSystem()
        try system.makeApp("Suite.app", metadata: ["CFBundleIdentifier": "com.vendor.suite"])
        try system.touch("Library/Application Support/Vendor Suite/data")
        try system.touch("Library/Fonts/Other.otf")
        try system.touch("Users/tester/notes.txt")
        try system.writePlist(["PackageIdentifier": "com.vendor.pkg.suite", "InstallPrefixPath": system.root.path], to: system.receipts.appending(path: "com.vendor.pkg.suite.plist"))
        try system.write("", to: system.receipts.appending(path: "com.vendor.pkg.suite.bom"))
        try system.write("#!/bin/sh\nprintf 'pkgid: com.vendor.pkg.suite\\n'\n", to: system.tools.appending(path: "pkgutil"), executable: true)
        try system.write("""
        #!/bin/sh
        case "$*" in *-d*) exit 0 ;; esac
        printf '.\\n./Applications\\n./Applications/Suite.app\\n./Library\\n./Library/Application Support\\n./Library/Application Support/Vendor Suite\\n./Library/Fonts\\n./Library/LaunchDaemons\\n./Users\\n./Users/tester\\n./System\\n./System/Library\\n./usr\\n./usr/local\\n./usr/local/bin\\n./private/var\\n./Library/../Users/tester\\n'
        """, to: system.tools.appending(path: "lsbom"), executable: true)

        let plan = try system.plan("Suite")
        assertSafe(plan, system)
        let paths = Set(selectedPaths(plan).map { $0.replacingOccurrences(of: system.root.path + "/", with: "") })
        XCTAssertEqual(paths, ["Applications/Suite.app", "Library/Application Support/Vendor Suite"], "\(paths)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: system.root.appending(path: "Library/Fonts/Other.otf").path))
    }

    /// Launch items whose programs point at folders, the root, or relative paths.
    func testHostileLaunchItemProgramsSelectNoFolders() throws {
        let system = try FakeSystem()
        try system.makeApp("Example.app", metadata: ["CFBundleIdentifier": "com.example.app"])
        try system.touch("Library/PrivilegedHelperTools/other-helper")
        try system.touch("Library/Application Support/Shared Vendor/Other/thing")
        let agents = system.userLibrary.appending(path: "LaunchAgents")
        let programs = ["/", system.library.appending(path: "PrivilegedHelperTools").path + "/", system.library.appending(path: "Application Support").path,
                        system.library.appending(path: "Application Support/Shared Vendor").path, system.home.path, "relative/path", "../../etc/passwd"]
        for (index, program) in programs.enumerated() {
            try system.writePlist(["Label": "com.example.app.job\(index)", "Program": program], to: agents.appending(path: "com.example.app.job\(index).plist"))
        }
        let plan = try system.plan("Example")
        assertSafe(plan, system)
        XCTAssertEqual(plan.launchItems.count, programs.count, "the jobs are the app's by label")
        let paths = Set(selectedPaths(plan).map { $0.replacingOccurrences(of: system.root.path + "/", with: "") })
        XCTAssertEqual(paths, Set(["Applications/Example.app"] + programs.indices.map { "Users/tester/Library/LaunchAgents/com.example.app.job\($0).plist" }), "\(paths)")
    }

    /// A copy carrying an Apple app's identifier is refused outright: Safari's data is never in reach.
    /// A third-party copy of another installed app's identifier shares, so takes nothing.
    func testSpoofedIdentifiersClaimNothing() throws {
        let system = try FakeSystem()
        try system.makeApp("Safari.app", in: system.systemApplications, metadata: ["CFBundleIdentifier": "com.apple.Safari"])
        try system.makeApp("Not Safari.app", metadata: ["CFBundleIdentifier": "com.apple.Safari"])
        XCTAssertThrowsError(try system.plan("Not Safari"))
        try system.makeApp("Raycast.app", metadata: ["CFBundleIdentifier": "com.raycast.macos"])
        try system.makeApp("Free Raycast.app", in: system.home.appending(path: "Applications"), metadata: ["CFBundleIdentifier": "com.raycast.macos"])
        try system.touch("Users/tester/Library/Preferences/com.raycast.macos.plist")
        let plan = try system.plan("Free Raycast")
        XCTAssertEqual(plan.selected(includeNameMatches: true).map(\.path), [system.home.appending(path: "Applications/Free Raycast.app").path])
        XCTAssertTrue(plan.skipped.contains { $0.path.hasSuffix("com.raycast.macos.plist") })
    }

    func testZapPatternsMustBeSpecific() {
        for broad in ["~/Library/Caches/*", "~/Library/Preferences/*.plist", "*", "~/Library/Application Support/?", "~/Library/[a-z]*", "~/Library/Application Support/ab*/x",
                      "~/Library/*/com.vendor.app", "~/Library/Logs/*.savedState", "~/Library/Preferences/Adobe/.[A-Z0-9]???????????", "/Library/Application Support/Adobe/SL*"] {
            XCTAssertFalse(HomebrewZap.isSpecific(broad), broad)
        }
        for specific in ["~/Library/Caches/com.vendor.app", "~/Library/Preferences/com.vendor.*", "~/Library/Application Support/Vendor*", "/Library/Logs/DiagnosticReports/Vendor_*.crash",
                         "~/Library/Group Containers/*.com.adguard.mac", "~/Library/Preferences/*1password.plist", "~/Library/Caches/*.CodeEdit", "~/Library/Application Support/CrashReporter/Live_*.plist",
                         "~/Library/Application Support/Arq *", "~/.claude.json*"] {
            XCTAssertTrue(HomebrewZap.isSpecific(specific), specific)
        }
    }

    /// Identifiers are data too: path-like or one-word ones reach nothing outside their folders.
    func testOddIdentifiersReachNothingOutside() throws {
        for identifier in ["../../..", "..", ".", "*", "com", "Caches", "Library", "", " ", "com.example/../../Documents", "com.example.app\n"] {
            let system = try FakeSystem()
            try system.makeApp("Odd.app", metadata: ["CFBundleIdentifier": identifier])
            try system.touch("Users/tester/Documents/thesis.txt")
            try system.touch("Users/tester/Library/Caches/com.other/")
            let plan = try system.plan("Odd")
            assertSafe(plan, system)
            let outside = plan.selected(includeNameMatches: true).filter { !plan.isOwn($0) && !$0.path.contains("/Library/") }
            XCTAssertTrue(outside.isEmpty, "\(identifier.debugDescription): \(outside.map(\.path))")
            XCTAssertTrue(FileManager.default.fileExists(atPath: system.home.appending(path: "Documents/thesis.txt").path))
        }
    }

    /// Broken metadata never stops the scan or crashes it; the rest of the apps are still found.
    func testBrokenBundlesDontBreakTheScan() throws {
        let system = try FakeSystem()
        try system.makeApp("Good.app", metadata: ["CFBundleIdentifier": "com.example.good"])
        try system.write("not a plist \u{0}\u{1}", to: system.applications.appending(path: "Garbage.app/Contents/Info.plist"))
        try system.writePlist(["CFBundleIdentifier": ["an", "array"], "CFBundleName": 42, "CFBundleShortVersionString": ["1"]], to: system.applications.appending(path: "Typed.app/Contents/Info.plist"))
        try system.write(String(repeating: "x", count: 2_000_000), to: system.applications.appending(path: "Huge.app/Contents/Info.plist"))
        try FileManager.default.createDirectory(at: system.applications.appending(path: "Empty.app/Contents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: system.applications.appending(path: "Loop.app"), withDestinationURL: system.applications.appending(path: "Loop.app"))
        try FileManager.default.createSymbolicLink(at: system.applications.appending(path: "Dangling.app"), withDestinationURL: system.root.appending(path: "nowhere.app"))
        try system.makeApp("Weird\nName\u{1B}[31m.app", metadata: ["CFBundleIdentifier": "com.example.weird"])

        let inventory = Inventory.load(roots: system.roots, sizes: false)
        let names = Set(inventory.applications.map(\.name))
        XCTAssertTrue(names.contains("Good"))
        XCTAssertTrue(names.contains("Typed"), "wrong types are ignored, not fatal")
        XCTAssertFalse(names.contains("Huge"))
        let text = ListRenderer.text(inventory.applications, home: system.home)
        XCTAssertFalse(text.contains("\u{1B}"), "control characters never reach the terminal")
    }

    /// A leftover that's a link is removed as a link; where it points is never touched.
    func testALinkedLeftoverRemovesOnlyTheLink() throws {
        let system = try FakeSystem()
        try system.makeApp("Example.app", metadata: ["CFBundleIdentifier": "com.example.app"])
        try system.touch("Users/tester/Documents/thesis.txt")
        let link = system.userLibrary.appending(path: "Caches/com.example.app")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: system.home.appending(path: "Documents"))
        let plan = try system.plan("Example")
        let report = Executor(actions: RecordingSystemActions(), allowedRoot: system.root.path, home: system.home)
            .run(plan, targets: Executor.targets(for: plan.selected(includeNameMatches: false)), isRoot: false, casks: [])
        XCTAssertNil(report.stopped)
        XCTAssertNil(FileIdentity.of(link.path), "the link is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: system.home.appending(path: "Documents/thesis.txt").path), "what it pointed to is not")
    }

    /// A folder swapped for a link between the question and the deletion is refused.
    func testAFolderSwappedForALinkAfterTheQuestionIsLeftAlone() throws {
        let system = try FakeSystem()
        try system.makeApp("Example.app", metadata: ["CFBundleIdentifier": "com.example.app"])
        try system.touch("Users/tester/Library/Caches/com.example.app/cache")
        try system.touch("Users/tester/Documents/thesis.txt")
        let plan = try system.plan("Example")
        let targets = Executor.targets(for: plan.selected(includeNameMatches: false))
        let caches = system.userLibrary.appending(path: "Caches/com.example.app")
        try FileManager.default.removeItem(at: caches)
        try FileManager.default.createSymbolicLink(at: caches, withDestinationURL: system.home.appending(path: "Documents"))
        let report = Executor(actions: RecordingSystemActions(), allowedRoot: system.root.path, home: system.home).run(plan, targets: targets, isRoot: false, casks: [])
        XCTAssertTrue(report.failed.contains { $0.finding.path == caches.path && $0.reason.contains("changed") }, "\(report.failed)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: system.home.appending(path: "Documents/thesis.txt").path))
    }

    /// Thousands of files, deep nesting and unusual names are removed completely.
    func testLargeDeepAndOddlyNamedTreesAreRemovedCompletely() throws {
        let system = try FakeSystem()
        try system.makeApp("Example.app", metadata: ["CFBundleIdentifier": "com.example.app"])
        let base = system.userLibrary.appending(path: "Application Support/com.example.app")
        var deep = base
        for level in 0..<60 { deep = deep.appending(path: "level\(level)") }
        try system.write("bottom", to: deep.appending(path: "file"))
        for index in 0..<3000 { try system.write("\(index)", to: base.appending(path: "bulk/\(index % 30)/file\(index)")) }
        for name in ["new\nline", "tab\there", " leading space", "émoji 🎉", "-dash", "*star*", "back\\slash", String(repeating: "n", count: 255)] {
            try system.write("odd", to: base.appending(path: "odd/\(name)"))
        }
        let readOnly = base.appending(path: "readonly")
        try system.write("locked", to: readOnly.appending(path: "file"))
        XCTAssertEqual(chmod(readOnly.appending(path: "file").path, 0o444), 0)

        let plan = try system.plan("Example")
        let report = Executor(actions: RecordingSystemActions(), allowedRoot: system.root.path, home: system.home)
            .run(plan, targets: Executor.targets(for: plan.selected(includeNameMatches: false)), isRoot: false, casks: [])
        XCTAssertNil(report.stopped)
        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
    }
}
