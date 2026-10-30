import Foundation
import XCTest
@testable import DeleteCore

final class CommandRunnerTests: XCTestCase {
    func testCapturesSeparatedOutputAndExitStatus() throws {
        let result = try CommandRunner().run(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "printf out; printf err >&2; exit 23"],
            environment: ["PATH": "/usr/bin:/bin"], timeout: 5, outputLimit: 1_024)

        XCTAssertEqual(result.status, 23)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err")
    }

    func testTerminatesCommandThatExceedsOutputLimit() {
        XCTAssertThrowsError(
            try CommandRunner().run(
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", "yes x"],
                environment: ["PATH": "/usr/bin:/bin"], timeout: 5, outputLimit: 1_024)
        ) { error in
            guard let runnerError = error as? CommandRunnerError,
                case let .outputTooLarge(url) = runnerError
            else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(url.path, "/bin/sh")
        }
    }

    func testTerminatesCommandThatTimesOut() {
        XCTAssertThrowsError(
            try CommandRunner().run(
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", "sleep 30"],
                environment: ["PATH": "/usr/bin:/bin"], timeout: 0.05, outputLimit: 1_024)
        ) { error in
            guard let runnerError = error as? CommandRunnerError,
                case let .timedOut(url) = runnerError
            else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(url.path, "/bin/sh")
        }
    }
}
