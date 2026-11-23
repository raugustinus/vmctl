import XCTest
@testable import VMCore

final class NameServiceTests: XCTestCase {
    static func query(_ name: String, type: UInt16 = 1, qclass: UInt16 = 1, id: UInt16 = 0xBEEF, flags: UInt8 = 0x01) -> [UInt8] {
        var packet: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xff), flags, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") { packet.append(UInt8(label.utf8.count)); packet += Array(label.utf8) }
        return packet + [0, UInt8(type >> 8), UInt8(type & 0xff), UInt8(qclass >> 8), UInt8(qclass & 0xff)]
    }
    let running = ["insights": "192.168.64.53"]
    func answer(_ packet: [UInt8]) -> [UInt8]? { NameService.response(to: packet) { self.running[$0] } }
    func rcode(_ reply: [UInt8]?) -> UInt8? { reply.map { $0[3] & 0x0F } }
    func answers(_ reply: [UInt8]?) -> Int? { reply.map { Int($0[6]) << 8 | Int($0[7]) } }

    func testARecordForARunningVM() throws {
        let query = Self.query("Insights.VM")
        let reply = try XCTUnwrap(answer(query))
        XCTAssertEqual(Array(reply[0..<2]), [0xBE, 0xEF])        // same ID
        XCTAssertEqual(reply[2] & 0x80, 0x80)                     // a response
        XCTAssertEqual(reply[2] & 0x04, 0x04)                     // authoritative
        XCTAssertEqual(reply[2] & 0x01, 0x01)                     // RD echoed
        XCTAssertEqual(reply[3], 0)                               // NOERROR, RA off
        XCTAssertEqual(answers(reply), 1)
        XCTAssertEqual(Array(reply[12..<query.count]), Array(query[12...])) // question echoed
        let record = Array(reply[query.count...])
        XCTAssertEqual(Array(record[0..<6]), [0xC0, 0x0C, 0, 1, 0, 1])
        XCTAssertEqual(Array(record[6..<10]), [0, 0, 0, UInt8(NameService.ttl)])
        XCTAssertEqual(Array(record[10...]), [0, 4, 192, 168, 64, 53])
    }

    func testOtherNamesAndTypes() {
        XCTAssertEqual(rcode(answer(Self.query("stopped.vm"))), 3)          // NXDOMAIN
        XCTAssertEqual(rcode(answer(Self.query("a.insights.vm"))), 3)
        XCTAssertEqual(rcode(answer(Self.query("Bad_Name.vm"))), 3)        // not a vmctl name: never looked up
        XCTAssertEqual(rcode(answer(Self.query("example.com"))), 5)         // REFUSED: not a resolver
        XCTAssertEqual(rcode(answer(Self.query("insights.vm", qclass: 3))), 5)
        let aaaa = answer(Self.query("insights.vm", type: 28))
        XCTAssertEqual(rcode(aaaa), 0); XCTAssertEqual(answers(aaaa), 0)    // NODATA: clients fall back to A
        XCTAssertEqual(rcode(answer(Self.query("vm", type: 6))), 0)        // the zone apex exists
        XCTAssertEqual(answers(answer(Self.query("insights.vm", type: 255))), 1)
    }

    func testMalformedPacketsNeverCrashOrAnswer() {
        XCTAssertNil(answer([1, 2, 3]))                                     // too short for an ID
        XCTAssertNil(answer(Self.query("insights.vm", flags: 0x81)))        // a response, not a query
        XCTAssertEqual(rcode(answer(Self.query("insights.vm", flags: 0x11))), 4) // opcode 2: NOTIMP
        var two = Self.query("insights.vm"); two[5] = 2
        XCTAssertEqual(rcode(answer(two)), 1)                               // FORMERR
        var pointer = Self.query("insights.vm"); pointer[12] = 0xC0
        XCTAssertEqual(rcode(answer(pointer)), 1)
        let full = Self.query("insights.vm")
        for length in 12..<full.count { XCTAssertEqual(rcode(answer(Array(full[0..<length]))), 1, "\(length)") }
        var overrun = Self.query("insights.vm"); overrun[12] = 63
        XCTAssertEqual(rcode(answer(overrun)), 1)
        // Random bytes: whatever comes back must not crash.
        for seed in 0..<2000 {
            var generator = SystemRandomNumberGenerator()
            let packet = (0..<(12 + seed % 60)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = answer(packet)
        }
    }
}
