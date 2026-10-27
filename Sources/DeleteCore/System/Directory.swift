import Darwin

/// Folder listings with `readdir`: a plan lists dozens of folders, some with thousands of entries
/// (the per-user temporary folder held 4,869), and Foundation's `contentsOfDirectory` costs about
/// ten times as much per entry.
enum Directory {
    /// The names in a folder (without `.` and `..`), or the `errno` it couldn't be read with.
    static func names(atPath path: String) -> Result<[String], DirectoryError> {
        guard let directory = opendir(path) else { return .failure(DirectoryError(code: errno)) }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return .success(names)
    }
}

struct DirectoryError: Error {
    let code: Int32
}
