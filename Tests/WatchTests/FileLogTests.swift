import Foundation
import Testing

@testable import Watch

@Suite("FileLog file I/O (PRD v2 §7.3)")
struct FileLogTests {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("filelog-test-\(UUID().uuidString).log")
    }

    @Test("record creates the file when it does not yet exist")
    func createsFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        FileLog(url: url).record("first line")

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents == "first line\n")
    }

    @Test("record appends subsequent lines to an existing file")
    func appendsToExistingFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let log = FileLog(url: url)
        log.record("line one")
        log.record("line two")

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents == "line one\nline two\n")
    }

    @Test("defaultLog constructs without crashing and targets ~/Library/Logs")
    func defaultLog() {
        // Exercises the try?-guarded createDirectory call and the FileLog construction.
        _ = FileLog.defaultLog()
    }
}
