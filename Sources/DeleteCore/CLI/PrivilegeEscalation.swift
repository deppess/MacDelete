import Darwin
import Foundation

/// Re-executes delete under sudo after the user approved an identity-bound plan.
enum PrivilegeEscalation {
    /// The direct argv passed to the fixed sudo executable. App paths are never interpreted by a
    /// shell, and `--` prevents an app path beginning with a dash becoming an option.
    static func arguments(application: InstalledApp, fingerprint: String, includesCompanions: Bool, executable: String) -> [String] {
        var arguments = ["/usr/bin/sudo", "--", executable, "--approved", fingerprint]
        if !includesCompanions { arguments.append("--no-companions") }
        arguments += ["--", application.path]
        return arguments
    }

    static func rerun(
        application: InstalledApp,
        fingerprint: String,
        includesCompanions: Bool,
        reportError: (String) -> Void
    ) -> Int32 {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
            reportError("Couldn't find delete's own path to rerun it with sudo. Run: sudo delete \(Format.shellQuoted(application.path))")
            return EXIT_FAILURE
        }
        let arguments = arguments(
            application: application,
            fingerprint: fingerprint,
            includesCompanions: includesCompanions,
            executable: executable)
        fflush(stdout)
        var pointers = arguments.map { strdup($0) } + [nil]
        execv("/usr/bin/sudo", &pointers)
        let error = String(cString: strerror(errno))
        pointers.forEach { free($0) }
        reportError("Couldn't run sudo (\(error)). Run: sudo delete \(Format.shellQuoted(application.path))")
        return EXIT_FAILURE
    }
}
