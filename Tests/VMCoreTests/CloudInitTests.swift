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
        let image = try CloudInit.seedImage(Provisioning(username: "dev", fullName: "Developer", password: "test-only-secret", sshPublicKey: Self.key), hostname: "lin")
        XCTAssertEqual(image.count, 1 << 20)
        XCTAssertEqual(Array(image[510..<512]), [0x55, 0xAA])
        XCTAssertEqual(String(decoding: image[43..<54], as: UTF8.self), "CIDATA     ")
        XCTAssertEqual(String(decoding: image[54..<62], as: UTF8.self), "FAT12   ")
        XCTAssertEqual(Self.fatEntry(image, 0), 0xFF8); XCTAssertEqual(Self.fatEntry(image, 1), 0xFFF)
        let entries = Self.rootEntries(image)
        XCTAssertEqual(entries.map(\.name), ["CIDATA", "user-data", "meta-data"])
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
