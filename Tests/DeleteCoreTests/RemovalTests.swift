import Darwin
import Foundation
import XCTest
@testable import DeleteCore

/// The error a removal ended with, or nil when it succeeded.
func failure(_ result: Result<Void, RemovalError>) -> RemovalError? {
    if case let .failure(error) = result { return error }
    return nil
}

final class RemoverTests: XCTestCase {
    func target(_ url: URL) throws -> RemovalTarget {
        RemovalTarget(path: url.path, identity: try XCTUnwrap(FileIdentity.of(url.path)))
    }

    func testRemovesATreeWithoutFollowingLinks() throws {
        let system = try FakeSystem()
        let folder = try system.touch("Users/tester/Library/Caches/com.example.app/")
        try system.touch("Users/tester/Library/Caches/com.example.app/nested/deep/file")
        let outside = try system.touch("Users/tester/Documents/precious.txt")
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "link-to-file"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "link-to-folder"), withDestinationURL: system.home.appending(path: "Documents"))

        XCTAssertNil(failure(Remover.remove(try target(folder), allowedRoot: system.root.path, home: system.home)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "a link's target is never deleted")
    }

    func testRefusesAPathReplacedSinceItWasConfirmed() throws {
        let system = try FakeSystem()
        let file = try system.touch("Users/tester/Library/Preferences/com.example.app.plist")
        let confirmed = try target(file)
        try FileManager.default.removeItem(at: file)
        try system.write("someone else's", to: file)
        XCTAssertEqual(failure(Remover.remove(confirmed, allowedRoot: system.root.path, home: system.home)), .changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // Replaced by a link to elsewhere: also refused, and the destination survives.
        let precious = try system.touch("Users/tester/Documents/precious.txt")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: precious)
        XCTAssertEqual(failure(Remover.remove(confirmed, allowedRoot: system.root.path, home: system.home)), .changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.path))
    }

    func testRefusesAnythingOutsideTheAllowedRoot() throws {
        let system = try FakeSystem()
        let other = try FakeSystem()
        let file = try other.touch("Users/tester/Library/Caches/com.example.app")
        XCTAssertEqual(failure(Remover.remove(try target(file), allowedRoot: system.root.path, home: system.home)), .outsideAllowedRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        var traversal = try target(file)
        traversal.path = system.root.path + "/Users/../../" + file.path
        XCTAssertEqual(failure(Remover.remove(traversal, allowedRoot: system.root.path, home: system.home)), .outsideAllowedRoot)
    }

    func testRefusesProtectedFoldersWhateverMatchedThem() throws {
        let system = try FakeSystem()
        for relative in ["Users/tester/Library/Caches/", "Users/tester/Library/", "Users/tester/Documents/", "Users/tester/Documents/notes/", "Library/LaunchDaemons/", "Applications/", "System/Library/"] {
            let url = try system.touch(relative)
            XCTAssertEqual(failure(Remover.remove(try target(url), allowedRoot: system.root.path, home: system.home)), .neverDeletable, relative)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), relative)
        }
        XCTAssertEqual(failure(Remover.remove(try target(system.home), allowedRoot: system.root.path, home: system.home)), .neverDeletable)
    }

    func testRefusesItemsReachedThroughALinkedFolder() throws {
        let system = try FakeSystem()
        let elsewhere = try system.touch("elsewhere/")
        let item = try system.touch("elsewhere/com.example.app/")
        try FileManager.default.createSymbolicLink(at: system.userLibrary.appending(path: "Logs"), withDestinationURL: elsewhere)
        let viaLink = system.userLibrary.appending(path: "Logs/com.example.app")
        let confirmed = RemovalTarget(path: viaLink.path, identity: try XCTUnwrap(FileIdentity.of(viaLink.path)))
        XCTAssertEqual(failure(Remover.remove(confirmed, allowedRoot: system.root.path, home: system.home)), .reachedThroughLink)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
    }
}

final class ExecutorTests: XCTestCase {
    func makeExample(_ system: FakeSystem) throws {
        try system.makeApp("Example.app", metadata: ["CFBundleIdentifier": "com.example.app"])
        try system.makeApp("Example Pro.app", metadata: ["CFBundleIdentifier": "com.example.app.pro"])
        try system.touch("Users/tester/Library/Application Support/com.example.app/data.db")
        try system.touch("Users/tester/Library/Preferences/com.example.app.plist")
        try system.touch("Users/tester/Library/Preferences/com.example.app.pro.plist")
        try system.touch("Users/tester/Library/Application Support/Example/settings")
        try system.touch("Users/tester/Documents/Example/project")
        try system.writePlist(["Label": "com.example.app.agent", "Program": "/usr/bin/true"], to: system.userLibrary.appending(path: "LaunchAgents/com.example.app.agent.plist"))
    }

    func testDeletesExactlyTheConfirmedItems() throws {
        let system = try FakeSystem()
        try makeExample(system)
        let plan = try system.plan("Example")
        let actions = RecordingSystemActions()
        let targets = Executor.targets(for: plan.selected(includeNameMatches: false))
        let report = Executor(actions: actions, allowedRoot: system.root.path, home: system.home).run(plan, targets: targets, isRoot: false, casks: [])

        XCTAssertNil(report.stopped)
        XCTAssertEqual(report.failed.count, 0, "\(report.failed)")
        XCTAssertEqual(Set(report.deleted.map { URL(filePath: $0.path).lastPathComponent }), ["Example.app", "com.example.app", "com.example.app.plist", "com.example.app.agent.plist"])
        for gone in ["Applications/Example.app", "Users/tester/Library/Application Support/com.example.app", "Users/tester/Library/Preferences/com.example.app.plist", "Users/tester/Library/LaunchAgents/com.example.app.agent.plist"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: system.root.appending(path: gone).path), gone)
        }
        for kept in ["Applications/Example Pro.app", "Users/tester/Library/Preferences/com.example.app.pro.plist", "Users/tester/Library/Application Support/Example/settings", "Users/tester/Documents/Example/project"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: system.root.appending(path: kept).path), kept)
        }
        XCTAssertEqual(actions.recorded.first, "launchctl bootout gui/<uid> \(system.userLibrary.appending(path: "LaunchAgents/com.example.app.agent.plist").path)", "launch items stop before anything is deleted")
        XCTAssertTrue(actions.recorded.contains("tccutil reset All com.example.app"))
        XCTAssertTrue(actions.recorded.contains { $0.hasPrefix("lsregister -u ") })
    }

    func testNameMatchesOnlyWhenAsked() throws {
        let system = try FakeSystem()
        try makeExample(system)
        let plan = try system.plan("Example")
        let targets = Executor.targets(for: plan.selected(includeNameMatches: true))
        _ = Executor(actions: RecordingSystemActions(), allowedRoot: system.root.path, home: system.home).run(plan, targets: targets, isRoot: false, casks: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: system.userLibrary.appending(path: "Application Support/Example").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: system.home.appending(path: "Documents/Example/project").path))
    }

    func testStopsWithTheDataIntactWhenTheAppCantBeDeleted() throws {
        let system = try FakeSystem()
        try makeExample(system)
        let plan = try system.plan("Example")
        let targets = Executor.targets(for: plan.selected(includeNameMatches: false))
        // The app's folder is read-only, so the app can't be removed.
        XCTAssertEqual(chmod(system.applications.appending(path: "Example.app/Contents").path, 0o555), 0)
        defer { chmod(system.applications.appending(path: "Example.app/Contents").path, 0o755) }

        let report = Executor(actions: RecordingSystemActions(), allowedRoot: system.root.path, home: system.home).run(plan, targets: targets, isRoot: false, casks: [])
        XCTAssertNotNil(report.stopped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: system.userLibrary.appending(path: "Preferences/com.example.app.plist").path), "the app's data stays when the app can't go")
    }

    func testAHomebrewFailureStopsBeforeAnythingIsDeleted() throws {
        final class FailingHomebrew: SystemActions, @unchecked Sendable {
            func quit(identifiers: [String], bundlePath: String) -> QuitResult { .quit }
            func bootout(_ item: LaunchItem) -> String? { nil }
            func uninstallCask(token: String, prefix: String) -> String? { "Error: Cask 'example' is not installed." }
            func forgetPackage(_ identifier: String) -> String? { nil }
            func resetPrivacy(_ identifier: String) -> String? { nil }
            func unregister(_ appPath: String) -> String? { nil }
        }
        let system = try FakeSystem()
        try makeExample(system)
        let metadata = system.homebrew.appending(path: "Caskroom/example/.metadata")
        try system.writeJSON(["uninstall_artifacts": [["app": ["Example.app"]]]], to: metadata.appending(path: "INSTALL_RECEIPT.json"))
        try system.writeJSON(["default": ["appdir": system.applications.path]], to: metadata.appending(path: "config.json"))
        let plan = try system.plan("Example")
        XCTAssertEqual(plan.homebrewCask, "example")
        let casks = Caskroom.installedCasks(prefixes: [system.homebrew], home: system.home)
        let report = Executor(actions: FailingHomebrew(), allowedRoot: system.root.path, home: system.home).run(plan, targets: Executor.targets(for: plan.selected(includeNameMatches: false)), isRoot: false, casks: casks)
        XCTAssertTrue(report.stopped?.contains("not installed") ?? false)
        XCTAssertTrue(report.deleted.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: system.applications.appending(path: "Example.app").path))
    }

    func testSandboxMapsEveryPathInsideItAndRefusesShallowFolders() throws {
        let system = try FakeSystem()
        let sandbox = try XCTUnwrap(Sandbox(path: system.root.path))
        XCTAssertTrue(sandbox.root.hasPrefix("/private/"), "the sandbox is fully resolved: \(sandbox.root)")
        XCTAssertEqual(sandbox.translate("/Applications/FL Studio 2026.app"), sandbox.root + "/Applications/FL Studio 2026.app")
        XCTAssertNil(Sandbox(path: "/"))
        XCTAssertNil(Sandbox(path: "/Users"))
        XCTAssertNil(Sandbox(path: "relative/path"))
    }

    /// A sandbox run deletes the clones, stops when the clone of the app can't go, and never
    /// touches the originals.
    func testSandboxRunDeletesOnlyTheClones() throws {
        let original = try FakeSystem()
        try makeExample(original)
        let plan = try original.plan("Example")
        let sandboxFolder = try FakeSystem()
        let sandbox = try XCTUnwrap(Sandbox(path: sandboxFolder.root.path))
        for finding in plan.selected(includeNameMatches: false) {
            let clone = sandbox.translate(finding.path)
            try FileManager.default.createDirectory(atPath: (clone as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: finding.path, toPath: clone)
        }
        let actions = RecordingSystemActions()
        let report = Executor(actions: actions, allowedRoot: sandbox.root, home: original.home)
            .run(sandbox.translate(plan), targets: Executor.targets(for: plan.selected(includeNameMatches: false), translate: sandbox.translate), isRoot: false, casks: [])
        XCTAssertNil(report.stopped)
        XCTAssertEqual(report.failed.count, 0, "\(report.failed)")
        XCTAssertEqual(report.deleted.count, 4)
        XCTAssertTrue(report.deleted.allSatisfy { !$0.path.hasPrefix(sandbox.root) }, "reported by their real paths")
        for finding in plan.selected(includeNameMatches: false) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: finding.path), "original kept: \(finding.path)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.translate(finding.path)), "clone deleted: \(finding.path)")
        }
    }

    func testJSONAndYesTogetherAreRejected() {
        XCTAssertThrowsError(try Invocation(arguments: ["Example", "--json", "-y"]))
        XCTAssertNoThrow(try Invocation(arguments: ["Example", "--json", "--dry-run"]))
    }
}
