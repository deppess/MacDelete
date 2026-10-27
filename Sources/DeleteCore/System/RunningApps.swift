import AppKit
import Foundation

public enum RunningApps {
    /// Running apps that are the app, one of its helpers, or anything launched from inside its
    /// bundle. Apps are looked up by identifier, and by process path (`proc_pidpath`, all
    /// processes in ~0.5 ms) for the bundle: reading every running app's URLs through AppKit
    /// took ~9 ms.
    public static func running(identifiers: [String], bundlePath: String) -> [NSRunningApplication] {
        // NSWorkspace updates from the run loop, which a command-line tool doesn't run; spinning
        // it once keeps an app that has quit from being reported.
        RunLoop.current.run(mode: .default, before: Date())
        var found: [pid_t: NSRunningApplication] = [:]
        for identifier in EvidenceFinder.distinct(identifiers) {
            for application in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) { found[application.processIdentifier] = application }
        }
        for pid in processes(inside: bundlePath) where found[pid] == nil {
            if let application = NSRunningApplication(processIdentifier: pid) { found[pid] = application }
        }
        return found.values.filter { isAlive($0.processIdentifier) }.sorted { $0.processIdentifier < $1.processIdentifier }
    }

    /// Opens the connection to Launch Services (~4 ms) ahead of the first real lookup.
    public static func prepare() {
        _ = NSRunningApplication.runningApplications(withBundleIdentifier: "")
    }

    /// Processes whose executable is inside the bundle.
    static func processes(inside bundlePath: String) -> [pid_t] {
        let prefix = bundlePath.lowercased() + "/"
        var pids = [pid_t](repeating: 0, count: Int(max(proc_listallpids(nil, 0), 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(max(count, 0)).filter { pid in
            guard pid > 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
            return String(cString: path).lowercased().hasPrefix(prefix)
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
