import Darwin
import Foundation

/// Homebrew's hand-written `zap` lists: what a cask's maintainers found each app leaves behind.
enum HomebrewZap {
    struct Evidence {
        /// The installed cask whose concrete receipt artifacts this plan reproduces locally.
        var cask: String?
        var findings: [Finding] = []
        var skipped: [Skipped] = []
        var emptyFolders: [String] = []
    }

    /// Exact for an installed cask, name evidence from
    /// the catalog's list otherwise. An item another installed app's identifier names stays,
    /// whatever the list says.
    static func evidence(for application: InstalledApp, casks: [InstalledCask], catalog: (token: String, paths: [String])?, ownership: Ownership, home: URL)
        -> Evidence
    {
        var result = Evidence()
        func claimant(_ path: String) -> String? {
            switch ownership.owner(ofItemNamed: URL(filePath: path).lastPathComponent) {
            case let .other(owner)?, let .shared(owner)?: owner
            default: nil
            }
        }
        if case let .homebrew(token, true) = application.source, let cask = casks.first(where: { $0.token == token }) {
            result.cask = token
            // Homebrew's Caskroom payload is an uninstall side effect too.  It is included so
            // the plan remains truthful even for otherwise simple app-only casks.
            let caskroom = URL(filePath: cask.prefix).appending(path: "Caskroom/\(cask.token)").path
            if FileManager.default.fileExists(atPath: caskroom) {
                result.findings.append(Finding(path: caskroom, tier: .exact, reason: "Homebrew cask files"))
            }
            for path in cask.removalArtifactPaths where FileManager.default.fileExists(atPath: path) {
                result.findings.append(Finding(path: path, tier: .exact, reason: "Homebrew command-line tool"))
            }
            for path in cask.uninstallDeletePaths where FileManager.default.fileExists(atPath: path) {
                result.findings.append(Finding(path: path, tier: .exact, reason: "Homebrew declared delete"))
            }
            for path in cask.uninstallEmptyFolders where !result.emptyFolders.contains(path) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    result.emptyFolders.append(path)
                }
            }
            let zap = installedCaskPaths(token: token, prefix: cask.prefix)
            for path in zap.remove.flatMap({ expand($0, home: home) }) {
                if let owner = claimant(path) {
                    result.skipped.append(Skipped(path: path, reason: "also belongs to \(Format.path(owner, home: home))"))
                } else {
                    result.findings.append(Finding(path: path, tier: .exact, reason: "Homebrew zap"))
                }
            }
            for path in zap.removeIfEmpty.flatMap({ expand($0, home: home) }) where !result.emptyFolders.contains(path) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { result.emptyFolders.append(path) }
            }
        } else if let catalog {
            for path in catalog.paths.flatMap({ expand($0, home: home) }) where claimant(path) == nil {
                result.findings.append(Finding(path: path, tier: .name, reason: "Homebrew's list for \(catalog.token)"))
            }
        }
        return result
    }

    /// The zap paths in an installed cask's own receipt. `remove` paths are modeled as concrete
    /// findings; `removeIfEmpty` are its `rmdir` folders, which are removed only when empty (a vendor
    /// folder, `~/.claude`): never deleted with their contents.
    static func installedCaskPaths(token: String, prefix: String) -> (remove: [String], removeIfEmpty: [String]) {
        let receipt = URL(filePath: prefix).appending(path: "Caskroom/\(token)/.metadata/INSTALL_RECEIPT.json")
        guard let json = SmallFile.json(atPath: receipt.path, limit: 4 * 1_048_576) else { return ([], []) }
        var remove: [String] = [], removeIfEmpty: [String] = []
        for stanza in json["uninstall_artifacts"] as? [[String: Any]] ?? [] {
            for directive in stanza["zap"] as? [[String: Any]] ?? [] {
                remove += strings(directive, keys: ["trash", "delete"])
                removeIfEmpty += strings(directive, keys: ["rmdir"])
            }
        }
        return (remove, removeIfEmpty)
    }

    /// The zap list Homebrew's downloaded catalog has for an app it didn't install, matched by the
    /// app's file name or bundle identifier. Nil when there's no catalog or no single cask fits.
    static func catalogPaths(for application: InstalledApp, catalog: URL) -> (token: String, paths: [String])? {
        guard let file = newestCatalog(in: catalog),
            let data = try? Data(contentsOf: file, options: .mappedIfSafe)
        else { return nil }
        let appFile = application.name + ".app"
        let needles = [appFile] + (application.bundleIdentifier.map { [$0] } ?? [])
        // Skip everything when the app isn't mentioned at all.
        guard needles.contains(where: { data.range(of: Data($0.utf8)) != nil }) else { return nil }

        var candidates: [(token: String, apps: [String], quits: [String], paths: [String])] = []
        if let casks = CatalogScanner.casks(in: data, mentioning: needles) {
            // The internal catalog: `raw_artifacts` as [":app", ["X.app"]], [":zap", {":trash": …}].
            for (token, cask) in casks {
                guard let artifacts = cask["raw_artifacts"] as? [[Any]] else { continue }
                var apps: [String] = [], quits: [String] = [], paths: [String] = []
                for artifact in artifacts {
                    guard let kind = artifact.first as? String else { continue }
                    let arguments = Array(artifact.dropFirst())
                    switch kind {
                    case ":app": apps += (arguments.first as? [Any])?.compactMap { $0 as? String } ?? []
                    case ":zap": for case let directive as [String: Any] in arguments { paths += strings(directive, keys: [":trash", ":delete"]) }
                    case ":uninstall": for case let directive as [String: Any] in arguments { quits += strings(directive, keys: [":quit"]) }
                    default: continue
                    }
                }
                candidates.append((token, apps, quits, paths))
            }
        } else if let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payloadText = outer["payload"] as? String,
            let casks = try? JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [[String: Any]]
        {
            // The older public catalog: `artifacts` as [{"app": ["X.app"]}, {"zap": [{"trash": …}]}].
            for cask in casks {
                guard let token = cask["token"] as? String else { continue }
                var apps: [String] = [], quits: [String] = [], paths: [String] = []
                for artifact in cask["artifacts"] as? [[String: Any]] ?? [] {
                    apps += (artifact["app"] as? [Any])?.compactMap { $0 as? String } ?? []
                    // `rmdir` folders are removed only when empty, so they're no evidence of the app.
                    for directive in artifact["zap"] as? [[String: Any]] ?? [] { paths += strings(directive, keys: ["trash", "delete"]) }
                    for directive in artifact["uninstall"] as? [[String: Any]] ?? [] { quits += strings(directive, keys: ["quit"]) }
                }
                candidates.append((token, apps, quits, paths))
            }
        }
        let identifier = application.bundleIdentifier?.lowercased()
        let byIdentifier = candidates.filter { candidate in identifier.map { id in candidate.quits.contains { $0.lowercased() == id } } ?? false }
        let byName = candidates.filter { candidate in
            candidate.apps.contains { URL(filePath: $0).lastPathComponent.caseInsensitiveCompare(appFile) == .orderedSame }
        }
        // Variants (`firefox`, `firefox@beta`) share an app name; one that names the bundle
        // identifier decides, otherwise the name must be unique.
        let chosen =
            byIdentifier.count == 1
            ? byIdentifier : byName.count == 1 ? byName : byName.filter { candidate in byIdentifier.contains { $0.token == candidate.token } }
        guard chosen.count == 1, let match = chosen.first, !match.paths.isEmpty else { return nil }
        return (match.token, match.paths)
    }

    /// Expands `~` and shell globs; returns only paths that exist.
    /// A zap list is the cask maintainers' data. A path component with a wildcard is accepted
    /// only when it still names something specific: three literal characters before the wildcard
    /// (`com.vendor.*`, `Live_*.plist`), or a literal run of six or more that isn't a file
    /// extension (`*.com.vendor.app`, a team-ID prefix). `*`, `*.plist` or `[a-z]*` would sweep up
    /// every other app's items in that folder. Measured on Homebrew's catalog (2026-10-26): 20 of
    /// 2,409 wildcard paths rejected, all `*` folder components or bare `*`/`*.log` names.
    static func isSpecific(_ pattern: String) -> Bool {
        pattern.split(separator: "/").allSatisfy { component in
            let text = String(component)
            guard text.contains(where: { "*?[".contains($0) }) else { return true }
            // Literal runs between wildcards; a [...] class counts as a wildcard.
            var runs: [String] = [], current = "", inClass = false
            for character in text {
                if inClass { if character == "]" { inClass = false }; continue }
                if character == "[" || character == "*" || character == "?" {
                    runs.append(current); current = ""
                    inClass = character == "["
                } else {
                    current.append(character)
                }
            }
            runs.append(current)
            if runs[0].count >= 3 { return true }
            return runs.contains { $0.count >= 6 && !fileExtensions.contains($0.lowercased()) }
        }
    }

    private static let fileExtensions: Set<String> = [
        ".plist", ".log", ".app", ".savedstate", ".crash", ".ips", ".diag", ".db", ".json", ".txt", ".binarycookies",
        ".sfl2", ".sfl3", ".sfl4", ".bom", ".pkg", ".dmg", ".zip", ".lock", ".tmp", ".cache", ".sqlite"
    ]

    static func expand(_ pattern: String, home: URL) -> [String] {
        guard isSpecific(pattern) else { return [] }
        let expanded = pattern.hasPrefix("~/") ? home.appending(path: String(pattern.dropFirst(2))).path : pattern
        guard expanded.hasPrefix("/"), !expanded.split(separator: "/").contains("..") else { return [] }
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(expanded, GLOB_NOSORT, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in result.gl_pathv[index].map { String(cString: $0) } }.map {
            URL(filePath: $0).standardizedFileURL.path
        }
    }

    private static func strings(_ directive: [String: Any], keys: [String]) -> [String] {
        keys.flatMap { key -> [String] in
            if let single = directive[key] as? String { return [single] }
            return directive[key] as? [String] ?? []
        }
    }

    private static func newestCatalog(in folder: URL) -> URL? {
        let fileManager = FileManager.default
        let internalFolder = folder.appending(path: "internal", directoryHint: .isDirectory)
        let candidates =
            ((try? fileManager.contentsOfDirectory(at: internalFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("packages.") && $0.lastPathComponent.hasSuffix(".jws.json") }
            + [folder.appending(path: "cask.jws.json")].filter { fileManager.fileExists(atPath: $0.path) }
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return candidates.max { modified($0) < modified($1) }
    }
}

/// Reads only the casks that mention given strings from Homebrew's internal catalog,
/// `{"payload": "<the catalog as an escaped JSON string>", …}`. Parsing all 16 MB takes ~150 ms;
/// unescaping the payload and finding each cask's extent in one pass takes ~25 ms, and only the
/// few matching casks are parsed.
enum CatalogScanner {
    /// Walks the catalog's "payload" string once (~15 MB) without unescaping it, tracking only
    /// the keys at depths 1 and 2 ("casks" and each cask's token). Only a cask that mentions a
    /// needle is unescaped and parsed.
    ///
    /// Inside the payload, a quote preceded by n backslashes is: the payload's end (n even), a
    /// quote of the inner JSON (n = 1, 5, …, `\"` or `\\\\\"`), or an escaped quote inside an
    /// inner string (n = 3, 7, …, `\\\"`).
    ///
    /// The formulae (half the payload) are skipped: the walk starts at the top-level "casks" key
    /// (`},\"casks\":{`, the previous top-level value closing before it) when it's found, and
    /// stops after the cask holding the needles' last mention.
    static func casks(in data: Data, mentioning needles: [String]) -> [(token: String, cask: [String: Any])]? {
        let marker = Array("\"payload\":\"".utf8)
        let casksStart = Array("},\\\"casks\\\":{".utf8)
        let needleBytes = needles.map { Array($0.utf8) }
        let casksKey = Array("casks".utf8)
        return data.withUnsafeBytes { raw -> [(String, [String: Any])]? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress, let start = firstIndex(of: marker, in: bytes) else { return nil }
            func backslashes(before index: Int) -> Int {
                var count = 0
                while bytes[index - 1 - count] == 0x5C { count += 1 }
                return count
            }
            var result: [(String, [String: Any])] = []
            var depth = 0
            // The last key seen at depth 1 and 2, as byte ranges.
            var depthOneKey = 0..<0, depthTwoKey = 0..<0
            var inCasks = false, caskStart = 0, caskToken = 0..<0
            var sawCasks = false
            var index = start + marker.count
            // Data.range, not memmem: memmem is slow on a pattern starting with a byte as common
            // as "}" (~6 ms over the formulae, against ~1 ms).
            if let jump = data.range(of: Data(casksStart), in: index..<data.count) {
                (index, depth) = (jump.lowerBound + 1, 1)
            }
            // Where the needles are last mentioned; nothing after that cask matters.
            var lastMention = -1
            for needle in needleBytes {
                if let found = data.range(of: Data(needle), options: .backwards, in: index..<data.count) { lastMention = max(lastMention, found.lowerBound) }
            }
            guard lastMention >= 0 else { return [] }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    let escapes = backslashes(before: index)
                    // The payload's end, or a stray escaped quote: malformed.
                    guard escapes % 4 == 1 else { return escapes % 2 == 0 && sawCasks ? result : nil }
                    // An inner string: jump to its closing quote (memchr, since strings are most
                    // of the payload).
                    let stringStart = index + 1
                    var end = index
                    repeat {
                        guard let found = memchr(base + end + 1, 0x22, bytes.count - end - 1) else { return nil }
                        end = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                        let count = backslashes(before: end)
                        if count % 4 == 1 { break }
                        guard count % 4 == 3 else { return nil }
                    } while true
                    index = end
                    // A string followed by ':' is a key; only depths 1 and 2 matter. Compact JSON
                    // has no whitespace before the colon.
                    if depth == 1 || depth == 2, index + 1 < bytes.count, bytes[index + 1] == 0x3A {
                        let key = stringStart..<(index - 1)
                        if depth == 1 { depthOneKey = key } else { depthTwoKey = key }
                    }
                } else if byte == 0x7B {  // {
                    depth += 1
                    if depth == 2, UnsafeBufferPointer(rebasing: bytes[depthOneKey]).elementsEqual(casksKey) { inCasks = true; sawCasks = true }
                    if inCasks, depth == 3 { caskStart = index; caskToken = depthTwoKey }
                } else if byte == 0x7D {  // }
                    if inCasks, depth == 3 {
                        let slice = UnsafeBufferPointer(rebasing: bytes[caskStart...index])
                        if needleBytes.contains(where: { contains(slice, $0) }), let json = unescape(slice),
                            let cask = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any],
                            let token = unescape(UnsafeBufferPointer(rebasing: bytes[caskToken]))
                        {
                            result.append((String(decoding: token, as: UTF8.self), cask))
                        }
                    }
                    if inCasks, depth == 2 { inCasks = false }
                    if inCasks, depth == 3, index > lastMention { return result }
                    depth -= 1
                }
                index += 1
            }
            return nil
        }
    }

    /// Text from inside a JSON string, unescaped. `\uXXXX` is kept as is, so the inner JSON parser
    /// decodes it (and any surrogate pair).
    static func unescape(_ bytes: UnsafeBufferPointer<UInt8>) -> [UInt8]? {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte != 0x5C { output.append(byte); index += 1; continue }
            guard index + 1 < bytes.count else { return nil }
            let code = bytes[index + 1]
            switch code {
            case 0x22, 0x5C, 0x2F: output.append(code)
            case 0x62: output.append(0x08)
            case 0x66: output.append(0x0C)
            case 0x6E: output.append(0x0A)
            case 0x72: output.append(0x0D)
            case 0x74: output.append(0x09)
            case 0x75:
                guard index + 5 < bytes.count else { return nil }
                output += [0x5C, 0x75] + Array(UnsafeBufferPointer(rebasing: bytes[(index + 2)...(index + 5)]))
                index += 6
                continue
            default: return nil
            }
            index += 2
        }
        return output
    }

    private static func firstIndex(of needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        guard needle.count <= bytes.count, let base = bytes.baseAddress else { return nil }
        return needle.withUnsafeBytes { pattern -> Int? in
            guard let found = memmem(base, bytes.count, pattern.baseAddress, needle.count) else { return nil }
            return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
        }
    }

    private static func contains(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        firstIndex(of: needle, in: bytes) != nil
    }
}
