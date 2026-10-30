import Foundation

public enum ListRenderer {
    public static func text(_ applications: [InstalledApp], home: URL) -> String {
        guard !applications.isEmpty else { return "No applications found." }
        let rows = applications.map { application -> [String] in
            [
                application.name.terminalInline, (application.version ?? "").terminalInline, application.size.map(Format.size) ?? "?",
                application.source.label.terminalInline
            ]
        }
        let sizeWidth = rows.map { $0[2].count }.max() ?? 0
        let aligned = rows.map { row in [row[0], row[1], String(repeating: " ", count: sizeWidth - row[2].count) + row[2], row[3]] }
        let total = applications.compactMap(\.size).reduce(0, +)
        let noun = applications.count == 1 ? "app" : "apps"
        return (TableFormatter.rows(aligned, spacing: 3) + ["", "\(applications.count) \(noun), \(Format.size(total))"]).joined(separator: "\n")
    }

    public static func json(_ applications: [InstalledApp], warnings: [String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let document = Document(applications: applications.map(Entry.init), warnings: warnings)
        return String(decoding: try encoder.encode(document), as: UTF8.self)
    }

    private struct Document: Encodable {
        let applications: [Entry]
        let warnings: [String]
    }

    private struct Entry: Encodable {
        let name: String
        let path: String
        let bundleIdentifier: String?
        let version: String?
        let size: Int64?
        let source: String
        let homebrewCask: String?
        let packages: [String]?
        let classification: String

        init(_ application: InstalledApp) {
            name = application.name
            path = application.path
            bundleIdentifier = application.bundleIdentifier
            version = application.version
            size = application.size
            classification = application.classification.rawValue
            switch application.source {
            case .appStore: (source, homebrewCask, packages) = ("app-store", nil, nil)
            case let .homebrew(token, _): (source, homebrewCask, packages) = ("homebrew", token, nil)
            case .macPorts: (source, homebrewCask, packages) = ("macports", nil, nil)
            case let .installerPackage(identifiers): (source, homebrewCask, packages) = ("installer-package", nil, identifiers)
            case .steam: (source, homebrewCask, packages) = ("steam", nil, nil)
            case .setapp: (source, homebrewCask, packages) = ("setapp", nil, nil)
            case .macOS: (source, homebrewCask, packages) = ("macos", nil, nil)
            case .download: (source, homebrewCask, packages) = ("download", nil, nil)
            }
        }
    }
}
