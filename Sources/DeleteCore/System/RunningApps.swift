import AppKit
import Foundation

public enum RunningApps {
    /// Running processes that are the app, one of its helpers, or anything launched from inside
    /// its bundle.
    public static func running(identifiers: [String], bundlePath: String) -> [NSRunningApplication] {
        let lowerIdentifiers = Set(identifiers.map { $0.lowercased() })
        let prefix = bundlePath.lowercased() + "/"
        return NSWorkspace.shared.runningApplications.filter { application in
            if let identifier = application.bundleIdentifier?.lowercased(), lowerIdentifiers.contains(identifier) { return true }
            let paths = [application.bundleURL?.path, application.executableURL?.path].compactMap { $0?.lowercased() }
            return paths.contains { $0 == bundlePath.lowercased() || $0.hasPrefix(prefix) }
        }
    }

    public static func isRunning(identifiers: [String], bundlePath: String) -> Bool {
        !running(identifiers: identifiers, bundlePath: bundlePath).isEmpty
    }
}
