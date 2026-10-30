import AppKit
import Darwin
import Foundation

public enum QuitResult: Sendable, Equatable {
    case quit
    /// Still running after the wait; nothing may be deleted.
    case stillRunning([String])
}

/// Everything delete does to the system besides removing files. Real runs use
/// `LiveSystemActions`; sandbox runs and tests use `RecordingSystemActions`, which only notes
/// what would have happened, so they can never quit a real app or change launchd, Homebrew,
/// the receipt database or the privacy database.
public protocol SystemActions: AnyObject, Sendable {
    func quit(identifiers: [String], bundlePath: String) -> QuitResult
    /// Each returns an error message, or nil on success.
    func bootout(_ item: LaunchItem) -> String?
    func forgetPackage(_ identifier: String) -> String?
    func resetPrivacy(_ identifier: String) -> String?
    func unregister(_ appPath: String) -> String?
}

public final class RecordingSystemActions: SystemActions, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    public init() {}

    public var recorded: [String] { lock.withLock { log } }
    private func note(_ line: String) -> String? { lock.withLock { log.append(line) }; return nil }

    public func quit(identifiers: [String], bundlePath: String) -> QuitResult { _ = note("quit \(bundlePath)"); return .quit }
    public func bootout(_ item: LaunchItem) -> String? { note("launchctl bootout \(item.domain == .system ? "system" : "gui/<uid>") \(item.plist)") }
    public func forgetPackage(_ identifier: String) -> String? { note("pkgutil --forget \(identifier)") }
    public func resetPrivacy(_ identifier: String) -> String? { note("tccutil reset All \(identifier)") }
    public func unregister(_ appPath: String) -> String? { note("lsregister -u \(appPath)") }
}

public final class LiveSystemActions: SystemActions, @unchecked Sendable {
    private let runner: CommandRunner
    private let tools: Tools
    private let environment: [String: String]
    /// The user delete acts for: the invoking user under sudo.
    private let user: (name: String, uid: uid_t)?

    public init(tools: Tools, runner: CommandRunner = CommandRunner(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.runner = runner
        self.tools = tools
        self.environment = environment
        if geteuid() == 0, let name = environment["SUDO_USER"]?.nonEmpty, name != "root", let entry = getpwnam(name) {
            user = (name, entry.pointee.pw_uid)
        } else if let entry = getpwuid(getuid()) {
            user = (String(cString: entry.pointee.pw_name), getuid())
        } else {
            user = nil
        }
    }

    /// Asks the app (and its helpers) to quit the normal way, as if from its menu, and waits up to
    /// `timeout` seconds. Never kills.
    public func quit(identifiers: [String], bundlePath: String) -> QuitResult {
        let running = RunningApps.running(identifiers: identifiers, bundlePath: bundlePath)
        for application in running { application.terminate() }
        let deadline = Date().addingTimeInterval(15)
        var remaining = running
        while !remaining.isEmpty, Date() < deadline {
            usleep(200_000)
            remaining = remaining.filter { RunningApps.isAlive($0.processIdentifier) }
        }
        return remaining.isEmpty ? .quit : .stillRunning(remaining.map { $0.localizedName ?? $0.bundleIdentifier ?? "pid \($0.processIdentifier)" })
    }

    public func bootout(_ item: LaunchItem) -> String? {
        let domain: String
        switch item.domain {
        case .system: domain = "system"
        case .user:
            guard let user else { return "unknown user" }
            domain = "gui/\(user.uid)"
        }
        guard
            let result = try? runner.run(
                executable: tools.launchctl, arguments: ["bootout", domain, item.plist], environment: baseEnvironment, timeout: 30, outputLimit: 1_048_576)
        else { return "launchctl didn't run" }
        // 3 (no such process), 5 (I/O error) and 113 (not found) mean it wasn't loaded: nothing to stop.
        return [0, 3, 5, 36, 113].contains(result.status) ? nil : message(result)
    }

    public func forgetPackage(_ identifier: String) -> String? {
        guard
            let result = try? runner.run(
                executable: tools.pkgutil, arguments: ["--forget", identifier], environment: baseEnvironment, timeout: 30, outputLimit: 1_048_576)
        else { return "pkgutil didn't run" }
        return result.status == 0 ? nil : message(result)
    }

    public func resetPrivacy(_ identifier: String) -> String? {
        let (command, arguments) = asUser(tools.tccutil, ["reset", "All", identifier])
        guard let result = try? runner.run(executable: command, arguments: arguments, environment: baseEnvironment, timeout: 30, outputLimit: 1_048_576) else {
            return "tccutil didn't run"
        }
        return result.status == 0 ? nil : message(result)
    }

    public func unregister(_ appPath: String) -> String? {
        let (command, arguments) = asUser(tools.lsregister, ["-u", appPath])
        guard let result = try? runner.run(executable: command, arguments: arguments, environment: baseEnvironment, timeout: 60, outputLimit: 1_048_576) else {
            return "lsregister didn't run"
        }
        return result.status == 0 ? nil : message(result)
    }

    private var baseEnvironment: [String: String] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        if let home = user.flatMap({ getpwnam($0.name) }).flatMap({ $0.pointee.pw_dir }) { environment["HOME"] = String(cString: home) }
        return environment
    }

    /// Runs a command as the invoking user when delete itself runs under sudo.
    private func asUser(_ executable: URL, _ arguments: [String]) -> (URL, [String]) {
        guard geteuid() == 0, let user, user.uid != 0 else { return (executable, arguments) }
        return (URL(filePath: "/usr/bin/sudo"), ["-u", user.name, "-H", "--", executable.path] + arguments)
    }

    private func message(_ result: CommandResult) -> String {
        let text = (String(decoding: result.stderr, as: UTF8.self) + "\n" + String(decoding: result.stdout, as: UTF8.self)).trimmingCharacters(
            in: .whitespacesAndNewlines)
        return text.isEmpty ? "exit status \(result.status)" : text.terminalText
    }
}
