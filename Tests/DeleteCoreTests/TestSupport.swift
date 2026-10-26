import Darwin
import Foundation
import XCTest
@testable import DeleteCore

/// A temporary folder standing in for the whole system: home, /Applications, /System, receipts,
/// and a Homebrew prefix. Removed after each test.
final class FakeSystem {
    let root: URL
    var home: URL { root.appending(path: "Users/tester", directoryHint: .isDirectory) }
    var applications: URL { root.appending(path: "Applications", directoryHint: .isDirectory) }
    var systemApplications: URL { root.appending(path: "System/Applications", directoryHint: .isDirectory) }
    var receipts: URL { root.appending(path: "var/db/receipts", directoryHint: .isDirectory) }
    var homebrew: URL { root.appending(path: "opt/homebrew", directoryHint: .isDirectory) }
    var library: URL { root.appending(path: "Library", directoryHint: .isDirectory) }
    var userLibrary: URL { home.appending(path: "Library", directoryHint: .isDirectory) }
    var userCache: URL { root.appending(path: "private/var/folders/zz/hash/C", directoryHint: .isDirectory) }
    var userTemp: URL { root.appending(path: "private/var/folders/zz/hash/T", directoryHint: .isDirectory) }
    var tools: URL { root.appending(path: "tools", directoryHint: .isDirectory) }

    init() throws {
        // Resolved, because /var is a symlink to /private/var and the scan resolves paths.
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "delete-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        for folder in [home, applications, systemApplications, receipts, homebrew.appending(path: "Caskroom"), library, userLibrary, userCache, userTemp, tools] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // Commands that report nothing unless a test says otherwise.
        for tool in ["pkgutil", "lsbom", "systemextensionsctl"] {
            try write("#!/bin/sh\nexit 1\n", to: tools.appending(path: tool), executable: true)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var roots: Roots {
        var roots = Roots(
            home: home,
            applicationRoots: [
                ApplicationRoot(url: applications, classification: .user, required: true),
                ApplicationRoot(url: home.appending(path: "Applications"), classification: .user, required: false),
                ApplicationRoot(url: systemApplications, classification: .system, required: true),
                ApplicationRoot(url: home.appending(path: "Library/Application Support/Steam/steamapps/common"), classification: .user, required: false, maxDepth: 2),
            ],
            homebrewPrefixes: [homebrew],
            receipts: receipts,
            spotlight: false,
            library: library,
            userCache: userCache,
            userTemp: userTemp
        )
        roots.tools.pkgutil = tools.appending(path: "pkgutil")
        roots.tools.lsbom = tools.appending(path: "lsbom")
        roots.tools.systemextensionsctl = tools.appending(path: "systemextensionsctl")
        return roots
    }

    /// Creates a file (or, with a trailing slash, a folder) at a path relative to the fake root.
    @discardableResult
    func touch(_ relative: String, contents: String = "x") throws -> URL {
        let url = root.appending(path: relative)
        if relative.hasSuffix("/") {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try write(contents, to: url)
        }
        return url
    }

    func writePlist(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: url)
    }

    func plan(_ name: String) throws -> RemovalPlan {
        let inventory = Inventory.load(roots: roots, sizes: false)
        guard case let .found(application) = AppMatcher.match(name, in: inventory.applications, home: home) else { throw Refusal(message: "no app \(name)") }
        var resolved = application
        resolved.source = Inventory.source(of: application, casks: inventory.casks, receipts: inventory.receipts)
        return try EvidenceFinder(roots: roots).plan(for: resolved, inventory: inventory)
    }

    @discardableResult
    func makeApp(_ relativePath: String, in folder: URL? = nil, metadata: [String: String] = [:]) throws -> URL {
        let url = (folder ?? applications).appending(path: relativePath, directoryHint: .isDirectory)
        let plist = url.appending(path: "Contents/Info.plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: plist)
        return url
    }

    /// Gives a bundle a real executable and an ad-hoc signature carrying these app groups, so
    /// the Security framework reads its entitlements as it would a shipped app's.
    func sign(_ bundle: URL, applicationGroups: [String]) throws {
        let info = bundle.appending(path: "Contents/Info.plist")
        var metadata = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any])
        metadata["CFBundleExecutable"] = metadata["CFBundleExecutable"] ?? bundle.deletingPathExtension().lastPathComponent
        try writePlist(metadata, to: info)
        let executable = bundle.appending(path: "Contents/MacOS/\(metadata["CFBundleExecutable"]!)")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: executable.path)
        let entitlements = root.appending(path: "entitlements-\(UUID().uuidString).plist")
        try writePlist(["com.apple.security.application-groups": applicationGroups], to: entitlements)
        defer { try? FileManager.default.removeItem(at: entitlements) }
        let result = try CommandRunner().run(executable: URL(filePath: "/usr/bin/codesign"), arguments: ["-f", "-s", "-", "--entitlements", entitlements.path, bundle.path], environment: [:], timeout: 30, outputLimit: 65_536)
        XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
    }

    func write(_ contents: String, to url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        if executable { XCTAssertEqual(chmod(url.path, 0o755), 0) }
    }

    func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}

func app(_ name: String, id: String? = nil, path: String? = nil, classification: AppClassification = .user, alternateNames: [String] = []) -> InstalledApp {
    let path = path ?? "/Applications/\(name).app"
    return InstalledApp(path: path, bundlePath: path, name: name, bundleIdentifier: id, alternateNames: alternateNames, version: nil, executableName: nil, classification: classification, source: .download, size: nil, linkTargets: [], hasAppStoreReceipt: false, isIOSApp: false, isSteamShortcut: false)
}
