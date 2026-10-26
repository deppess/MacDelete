import Foundation

public enum Format {
    /// Decimal units, as Finder shows them: "312 MB", "1.8 MB", "4 KB".
    public static func size(_ bytes: Int64) -> String {
        if bytes < 1_000 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes) / 1_000
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        if unit == 0 || value >= 9.95 { return "\(Int(value.rounded())) \(units[unit])" }
        return String(format: "%.1f %@", value, units[unit])
    }

    /// `path` with the home folder shown as `~`.
    public static func path(_ path: String, home: URL) -> String {
        let home = home.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
