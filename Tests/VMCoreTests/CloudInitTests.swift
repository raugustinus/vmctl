import XCTest
import Foundation
@testable import VMCore

final class CloudInitTests: XCTestCase {
    static let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJJZYARy5Bs72WqSK9IQguYtidDHjXbrMbD5wKnDSfBS vmctl-test"

    func testSHA512CryptMatchesReferenceImplementations() {
        // Drepper's specification vector, then OpenSSL `passwd -6` outputs (16-byte salt truncation, >64-byte password, UTF-8).
        XCTAssertEqual(CloudInit.sha512Crypt("Hello world!", salt: "saltstring"),
                       "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1")
        XCTAssertEqual(CloudInit.sha512Crypt("This password is deliberately longer than sixty-four bytes to exercise the digest repetition paths!", salt: "saltstringsaltstring"),
                       "$6$saltstringsaltst$GDz.8QjRjg3iDe/rzR4XPzCsqPGJI/icGhZ1d4BCPryHSbcQTrsv9FMItb9pEikaeF7sYAFOBYp2dFi7G9.67/")
        XCTAssertEqual(CloudInit.sha512Crypt("pässwörd", salt: "Zz9./x"),
                       "$6$Zz9./x$NWIkScsNJ0GiagmYrebzXB8LUhOB4CELU5FNEQQ22GX8gIDfSgtXDmLrMEJP3jncTRW3uPF5eLfBs4BV1iatc.")
        XCTAssertTrue(CloudInit.sha512Crypt("x", salt: "s", rounds: 1000).hasPrefix("$6$rounds=1000$s$"))
        let salt = CloudInit.randomSalt()
        XCTAssertEqual(salt.count, 16)
        XCTAssertTrue(salt.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "./")).contains($0) })
    }

    func testUserDataNeverContainsThePlaintextPassword() throws {
        let both = try CloudInit.userData(Provisioning(username: "dev", fullName: "Dev \"Quoted\": Name", password: "test-only-secret", sshPublicKey: Self.key), hostname: "lin")
        XCTAssertTrue(both.hasPrefix("#cloud-config\n"))
        XCTAssertFalse(both.contains("test-only-secret"))
        XCTAssertTrue(both.contains("\"passwd\":\"$6$"))
        XCTAssertTrue(both.contains("\"lock_passwd\":false"))
        XCTAssertTrue(both.contains("\"ssh_pwauth\":true"))
        XCTAssertTrue(both.contains("\"ssh_authorized_keys\":[\"\(Self.key)\"]"))
        XCTAssertTrue(both.contains("\"gecos\":\"Dev \\\"Quoted\\\": Name\""))
        XCTAssertTrue(both.contains("\"shell\":\"/bin/bash\""))
        XCTAssertTrue(both.contains("\"hostname\":\"lin\""))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(both.dropFirst("#cloud-config\n".count).utf8)) as? [String: Any])
        XCTAssertEqual((object["users"] as? [[String: Any]])?.count, 1)
        let keyOnly = try CloudInit.userData(Provisioning(username: "dev", fullName: "Developer", password: nil, sshPublicKey: Self.key), hostname: "lin")
        XCTAssertTrue(keyOnly.contains("\"lock_passwd\":true"))
        XCTAssertFalse(keyOnly.contains("passwd\":\"$6"))
        XCTAssertTrue(keyOnly.contains("\"ssh_pwauth\":false"))
        XCTAssertEqual(CloudInit.metaData(instanceID: "iid-1", hostname: "lin"), "instance-id: iid-1\nlocal-hostname: lin\n")
    }

    func testLocaleAndShareBecomeRuncmdAndFstab() throws {
        func object(_ text: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.dropFirst("#cloud-config\n".count).utf8)) as? [String: Any])
        }
        // Neither: only the console setup, no uid, and never cloud-init's own locale key.
        let plain = try object(CloudInit.userData(Provisioning(username: "dev", fullName: "Dev", password: nil, sshPublicKey: Self.key), hostname: "lin"))
        XCTAssertEqual((plain["runcmd"] as? [Any])?.count, 1); XCTAssertEqual((plain["write_files"] as? [Any])?.count, 2)
        XCTAssertNil(plain["locale"]); XCTAssertNil(plain["ssh_keys"])
        XCTAssertEqual((plain["power_state"] as? [String: String])?["mode"], "reboot")
        let journald = (plain["write_files"] as? [[String: Any]])?.first?["content"] as? String
        XCTAssertTrue(journald?.contains("MaxLevelConsole=warning") == true, journald ?? "")
        // A host-generated host key replaces the image's keys, and no other key types are generated.
        let keyed = try object(CloudInit.userData(Provisioning(username: "dev", fullName: "Dev", password: nil, sshPublicKey: Self.key), hostname: "lin",
                                                  hostKey: CloudInit.HostKey(privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nx\n-----END OPENSSH PRIVATE KEY-----\n", publicKey: Self.key)))
        XCTAssertEqual(keyed["ssh_keys"] as? [String: String], ["ed25519_private": "-----BEGIN OPENSSH PRIVATE KEY-----\nx\n-----END OPENSSH PRIVATE KEY-----\n", "ed25519_public": Self.key])
        XCTAssertEqual(keyed["ssh_genkeytypes"] as? [String], ["ed25519"]); XCTAssertEqual(keyed["ssh_deletekeys"] as? Bool, true)
        XCTAssertNil((plain["users"] as? [[String: Any]])?.first?["uid"])

        let account = Provisioning(username: "dev", fullName: "Dev", password: nil, sshPublicKey: Self.key, locale: "en_US.UTF-8")
        let share = CloudInit.SeedShare(name: "unia", readOnly: false, hostUID: 501)
        let both = try object(CloudInit.userData(account, hostname: "lin", share: share))
        XCTAssertNil(both["locale"])
        XCTAssertEqual((both["users"] as? [[String: Any]])?.first?["uid"] as? Int, 501)
        let files = try XCTUnwrap(both["write_files"] as? [[String: Any]])
        XCTAssertEqual(files.last?["path"] as? String, "/etc/fstab"); XCTAssertEqual(files.last?["append"] as? Bool, true)
        XCTAssertEqual(files.last?["content"] as? String, "vmctl /home/dev/unia virtiofs rw,nofail 0 0\n")
        let runcmd = try XCTUnwrap(both["runcmd"] as? [Any])
        XCTAssertEqual(runcmd.count, 4)
        let localeStep = try XCTUnwrap(runcmd[1] as? String)
        XCTAssertTrue(localeStep.hasPrefix("(") && localeStep.hasSuffix(")"), localeStep) // a subshell: its exit skips nothing else
        XCTAssertTrue(localeStep.contains("echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen") && localeStep.contains("locale-gen en_US.UTF-8"), localeStep)
        XCTAssertEqual(runcmd[2] as? [String], ["mkdir", "-p", "/home/dev/unia"])
        XCTAssertEqual(runcmd[3] as? [String], ["mount", "/home/dev/unia"])

        let readOnly = try object(CloudInit.userData(account, hostname: "lin", share: CloudInit.SeedShare(name: "p", readOnly: true, hostUID: 501)))
        XCTAssertEqual((readOnly["write_files"] as? [[String: Any]])?.last?["content"] as? String, "vmctl /home/dev/p virtiofs ro,nofail 0 0\n")
    }

    func testDNSReplacesTheGatewayServer() throws {
        func object(_ text: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let plain = try object(CloudInit.networkConfig(mac: "F6:12:32:EC:B2:F8"))
        let plainNIC = try XCTUnwrap((plain["ethernets"] as? [String: Any])?["primary"] as? [String: Any])
        XCTAssertNil(plainNIC["nameservers"]); XCTAssertNil(plainNIC["dhcp4-overrides"])

        let set = try object(CloudInit.networkConfig(mac: "F6:12:32:EC:B2:F8", dns: "10.254.254.254"))
        let nic = try XCTUnwrap((set["ethernets"] as? [String: Any])?["primary"] as? [String: Any])
        XCTAssertEqual((nic["nameservers"] as? [String: [String]])?["addresses"], ["10.254.254.254"])
        XCTAssertEqual((nic["dhcp4-overrides"] as? [String: Bool])?["use-dns"], false)
        XCTAssertEqual((nic["match"] as? [String: String])?["macaddress"], "f6:12:32:ec:b2:f8")

        // Router advertisements are turned off by a networkd drop-in on netplan's unit for "primary".
        let account = Provisioning(username: "dev", fullName: "Dev", password: nil, sshPublicKey: Self.key, dns: "10.254.254.254")
        let userData = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try CloudInit.userData(account, hostname: "lin").dropFirst("#cloud-config\n".count).utf8)) as? [String: Any])
        let dropIn = try XCTUnwrap((userData["write_files"] as? [[String: Any]])?.first { ($0["path"] as? String)?.hasSuffix("50-vmctl-dns.conf") == true })
        XCTAssertEqual(dropIn["path"] as? String, "/etc/systemd/network/10-netplan-primary.network.d/50-vmctl-dns.conf")
        XCTAssertTrue((dropIn["content"] as? String)?.contains("[IPv6AcceptRA]\nUseDNS=no") == true)

        XCTAssertNoThrow(try account.validate())
        XCTAssertNoThrow(try Provisioning(username: "dev", fullName: "Dev", password: nil, sshPublicKey: Self.key, dns: "fd00::53").validate())
        for bad in ["dnsmasq.local", "10.254.254", "10.254.254.254; reboot", ""] {
            XCTAssertThrowsError(try Provisioning(username: "dev", fullName: "Dev", password: nil, sshPublicKey: Self.key, dns: bad).validate(), bad)
        }
    }

    // Minimal FAT12 reader used only to verify what the writer produced.
    struct Entry { let name: String; let cluster: Int; let size: Int; let attributes: UInt8 }
    static func rootEntries(_ image: Data) -> [Entry] {
        let rootOffset = (FAT12.reservedSectors + FAT12.fatCount * FAT12.fatSectors) * FAT12.sectorSize
        var entries: [Entry] = []; var longName: [Int: String] = [:]
        for index in 0..<FAT12.rootEntries {
            let o = rootOffset + index * 32
            let e = Array(image[o..<o + 32])
            if e[0] == 0 { break }
            if e[11] == 0x0F {
                let units = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30].map { UInt16(e[$0]) | UInt16(e[$0 + 1]) << 8 }
                let text = String(decoding: units.prefix { $0 != 0 && $0 != 0xFFFF }, as: UTF16.self)
                longName[Int(e[0] & 0x3F)] = text; continue
            }
            let assembled = longName.keys.sorted().compactMap { longName[$0] }.joined()
            let short = String(decoding: e[0..<11], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            entries.append(Entry(name: assembled.isEmpty ? short : assembled, cluster: Int(e[26]) | Int(e[27]) << 8,
                                 size: Int(e[28]) | Int(e[29]) << 8 | Int(e[30]) << 16 | Int(e[31]) << 24, attributes: e[11]))
            longName = [:]
        }
        return entries
    }
    static func fatEntry(_ image: Data, _ cluster: Int) -> Int {
        let o = FAT12.reservedSectors * FAT12.sectorSize + cluster * 3 / 2
        let pair = Int(image[o]) | Int(image[o + 1]) << 8
        return cluster & 1 == 0 ? pair & 0xFFF : pair >> 4
    }
    static func contents(_ image: Data, _ entry: Entry) -> Data {
        var data = Data(); var cluster = entry.cluster
        while cluster >= 2 && cluster < 0xFF8 {
            let o = (FAT12.firstDataSector + cluster - 2) * FAT12.sectorSize
            data.append(image[o..<o + FAT12.sectorSize]); cluster = fatEntry(image, cluster)
        }
        return data.prefix(entry.size)
    }

    func testSeedImageIsAValidLabelledFAT12VolumeWithLongNames() throws {
        let image = try CloudInit.seedImage(Provisioning(username: "dev", fullName: "Developer", password: "test-only-secret", sshPublicKey: Self.key), hostname: "lin", mac: "F6:12:32:EC:B2:F8")
        XCTAssertEqual(image.count, 1 << 20)
        XCTAssertEqual(Array(image[510..<512]), [0x55, 0xAA])
        XCTAssertEqual(String(decoding: image[43..<54], as: UTF8.self), "CIDATA     ")
        XCTAssertEqual(String(decoding: image[54..<62], as: UTF8.self), "FAT12   ")
        XCTAssertEqual(Self.fatEntry(image, 0), 0xFF8); XCTAssertEqual(Self.fatEntry(image, 1), 0xFFF)
        let entries = Self.rootEntries(image)
        XCTAssertEqual(entries.map(\.name), ["CIDATA", "user-data", "meta-data", "network-config"])
        XCTAssertEqual(String(decoding: Self.contents(image, entries[3]), as: UTF8.self),
                       #"{"ethernets":{"primary":{"dhcp-identifier":"mac","dhcp4":true,"match":{"macaddress":"f6:12:32:ec:b2:f8"}}},"version":2}"# + "\n")
        XCTAssertEqual(entries[0].attributes, 0x08)
        let userData = String(decoding: Self.contents(image, entries[1]), as: UTF8.self)
        XCTAssertTrue(userData.hasPrefix("#cloud-config\n"))
        XCTAssertFalse(userData.contains("test-only-secret"))
        XCTAssertTrue(String(decoding: Self.contents(image, entries[2]), as: UTF8.self).hasPrefix("instance-id: vmctl-lin-"))
        // Both FAT copies are identical.
        let fatSize = FAT12.fatSectors * FAT12.sectorSize
        XCTAssertEqual(image[FAT12.sectorSize..<FAT12.sectorSize + fatSize], image[FAT12.sectorSize + fatSize..<FAT12.sectorSize + 2 * fatSize])
    }

    func testMultiClusterChainsAndLimits() throws {
        let name = "a-long-file-name-with-many-characters.txt" // 41 UTF-16 units: four long-name entries
        let payload = Data((0..<1500).map { UInt8($0 % 251) })
        let image = try FAT12.image(label: "cidata", files: [(name: name, data: payload), (name: "b", data: Data("x".utf8))])
        let entries = Self.rootEntries(image)
        XCTAssertEqual(entries.map(\.name), ["CIDATA", name, "b"])
        XCTAssertEqual(entries[1].cluster, 2); XCTAssertEqual(entries[2].cluster, 5)
        XCTAssertEqual(Self.fatEntry(image, 2), 3); XCTAssertEqual(Self.fatEntry(image, 3), 4)
        XCTAssertEqual(Self.fatEntry(image, 4), 0xFFF); XCTAssertEqual(Self.fatEntry(image, 5), 0xFFF)
        XCTAssertEqual(Self.contents(image, entries[1]), payload)
        XCTAssertEqual(Self.contents(image, entries[2]), Data("x".utf8))
        XCTAssertThrowsError(try FAT12.image(label: "cidata", files: [(name: "big", data: Data(count: 1 << 20))]))
        XCTAssertThrowsError(try FAT12.image(label: "cidata", files: [(name: "", data: Data("x".utf8))]))
        XCTAssertThrowsError(try FAT12.image(label: "cidata", files: [(name: "empty", data: Data())]))
    }
}
