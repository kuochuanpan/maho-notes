import Testing
import Foundation
@testable import MahoNotesKit

@Suite("nextFileNumber")
struct NextFileNumberTests {
    @Test func emptyDirectory() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let num = try nextFileNumber(in: tmp.path)
        #expect(num == 1)

        try fm.removeItem(at: tmp)
    }

    @Test func withExistingFiles() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        try "".write(to: tmp.appendingPathComponent("001-first.md"), atomically: true, encoding: .utf8)
        try "".write(to: tmp.appendingPathComponent("003-third.md"), atomically: true, encoding: .utf8)
        try "".write(to: tmp.appendingPathComponent("_index.md"), atomically: true, encoding: .utf8)

        let num = try nextFileNumber(in: tmp.path)
        #expect(num == 4)

        try fm.removeItem(at: tmp)
    }

    @Test func nonexistentDirectory() throws {
        let num = try nextFileNumber(in: "/nonexistent/path/\(UUID().uuidString)")
        #expect(num == 1)
    }
}
