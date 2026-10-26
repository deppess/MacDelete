import Darwin
import Foundation

/// Homebrew's hand-written `zap` lists: what a cask's maintainers found each app leaves behind.
enum HomebrewZap {
    /// The zap paths in an installed cask's own receipt. `brew uninstall --zap` deletes these.
    static func installedCaskPaths(token: String, prefix: String) -> [String] {
        let receipt = URL(filePath: prefix).appending(path: "Caskroom/\(token)/.metadata/INSTALL_RECEIPT.json")
        guard let data = try? Data(contentsOf: receipt), data.count <= 4 * 1_048_576,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var paths: [String] = []
        for stanza in json["uninstall_artifacts"] as? [[String: Any]] ?? [] {
            for directive in stanza["zap"] as? [[String: Any]] ?? [] { paths += strings(directive, keys: ["trash", "delete", "rmdir"]) }
        }
        return paths
    }

    /// The zap list Homebrew's downloaded catalog has for an app it didn't install, matched by the
    /// app's file name or bundle identifier. Nil when there's no catalog or no single cask fits.
    static func catalogPaths(for application: InstalledApp, catalog: URL) -> (token: String, paths: [String])? {
        guard let file = newestCatalog(in: catalog),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
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
                    case ":zap": for case let directive as [String: Any] in arguments { paths += strings(directive, keys: [":trash", ":delete", ":rmdir"]) }
                    case ":uninstall": for case let directive as [String: Any] in arguments { quits += strings(directive, keys: [":quit"]) }
                    default: continue
                    }
                }
                candidates.append((token, apps, quits, paths))
            }
        } else if let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payloadText = outer["payload"] as? String,
                  let casks = try? JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [[String: Any]] {
            // The older public catalog: `artifacts` as [{"app": ["X.app"]}, {"zap": [{"trash": …}]}].
            for cask in casks {
                guard let token = cask["token"] as? String else { continue }
                var apps: [String] = [], quits: [String] = [], paths: [String] = []
                for artifact in cask["artifacts"] as? [[String: Any]] ?? [] {
                    apps += (artifact["app"] as? [Any])?.compactMap { $0 as? String } ?? []
                    for directive in artifact["zap"] as? [[String: Any]] ?? [] { paths += strings(directive, keys: ["trash", "delete", "rmdir"]) }
                    for directive in artifact["uninstall"] as? [[String: Any]] ?? [] { quits += strings(directive, keys: ["quit"]) }
                }
                candidates.append((token, apps, quits, paths))
            }
        }
        let identifier = application.bundleIdentifier?.lowercased()
        let byIdentifier = candidates.filter { candidate in identifier.map { id in candidate.quits.contains { $0.lowercased() == id } } ?? false }
        let byName = candidates.filter { candidate in candidate.apps.contains { URL(filePath: $0).lastPathComponent.caseInsensitiveCompare(appFile) == .orderedSame } }
        // Variants (`firefox`, `firefox@beta`) share an app name; one that names the bundle
        // identifier decides, otherwise the name must be unique.
        let chosen = byIdentifier.count == 1 ? byIdentifier : byName.count == 1 ? byName : byName.filter { candidate in byIdentifier.contains { $0.token == candidate.token } }
        guard chosen.count == 1, let match = chosen.first, !match.paths.isEmpty else { return nil }
        return (match.token, match.paths)
    }

    /// Expands `~` and shell globs; returns only paths that exist.
    static func expand(_ pattern: String, home: URL) -> [String] {
        let expanded = pattern.hasPrefix("~/") ? home.appending(path: String(pattern.dropFirst(2))).path : pattern
        guard expanded.hasPrefix("/"), !expanded.split(separator: "/").contains("..") else { return [] }
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(expanded, GLOB_NOSORT, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in result.gl_pathv[index].map { String(cString: $0) } }.map { URL(filePath: $0).standardizedFileURL.path }
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
        let candidates = ((try? fileManager.contentsOfDirectory(at: internalFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
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
    static func casks(in data: Data, mentioning needles: [String]) -> [(token: String, cask: [String: Any])]? {
        guard let payload = unescapedPayload(data) else { return nil }
        let needleBytes = needles.map { Array($0.utf8) }
        return payload.withUnsafeBufferPointer { bytes -> [(String, [String: Any])]? in
            var result: [(String, [String: Any])] = []
            var depth = 0, inString = false, escaped = false
            var stringStart = 0, lastKeyAtDepth: [Int: String] = [:]
            var inCasks = false, caskStart = 0, caskToken = ""
            var sawCasks = false
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if inString {
                    if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 {
                        inString = false
                        // A string followed by ':' is a key.
                        var next = index + 1
                        while next < bytes.count, bytes[next] == 0x20 || bytes[next] == 0x0A || bytes[next] == 0x0D || bytes[next] == 0x09 { next += 1 }
                        if next < bytes.count, bytes[next] == 0x3A {
                            lastKeyAtDepth[depth] = String(decoding: UnsafeBufferPointer(rebasing: bytes[(stringStart + 1)..<index]), as: UTF8.self)
                        }
                    }
                } else if byte == 0x22 {
                    inString = true
                    stringStart = index
                } else if byte == 0x7B { // {
                    depth += 1
                    if depth == 2, lastKeyAtDepth[1] == "casks" { inCasks = true; sawCasks = true }
                    if inCasks, depth == 3 { caskStart = index; caskToken = lastKeyAtDepth[2] ?? "" }
                } else if byte == 0x7D { // }
                    if inCasks, depth == 3 {
                        let slice = UnsafeBufferPointer(rebasing: bytes[caskStart...index])
                        if needleBytes.contains(where: { contains(slice, $0) }),
                           let cask = try? JSONSerialization.jsonObject(with: Data(slice)) as? [String: Any] {
                            result.append((caskToken, cask))
                        }
                    }
                    if inCasks, depth == 2 { inCasks = false }
                    depth -= 1
                }
                index += 1
            }
            return sawCasks ? result : nil
        }
    }

    /// The bytes of the top-level "payload" string, unescaped.
    static func unescapedPayload(_ data: Data) -> [UInt8]? {
        let marker = Array("\"payload\":\"".utf8)
        return data.withUnsafeBytes { raw -> [UInt8]? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let start = firstIndex(of: marker, in: bytes) else { return nil }
            var output: [UInt8] = []
            output.reserveCapacity(bytes.count)
            var index = start + marker.count
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 { return output }
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
                case 0x75: // \uXXXX, re-escaped so the inner JSON parser decodes it (and any surrogate pair).
                    guard index + 5 < bytes.count else { return nil }
                    output += [0x5C, 0x75] + Array(UnsafeBufferPointer(rebasing: bytes[(index + 2)...(index + 5)]))
                    index += 6
                    continue
                default: return nil
                }
                index += 2
            }
            return nil
        }
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
