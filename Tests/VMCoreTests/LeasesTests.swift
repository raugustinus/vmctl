import XCTest
import VMCore

final class LeasesTests: XCTestCase {
    // Taken verbatim from /var/db/dhcpd_leases after a Debian netinst install: the installer's
    // client leased .36 with the bare MAC, the installed dhcpcd leased .37 with a DUID-LLT.
    static let leases = """
    {
    \tname=vmdeb
    \tip_address=192.168.64.37
    \thw_address=ff,c9:f0:66:26:0:1:0:1:32:6e:72:65:86:5e:c9:f0:66:26
    \tidentifier=ff,c9:f0:66:26:0:1:0:1:32:6e:72:65:86:5e:c9:f0:66:26
    \tlease=0x6adbc523
    }
    {
    \tip_address=192.168.64.36
    \thw_address=1,86:5e:c9:f0:66:26
    \tidentifier=1,86:5e:c9:f0:66:26
    \tlease=0x6adbbdd2
    }
    {
    \tip_address=192.168.64.35
    \thw_address=1,56:6b:35:99:6a:de
    \tidentifier=1,56:6b:35:99:6a:de
    \tlease=0x6adbad11
    }
    {
    \tname=debian-vm
    \tip_address=192.168.64.25
    \thw_address=ff,f1:f5:dd:7f:0:2:0:0:ab:11:5a:25:2f:11:a7:3c:88:9f
    \tidentifier=ff,f1:f5:dd:7f:0:2:0:0:ab:11:5a:25:2f:11:a7:3c:88:9f
    \tlease=0x69bca62e
    }
    {
    \tip_address=192.168.64.2
    \thw_address=1,6:bd:af:95:a3:3
    \tidentifier=1,6:bd:af:95:a3:3
    \tlease=0x68626f21
    }
    """
    let now = Date(timeIntervalSince1970: 1_792_784_205) // 2026-10-23 19:36:45 UTC

    func testPrefersNewestUnexpiredLeaseAcrossIdentifierTypes() {
        XCTAssertEqual(Leases.ip(mac: "86:5e:c9:f0:66:26", in: Self.leases, now: now), "192.168.64.37")
        // With the DUID lease gone, the bare-MAC lease from the installer still resolves.
        let withoutDUID = Self.leases.components(separatedBy: "{").filter { !$0.contains("vmdeb") }.joined(separator: "{")
        XCTAssertEqual(Leases.ip(mac: "86:5e:c9:f0:66:26", in: withoutDUID, now: now), "192.168.64.36")
    }

    func testDUIDVariants() {
        let ll = "{\n\tip_address=192.168.64.40\n\thw_address=ff,1:2:3:4:0:3:0:1:aa:bb:cc:dd:ee:ff\n\tlease=0x6adbc523\n}"
        XCTAssertEqual(Leases.ip(mac: "aa:bb:cc:dd:ee:ff", in: ll, now: now), "192.168.64.40")
        // DUID-EN carries no link-layer address; it must never match by coincidence of trailing bytes.
        let en = "{\n\tip_address=192.168.64.41\n\thw_address=ff,1:2:3:4:0:2:0:0:ab:11:aa:bb:cc:dd:ee:ff\n\tlease=0x6adbc523\n}"
        XCTAssertNil(Leases.ip(mac: "aa:bb:cc:dd:ee:ff", in: en, now: now))
        XCTAssertNil(Leases.ip(mac: "AA:BB:CC:DD:EE:FF", in: en, now: now))
    }

    func testIgnoresExpiredOtherAndMalformedEntries() {
        XCTAssertEqual(Leases.ip(mac: "06:bd:af:95:a3:03", in: Self.leases, now: Date(timeIntervalSince1970: 1_700_000_000)), "192.168.64.2")
        XCTAssertNil(Leases.ip(mac: "06:bd:af:95:a3:03", in: Self.leases, now: now)) // expired
        XCTAssertNil(Leases.ip(mac: "56:6b:35:99:6a:de", in: Self.leases, now: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertNil(Leases.ip(mac: "00:11:22:33:44:55", in: Self.leases, now: now))
        XCTAssertNil(Leases.ip(mac: "not-a-mac", in: Self.leases, now: now))
        XCTAssertNil(Leases.ip(mac: "86:5e:c9:f0:66:26", in: "{\n\tip_address=999.1.1.1\n\thw_address=1,86:5e:c9:f0:66:26\n\tlease=0x6adbc523\n}", now: now))
        XCTAssertNil(Leases.ip(mac: "86:5e:c9:f0:66:26", in: "", now: now))
    }
}
