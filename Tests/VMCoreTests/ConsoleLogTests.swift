import XCTest
import Foundation
@testable import VMCore

final class ConsoleLogTests: XCTestCase {
    func testRotatesAtTheLimitKeepingTheStartOfTheRun() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("consolelog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("console.log"), previous = ConsoleLog.previous(url), start = ConsoleLog.start(url)
        XCTAssertEqual(start.lastPathComponent, "console.start.log")
        var log: ConsoleLog? = try ConsoleLog(url: url, limit: 10)
        log!.append(Data("12345678\n".utf8))
        log!.append(Data("abc\n".utf8))                    // would pass 10 bytes: rotates first
        XCTAssertEqual(try String(contentsOf: start, encoding: .utf8), "12345678\n") // the run's first file is kept
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "abc\n")
        log!.append(Data("defghij\n".utf8))
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "abc\n")
        log!.append(Data("klmnopq\n".utf8))
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "defghij\n") // the older file is replaced
        XCTAssertEqual(try String(contentsOf: start, encoding: .utf8), "12345678\n")  // never the start
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "klmnopq\n")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        log = nil
        // A reopened log appends; a symlink in its place is refused.
        log = try ConsoleLog(url: url, limit: 100)
        log!.append(Data("more\n".utf8))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "klmnopq\nmore\n")
        log = nil
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: previous)
        XCTAssertThrowsError(try ConsoleLog(url: url))
    }

    func testPrintableNeutralisesTerminalEscapes() {
        let raw = Data("\u{1B}[0;32m  OK  \u{1B}[0m Started\r\n\u{1B}]0;pwned\u{07}\u{1B}[2J\ttab\u{7F}\u{9B}é\n".utf8)
        XCTAssertEqual(ConsoleLog.printable(raw), "  OK   Started\n^[]0;pwned^G^[[2J\ttab^?\\u009Bé\n")
        // journald colours warnings with the colon form of 256-colour SGR.
        XCTAssertEqual(ConsoleLog.printable(Data("\u{1B}[0;1;38:5:185mwarn\u{1B}[0m\n".utf8)), "warn\n")
    }
}
