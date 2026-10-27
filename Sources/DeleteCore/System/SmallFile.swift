import Darwin
import Foundation

/// Reads the small data files evidence comes from (plists, manifests, receipts, scripts). Each
/// is data from somewhere else, so it's opened without following a link at the last component,
/// must be a regular file, and is checked against `limit` before anything is read.
enum SmallFile {
    static func data(atPath path: String, limit: Int = 1_048_576) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { buffer in buffer.baseAddress.map { read(descriptor, $0, buffer.count) } ?? 0 }
        guard count >= 0 else { return nil }
        return data.prefix(count)
    }

    /// A property list whose top level is a dictionary.
    static func plist(atPath path: String, limit: Int = 1_048_576) -> [String: Any]? {
        data(atPath: path, limit: limit).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    }

    /// A JSON document whose top level is an object.
    static func json(atPath path: String, limit: Int = 1_048_576) -> [String: Any]? {
        data(atPath: path, limit: limit).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func text(atPath path: String, limit: Int = 1_048_576) -> String? {
        data(atPath: path, limit: limit).flatMap { String(data: $0, encoding: .utf8) }
    }
}
