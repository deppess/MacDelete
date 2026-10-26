import AppKit
import Foundation

public enum RunningApps {
    /// Running processes that are the app, one of its helpers, or anything launched from inside
    /// its bundle.
    public static func running(identifiers: [String], bundlePath: String) -> [NSRunningApplication] {
        let lowerIdentifiers = Set(identifiers.map { $0.lowercased() })
        let prefix = bundlePath.lowercased() + "/"
        // NSWorkspace updates its list from the run loop, which a command-line tool doesn't run:
        // without this, an app that has quit stays listed for the life of the process.
        RunLoop.current.run(mode: .default, before: Date())
        return NSWorkspace.shared.runningApplications.filter { application in
            guard isAlive(application.processIdentifier) else { return false }
            if let identifier = application.bundleIdentifier?.lowercased(), lowerIdentifiers.contains(identifier) { return true }
            let paths = [application.bundleURL?.path, application.executableURL?.path].compactMap { $0?.lowercased() }
            return paths.contains { $0 == bundlePath.lowercased() || $0.hasPrefix(prefix) }
        }
    }

    /// The process exists (pid 0 and -1 would address many processes, so they never count).
    public static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    public static func isRunning(identifiers: [String], bundlePath: String) -> Bool {
        !running(identifiers: identifiers, bundlePath: bundlePath).isEmpty
    }
}
