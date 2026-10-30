import Darwin
import Foundation

/// The small terminal boundary for prompts, diagnostics, and presentation width.
enum TerminalInteraction {
    /// Standard output's width in columns when it is a terminal, nil otherwise.
    static var width: Int? {
        guard isatty(STDOUT_FILENO) == 1 else { return nil }
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return nil }
        return Int(size.ws_col)
    }

    /// Only "y" or "yes" confirms. Missing input, including no controlling terminal, is no.
    static func ask(_ question: String) -> Bool {
        guard let terminal = fopen("/dev/tty", "r+") else {
            printError("\(question.trimmingCharacters(in: .whitespaces))\nNo terminal to answer on; rerun in a terminal, or with -y.")
            return false
        }
        defer { fclose(terminal) }
        fputs(question, terminal)
        fflush(terminal)
        var buffer = [CChar](repeating: 0, count: 64)
        guard fgets(&buffer, Int32(buffer.count), terminal) != nil else { return false }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let answer = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }

    static func printError(_ message: String) {
        // Standard output is buffered and standard error isn't; flush so the two stay in order.
        fflush(stdout)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
