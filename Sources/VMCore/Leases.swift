import Foundation
import Darwin

/// Best-effort guest address lookup in macOS's bootpd lease database. The file is an
/// implementation detail of NAT networking, not a Virtualization API: it may be missing,
/// unreadable, or hold several leases for one guest.
public enum Leases {
    public static let path = "/var/db/dhcpd_leases"

    public static func ip(mac: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return ip(mac: mac, in: text, now: Date())
    }

    /// The unexpired lease with the latest expiry whose client identifies itself by this MAC.
    /// A guest commonly holds two: the installer's DHCP client sends the bare MAC, while the
    /// installed system's client (dhcpcd, systemd-networkd) sends an RFC 4361 identifier.
    public static func ip(mac: String, in leases: String, now: Date) -> String? {
        guard let wanted = bytes(mac), wanted.count == 6 else { return nil }
        var best: (expiry: UInt64, ip: String)?
        for block in leases.components(separatedBy: "{") {
            var fields: [String: String] = [:]
            for line in block.components(separatedBy: .newlines) {
                let pair = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { fields[pair[0]] = pair[1] }
            }
            guard let hw = fields["hw_address"], matches(hw, mac: wanted), let ip = fields["ip_address"],
                  let expiry = fields["lease"].flatMap(number), Double(expiry) > now.timeIntervalSince1970 else { continue }
            var address = in_addr()
            guard inet_pton(AF_INET, ip, &address) == 1 else { continue }
            if best.map({ expiry > $0.expiry }) ?? true { best = (expiry, ip) }
        }
        return best?.ip
    }

    static func number(_ text: String) -> UInt64? {
        text.hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
    }

    /// Colon-separated hex bytes as bootpd writes them, without zero padding (`6:bd:af:95:a3:3`).
    static func bytes<S: StringProtocol>(_ text: S) -> [UInt8]? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        let values = parts.compactMap { UInt8($0, radix: 16) }
        return values.count == parts.count ? values : nil
    }

    /// `hw_address` is `<type>,<bytes>`. Type 1 is a bare Ethernet MAC. Type ff is an RFC 4361
    /// client identifier: a 4-byte IAID followed by a DUID. DUID-LLT (type 1) and DUID-LL (type 3)
    /// end in the link-layer address. DUID-EN (type 2) carries no MAC and cannot be matched.
    static func matches(_ hw: String, mac: [UInt8]) -> Bool {
        let parts = hw.split(separator: ",", maxSplits: 1)
        guard parts.count == 2, let type = UInt8(parts[0], radix: 16), let value = bytes(parts[1]) else { return false }
        switch type {
        case 1:
            return value == mac
        case 0xff:
            let duid = value.dropFirst(4)
            guard duid.count >= 2 + 2 + 6 else { return false }
            let duidType = Int(duid[duid.startIndex]) << 8 | Int(duid[duid.startIndex + 1])
            return (duidType == 1 || duidType == 3) && Array(duid.suffix(6)) == mac
        default:
            return false
        }
    }
}
