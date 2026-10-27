import Foundation

/// The app's launchd jobs: plists in the LaunchAgents and LaunchDaemons folders whose label is
/// one of the app's identifiers (or a sub-identifier), whose `AssociatedBundleIdentifiers` names
/// the app, or whose program lives inside the app's bundle.
enum LaunchItemScan {
    struct Result {
        var items: [LaunchItem] = []
        var findings: [Finding] = []
        var unreadable: [String] = []
    }

    struct Job {
        var label: String
        var program: String?
        var associated: [String]
    }

    static func scan(roots: Roots, bundlePath: String, identifiers: [String], helperLabels: [String], ownership: Ownership) -> Result {
        var result = Result()
        let folders: [(URL, LaunchItem.Domain, String)] = [
            (roots.home.appending(path: "Library/LaunchAgents"), .user, "launch agent"),
            (roots.library.appending(path: "LaunchAgents"), .user, "launch agent"),
            (roots.library.appending(path: "LaunchDaemons"), .system, "launch daemon"),
        ]
        let lowerIdentifiers = Set(identifiers.map { $0.lowercased() })
        let lowerHelpers = Set(helperLabels.map { $0.lowercased() })
        let bundlePrefix = bundlePath.lowercased() + "/"
        for (folder, domain, kind) in folders {
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: folder.path) } catch {
                if FileManager.default.fileExists(atPath: folder.path) { result.unreadable.append(folder.path) }
                continue
            }
            for name in names.sorted() where name.hasSuffix(".plist") {
                let plist = folder.appending(path: name)
                guard let job = read(plist) else { continue }
                let label = job.label.lowercased()
                let program = job.program.map { URL(filePath: $0).standardizedFileURL.path }
                let byLabel = lowerHelpers.contains(label) || ownership.owner(ofItemNamed: job.label) == .target
                let byAssociation = job.associated.contains { lowerIdentifiers.contains($0.lowercased()) }
                let byProgram = program.map { $0.lowercased().hasPrefix(bundlePrefix) } ?? false
                guard byLabel || byAssociation || byProgram else { continue }
                result.items.append(LaunchItem(label: job.label, plist: plist.path, domain: domain))
                result.findings.append(Finding(path: plist.path, tier: .exact, reason: kind))
                if let program, !byProgram { result.findings += programFindings(program, label: job.label, roots: roots) }
            }
        }
        return result
    }

    /// A job's program outside the app's bundle: a privileged helper tool, or a helper installed
    /// into Application Support. The program (or the bundle holding it) is the app's; the folder
    /// around it is only name evidence, since a vendor may keep other products there.
    static func programFindings(_ program: String, label: String, roots: Roots) -> [Finding] {
        let helperTools = roots.library.appending(path: "PrivilegedHelperTools").standardizedFileURL.path + "/"
        if program.hasPrefix(helperTools), !program.dropFirst(helperTools.count).contains("/") {
            return [Finding(path: program, tier: .exact, reason: "helper tool run by \(label)")]
        }
        let supportFolders = [roots.library.appending(path: "Application Support"), roots.home.appending(path: "Library/Application Support")].map { $0.standardizedFileURL.path + "/" }
        guard let support = supportFolders.first(where: { program.hasPrefix($0) }) else { return [] }
        var item = URL(filePath: program)
        // The outermost bundle holding the program, if any.
        var ancestor = item.deletingLastPathComponent()
        while ancestor.path.count > support.count {
            if ["app", "bundle", "framework", "xpc"].contains(ancestor.pathExtension.lowercased()) { item = ancestor }
            ancestor = ancestor.deletingLastPathComponent()
        }
        // Never a top-level vendor folder itself.
        guard item.deletingLastPathComponent().path.count >= support.count, item.path.count > support.count else { return [] }
        var findings = [Finding(path: item.path, tier: .exact, reason: "program of \(label)")]
        var folder = item.deletingLastPathComponent()
        let generic: Set<String> = ["components", "helpers", "bin", "resources", "support", "macos", "contents", "library", "lib"]
        while generic.contains(folder.lastPathComponent.lowercased()), folder.path.count > support.count {
            folder = folder.deletingLastPathComponent()
        }
        if folder.path.count > support.count - 1, folder.path + "/" != support {
            findings.append(Finding(path: folder.path, tier: .name, reason: "folder holding \(label)'s program"))
        }
        return findings
    }

    static func read(_ plist: URL) -> Job? {
        guard let dictionary = SmallFile.plist(atPath: plist.path),
              let label = (dictionary["Label"] as? String)?.nonEmpty else { return nil }
        let program = (dictionary["Program"] as? String) ?? (dictionary["ProgramArguments"] as? [Any])?.first as? String
        let associated: [String] = (dictionary["AssociatedBundleIdentifiers"] as? [String]) ?? ((dictionary["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? [])
        // Only absolute program paths are evidence; anything else is resolved through PATH.
        return Job(label: label, program: program.flatMap { $0.hasPrefix("/") ? $0 : nil }, associated: associated)
    }
}
