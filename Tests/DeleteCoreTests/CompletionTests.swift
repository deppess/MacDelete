import Foundation
import XCTest
@testable import DeleteCore

final class CompletionTests: XCTestCase {
    var applications: [InstalledApp] {
        var raycast = app("Raycast", id: "com.raycast.macos")
        raycast.version = "1.98.2"
        raycast.source = .homebrew(token: "raycast", declared: true)
        raycast.size = 312_000_000
        var xcode = app("Xcode", id: "com.apple.dt.Xcode")
        xcode.source = .appStore
        return [
            raycast,
            app("Visual Studio Code", id: "com.microsoft.VSCode", alternateNames: ["Code"]),
            app("FL Studio 2026", id: "com.image-line.flstudio"),
            app("FL Cloud Plugins", id: "com.image-line.fl-cloud-plugins"),
            xcode,
            app("Mail", id: "com.apple.mail", path: "/System/Applications/Mail.app", classification: .system),
            app("Falcon", id: "com.crowdstrike.falcon.App"),
            app("Helper", id: "com.example.helper", path: "/Library/Application Support/Example/Helper.app", classification: .auxiliary),
            app("Twin", id: "com.example.twin"),
            app("Twin", id: "com.example.twin", path: "/Users/tester/Applications/Twin.app"),
        ]
    }

    func values(_ word: String) -> [String] { Completion.candidates(for: word, applications: applications).map(\.value) }

    func testOffersOnlyAppsDeleteWouldAccept() {
        XCTAssertEqual(values(""), ["FL Cloud Plugins", "FL Studio 2026", "Raycast", "Twin", "Visual Studio Code", "Xcode"],
                       "macOS apps, security agents and helpers are never offered; removable Apple apps are")
    }

    func testPrefixesAlternateNamesAndCase() {
        XCTAssertEqual(values("fl"), ["FL Cloud Plugins", "FL Studio 2026"])
        XCTAssertEqual(values("RAY"), ["Raycast"])
        XCTAssertEqual(values("code"), ["Visual Studio Code"], "an alternate name finds the app under its real name")
        XCTAssertEqual(values("nothing"), [])
    }

    func testDescriptionsAndDuplicates() {
        let raycast = Completion.candidates(for: "ray", applications: applications).first
        XCTAssertEqual(raycast?.description, "1.98.2 · Homebrew (raycast) · 312 MB")
        XCTAssertEqual(Completion.candidates(for: "twin", applications: applications).map(\.description), ["2 apps with this name: give a path"])
    }

    func testIdentifiers() {
        XCTAssertEqual(Completion.candidates(for: "com.image", applications: applications).map(\.value), ["com.image-line.fl-cloud-plugins", "com.image-line.flstudio"])
        XCTAssertEqual(values("com.apple.m"), [], "never a macOS app's identifier")
    }

    func testLinesCannotBreakTheFormat() {
        var odd = app("Evil\tName\nInjected", id: "com.evil")
        odd.version = "1\t2"
        let output = Completion.lines(Completion.candidates(for: "", applications: [odd]))
        XCTAssertEqual(output.split(separator: "\n").count, 1)
        XCTAssertEqual(output.filter { $0 == "\t" }.count, 1)
    }

    func testParsesCompletionCommands() throws {
        XCTAssertEqual(try Invocation(arguments: ["completions", "fish"]).command, .completions(.fish))
        XCTAssertEqual(try Invocation(arguments: ["__complete", "--dr"]).command, .complete("--dr"))
        XCTAssertEqual(try Invocation(arguments: ["__complete"]).command, .complete(""))
        XCTAssertThrowsError(try Invocation(arguments: ["completions", "powershell"]))
        XCTAssertEqual(try Invocation(arguments: ["--", "completions"]).command, .remove("completions"), "after -- it's an app name")
    }

    /// Each script parses in its own shell (checked without running it).
    func testScriptsParse() throws {
        let checks: [(CompletionShell, String, [String])] = [(.fish, "/opt/homebrew/bin/fish", ["--no-execute"]), (.zsh, "/bin/zsh", ["-n"]), (.bash, "/bin/bash", ["-n"])]
        for (shell, executable, flags) in checks {
            guard FileManager.default.isExecutableFile(atPath: executable) else { continue }
            let file = FileManager.default.temporaryDirectory.appending(path: "delete-completion-\(UUID().uuidString).\(shell.rawValue)")
            try Completion.script(for: shell).write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let result = try CommandRunner().run(executable: URL(filePath: executable), arguments: flags + [file.path], environment: ["PATH": "/usr/bin:/bin"], timeout: 10, outputLimit: 65_536)
            XCTAssertEqual(result.status, 0, "\(shell): \(String(decoding: result.stderr, as: UTF8.self))")
        }
    }
}
