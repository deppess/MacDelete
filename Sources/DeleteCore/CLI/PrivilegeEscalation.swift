import Darwin
import Foundation

/// Re-executes delete under sudo after the user approved an identity-bound plan.
enum PrivilegeEscalation {
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
        var arguments = ["/usr/bin/sudo", "--", executable, "--approved", fingerprint]
        if !includesCompanions { arguments.append("--no-companions") }
        arguments += ["--", application.path]
        fflush(stdout)
        var pointers = arguments.map { strdup($0) } + [nil]
        execv("/usr/bin/sudo", &pointers)
        let error = String(cString: strerror(errno))
        pointers.forEach { free($0) }
        reportError("Couldn't run sudo (\(error)). Run: sudo delete \(Format.shellQuoted(application.path))")
        return EXIT_FAILURE
    }
}
