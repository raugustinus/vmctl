import Foundation
import Darwin

/// Answers DNS queries for `<name>.vm` from the VMs vmd is running. Pure: a query packet in,
/// a response packet out. vmd serves it on 127.0.0.1 only; a resolver such as dnsmasq forwards
/// the `vm` zone to it (`server=/vm/127.0.0.1#15353`).
///
/// Deliberately tiny: one question, class IN, A records only (vmnet hands guests IPv4 leases).
/// Anything outside the zone is refused, so it can never act as a general resolver.
public enum NameService {
    public static let zone = "vm"
    public static let port: UInt16 = 15353
    /// Short, because a lease can change when a VM restarts.
    public static let ttl: UInt32 = 5

    enum RCode: UInt8 { case noError = 0, formatError = 1, nameError = 3, notImplemented = 4, refused = 5 }

    /// `lookup` gets a validated VM name and returns its IPv4 address while it runs, else nil.
    /// Returns nil for packets that get no reply at all: responses, and anything too short to carry an ID.
    public static func response(to query: [UInt8], lookup: (String) -> String?) -> [UInt8]? {
        guard query.count >= 12, query[2] & 0x80 == 0 else { return nil }
        func reply(_ code: RCode, question: ArraySlice<UInt8> = [], answer: [UInt8] = []) -> [UInt8] {
            // ID, then QR + AA with the query's opcode and RD bit; RA off: this server never recurses.
            var out = [query[0], query[1], 0x84 | query[2] & 0x79, code.rawValue]
            out += [0, question.isEmpty ? 0 : 1, 0, answer.isEmpty ? 0 : 1, 0, 0, 0, 0]
            return out + question + answer
        }
        guard (query[2] >> 3) & 0x0F == 0 else { return reply(.notImplemented) }
        guard query[4] == 0, query[5] == 1 else { return reply(.formatError) }

        // QNAME: plain labels only. A query has nothing to point back to, so compression is malformed.
        var labels: [String] = [], offset = 12, nameLength = 0
        while true {
            guard offset < query.count else { return reply(.formatError) }
            let length = Int(query[offset])
            if length == 0 { offset += 1; break }
            nameLength += length + 1
            guard length < 64, nameLength < 255, offset + 1 + length <= query.count else { return reply(.formatError) }
            labels.append(String(decoding: query[offset + 1 ..< offset + 1 + length], as: UTF8.self).lowercased())
            offset += 1 + length
        }
        guard offset + 4 <= query.count else { return reply(.formatError) }
        let question = query[12 ..< offset + 4]
        let type = UInt16(query[offset]) << 8 | UInt16(query[offset + 1])
        let qclass = UInt16(query[offset + 2]) << 8 | UInt16(query[offset + 3])

        guard labels.last == zone, qclass == 1 || qclass == 255 else { return reply(.refused, question: question) }
        if labels.count == 1 { return reply(.noError, question: question) }
        guard labels.count == 2, (try? validateName(labels[0])) != nil, let ip = lookup(labels[0]) else {
            return reply(.nameError, question: question)
        }
        // Any type but A (or ANY) gets an empty answer, so clients asking AAAA move on at once.
        var address = in_addr()
        guard type == 1 || type == 255, inet_pton(AF_INET, ip, &address) == 1 else { return reply(.noError, question: question) }
        let octets = withUnsafeBytes(of: address.s_addr) { Array($0) } // already network order
        let ttlBytes = (0..<4).map { UInt8(truncatingIfNeeded: ttl >> (24 - 8 * $0)) }
        // Name as a pointer to the question's name at offset 12, type A, class IN, TTL, 4-byte address.
        let answer: [UInt8] = [0xC0, 0x0C, 0, 1, 0, 1] + ttlBytes + [0, 4] + octets
        return reply(.noError, question: question, answer: answer)
    }
}
