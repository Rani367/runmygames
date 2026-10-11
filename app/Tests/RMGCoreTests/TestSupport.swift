import Foundation
import XCTest
@testable import RMGCore

/// A throwaway folder per test, removed afterwards.
class TempDirTestCase: XCTestCase {
    var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rmg-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    /// Paths whose every location (including the "user home") lives inside `tmp`.
    var paths: Paths {
        Paths(home: tmp.appendingPathComponent("home"), resources: tmp.appendingPathComponent("res"),
              userHome: tmp.appendingPathComponent("user"))
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Runs /usr/bin/tar to build a .tar.gz of `dir`'s contents (top-level entries as given).
    func tarball(of dir: URL, entries: [String], to out: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-czf", out.path, "-C", dir.path] + entries
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }
}
