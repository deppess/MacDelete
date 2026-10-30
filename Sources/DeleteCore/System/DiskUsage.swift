import Darwin
import Foundation

public enum DiskUsage {
    public struct Usage: Sendable {
        public var bytes: Int64
        /// False when part of the tree couldn't be read; `bytes` is then a lower bound.
        public var complete: Bool
        /// Something inside belongs to another user than `owner` (root, typically).
        public var foreignOwned: Bool
    }

    /// Allocated bytes under `path`, like `du`: symlinks are not followed, a hard-linked file is
    /// counted once, and sparse files count only their allocated blocks. Never cached, because
    /// APFS doesn't update a folder's modification time when something deep inside it changes.
    public static func allocatedSize(of path: String, owner: uid_t? = nil) -> Usage {
        var usage = Usage(bytes: 0, complete: true, foreignOwned: false)
        var seenLinks = Set<FileKey>()
        let pathCopy = strdup(path)
        defer { free(pathCopy) }
        var paths: [UnsafeMutablePointer<CChar>?] = [pathCopy, nil]
        guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return Usage(bytes: 0, complete: false, foreignOwned: false) }
        defer { fts_close(stream) }
        while let entry = fts_read(stream) {
            switch Int32(entry.pointee.fts_info) {
            case FTS_DNR, FTS_ERR, FTS_NS:
                usage.complete = false
            case FTS_D:
                continue  // counted once, on the way out (FTS_DP)
            default:
                guard let info = entry.pointee.fts_statp?.pointee else { continue }
                if let owner, info.st_uid != owner { usage.foreignOwned = true }
                if info.st_nlink > 1, (info.st_mode & S_IFMT) != S_IFDIR {
                    guard seenLinks.insert(FileKey(device: info.st_dev, inode: info.st_ino)).inserted else { continue }
                }
                usage.bytes += Int64(info.st_blocks) * 512
            }
        }
        return usage
    }

    private struct FileKey: Hashable {
        let device: Int32
        let inode: UInt64
    }
}
