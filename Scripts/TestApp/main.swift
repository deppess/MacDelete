// A disposable app for testing real deletions (Scripts/testapps). Launched normally it writes the
// leftovers a real app leaves, keyed by its own bundle identifier and name, then keeps running as
// a menu-bar-less accessory so `delete` has to ask it to quit. With --agent (how its launch items
// run it) it exits at once.
import AppKit

if CommandLine.arguments.contains("--agent") { exit(0) }

let identifier = Bundle.main.bundleIdentifier ?? "com.macdelete.test.unknown"
let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "DeleteTest"
let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
let stamp = ISO8601DateFormatter().string(from: Date())

UserDefaults.standard.set(stamp, forKey: "lastLaunch")
UserDefaults.standard.synchronize()
for relative in ["Application Support/\(identifier)/data.txt", "Caches/\(identifier)/cache.txt", "Logs/\(identifier)/run.log", "HTTPStorages/\(identifier)/storage.txt",
                 "Application Support/\(name)/note.txt"] {
    let file = library.appending(path: relative)
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data("written by \(identifier) at \(stamp)\n".utf8).write(to: file)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.run()
