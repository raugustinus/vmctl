import Foundation
import CryptoKit

/// Builds a cloud-init NoCloud seed for Linux guests. Pure data; nothing here touches
/// the filesystem or runs a command. The seed is a 1 MiB FAT12 volume labelled CIDATA
/// holding `user-data` and `meta-data`, which cloud-init discovers by volume label.
public enum CloudInit {
    /// `#cloud-config` document. Emitted as JSON, which is valid YAML, so no scalar needs
    /// hand quoting. Only the configured account is created: no distro default user.
    public static func userData(_ account: Provisioning, hostname: String) throws -> String {
        var user: [String: Any] = ["name": account.username, "gecos": account.fullName,
                                   "shell": "/bin/bash", "sudo": "ALL=(ALL) NOPASSWD:ALL"]
        if let password = account.password {
            user["lock_passwd"] = false
            user["passwd"] = sha512Crypt(password, salt: randomSalt())
        } else { user["lock_passwd"] = true }
        if let key = account.sshPublicKey { user["ssh_authorized_keys"] = [key] }
        let config: [String: Any] = ["hostname": hostname, "users": [user], "ssh_pwauth": account.password != nil]
        let json = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])
        return "#cloud-config\n" + String(decoding: json, as: UTF8.self) + "\n"
    }
    public static func metaData(instanceID: String, hostname: String) -> String {
        "instance-id: \(instanceID)\nlocal-hostname: \(hostname)\n"
    }
    public static func seedImage(_ account: Provisioning, hostname: String) throws -> Data {
        try FAT12.image(label: "CIDATA", files: [
            (name: "user-data", data: Data(try userData(account, hostname: hostname).utf8)),
            (name: "meta-data", data: Data(metaData(instanceID: "vmctl-\(hostname)-\(UUID().uuidString.lowercased())", hostname: hostname).utf8))
        ])
    }

    static let cryptAlphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    public static func randomSalt() -> String {
        String(decoding: (0..<16).map { _ in cryptAlphabet[Int.random(in: 0..<64)] }, as: UTF8.self)
    }
    /// sha512-crypt (`$6$`) per Drepper's "Unix crypt using SHA-256 and SHA-512". Only the
    /// hash enters the seed; the plaintext password never reaches disk.
    public static func sha512Crypt(_ password: String, salt rawSalt: String, rounds: Int = 5000) -> String {
        let pw = Array(password.utf8)
        let salt = Array(rawSalt.utf8.prefix(16))
        func h(_ parts: [[UInt8]]) -> [UInt8] {
            var context = SHA512(); parts.forEach { context.update(data: $0) }; return Array(context.finalize())
        }
        func repeated(_ block: [UInt8], count: Int) -> [UInt8] {
            var out = [UInt8](); out.reserveCapacity(count)
            while out.count < count { out.append(contentsOf: block.prefix(count - out.count)) }
            return out
        }
        let b = h([pw, salt, pw])
        var aParts: [[UInt8]] = [pw, salt, repeated(b, count: pw.count)]
        var bits = pw.count
        while bits > 0 { aParts.append(bits & 1 == 1 ? b : pw); bits >>= 1 }
        let a = h(aParts)
        let p = repeated(h(Array(repeating: pw, count: pw.count)), count: pw.count)
        let s = repeated(h(Array(repeating: salt, count: 16 + Int(a[0]))), count: salt.count)
        var c = a
        for i in 0..<rounds {
            var parts: [[UInt8]] = [i & 1 == 1 ? p : c]
            if i % 3 != 0 { parts.append(s) }
            if i % 7 != 0 { parts.append(p) }
            parts.append(i & 1 == 1 ? c : p)
            c = h(parts)
        }
        var out = [UInt8]()
        func encode(_ b2: UInt8, _ b1: UInt8, _ b0: UInt8, _ n: Int) {
            var w = UInt32(b2) << 16 | UInt32(b1) << 8 | UInt32(b0)
            for _ in 0..<n { out.append(cryptAlphabet[Int(w & 0x3f)]); w >>= 6 }
        }
        let order = [(0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4), (47, 5, 26), (6, 27, 48),
                     (28, 49, 7), (50, 8, 29), (9, 30, 51), (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13),
                     (56, 14, 35), (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19), (62, 20, 41)]
        for (x, y, z) in order { encode(c[x], c[y], c[z], 4) }
        encode(0, 0, c[63], 2)
        let prefix = rounds == 5000 ? "" : "rounds=\(rounds)$"
        return "$6$" + prefix + String(decoding: salt, as: UTF8.self) + "$" + String(decoding: out, as: UTF8.self)
    }
}

/// Minimal FAT12 volume writer with VFAT long file names. 512-byte sectors, one sector
/// per cluster, 1 MiB total. Enough for a cloud-init seed; not a general filesystem.
public enum FAT12 {
    public static let sectorSize = 512, totalSectors = 2048, reservedSectors = 1, fatSectors = 6, fatCount = 2, rootEntries = 512
    public static var rootSectors: Int { rootEntries * 32 / sectorSize }
    public static var firstDataSector: Int { reservedSectors + fatCount * fatSectors + rootSectors }

    public static func image(label: String, files: [(name: String, data: Data)]) throws -> Data {
        var image = Data(count: totalSectors * sectorSize)
        func put(_ bytes: [UInt8], at offset: Int) { image.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)] }
        let volumeLabel = pad(label.uppercased(), 11)
        put([0xEB, 0x3C, 0x90], at: 0); put(Array("MSWIN4.1".utf8), at: 3)
        put(le16(sectorSize), at: 11); put([1], at: 13); put(le16(reservedSectors), at: 14)
        put([UInt8(fatCount)], at: 16); put(le16(rootEntries), at: 17); put(le16(totalSectors), at: 19)
        put([0xF8], at: 21); put(le16(fatSectors), at: 22); put(le16(32), at: 24); put(le16(2), at: 26)
        put([0x80, 0, 0x29], at: 36); put(le32(UInt32.random(in: 1...UInt32.max)), at: 39)
        put(volumeLabel, at: 43); put(Array("FAT12   ".utf8), at: 54); put([0x55, 0xAA], at: 510)

        var fat = [UInt8](repeating: 0, count: fatSectors * sectorSize)
        func setFAT(_ cluster: Int, _ value: Int) {
            let o = cluster * 3 / 2
            if cluster & 1 == 0 { fat[o] = UInt8(value & 0xff); fat[o + 1] = fat[o + 1] & 0xF0 | UInt8(value >> 8 & 0x0f) }
            else { fat[o] = fat[o] & 0x0F | UInt8(value & 0x0f) << 4; fat[o + 1] = UInt8(value >> 4 & 0xff) }
        }
        setFAT(0, 0xFF8); setFAT(1, 0xFFF)
        var root = directoryEntry(shortName: volumeLabel, attributes: 0x08, cluster: 0, size: 0)
        var nextCluster = 2
        let lastCluster = totalSectors - firstDataSector + 1
        for (index, file) in files.enumerated() {
            guard !file.name.isEmpty, file.name.utf16.count <= 255, !file.data.isEmpty else {
                throw Failure("invalid_seed", "Seed files need a name of 1–255 characters and content.")
            }
            let clusters = (file.data.count + sectorSize - 1) / sectorSize
            guard nextCluster + clusters - 1 <= lastCluster else { throw Failure("seed_too_large", "Seed content exceeds the 1 MiB volume.") }
            for i in 0..<clusters { setFAT(nextCluster + i, i == clusters - 1 ? 0xFFF : nextCluster + i + 1) }
            let offset = (firstDataSector + nextCluster - 2) * sectorSize
            image.replaceSubrange(offset..<offset + file.data.count, with: file.data)
            let short = shortName(file.name, index: index + 1)
            root += longNameEntries(file.name, checksum: checksum(short))
            root += directoryEntry(shortName: short, attributes: 0x20, cluster: nextCluster, size: file.data.count)
            nextCluster += clusters
        }
        guard root.count <= rootEntries * 32 else { throw Failure("seed_too_large", "Too many seed files.") }
        put(fat, at: reservedSectors * sectorSize)
        put(fat, at: (reservedSectors + fatSectors) * sectorSize)
        put(root, at: (reservedSectors + fatCount * fatSectors) * sectorSize)
        return image
    }
    static func pad(_ s: String, _ width: Int) -> [UInt8] {
        let bytes = Array(s.utf8.prefix(width)); return bytes + Array(repeating: 0x20, count: width - bytes.count)
    }
    /// Unique, deliberately simple 8.3 alias: the first six usable characters plus `~n`.
    static func shortName(_ name: String, index: Int) -> [UInt8] {
        let usable = name.uppercased().utf8.filter { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F || $0 == 0x2D }
        let tail = Array("~\(index)".utf8)
        let base = Array(usable.prefix(8 - tail.count)) + tail
        return base + Array(repeating: 0x20, count: 11 - base.count)
    }
    static func checksum(_ shortName: [UInt8]) -> UInt8 {
        shortName.reduce(0 as UInt8) { sum, byte in ((sum & 1) << 7) &+ (sum >> 1) &+ byte }
    }
    static func directoryEntry(shortName: [UInt8], attributes: UInt8, cluster: Int, size: Int) -> [UInt8] {
        var e = [UInt8](repeating: 0, count: 32)
        e.replaceSubrange(0..<11, with: shortName); e[11] = attributes
        let date: [UInt8] = [0x21, 0x5C] // 2026-01-01; the seed carries no meaningful timestamps.
        e.replaceSubrange(16..<18, with: date); e.replaceSubrange(18..<20, with: date); e.replaceSubrange(24..<26, with: date)
        e[26] = UInt8(cluster & 0xff); e[27] = UInt8(cluster >> 8 & 0xff)
        e[28] = UInt8(size & 0xff); e[29] = UInt8(size >> 8 & 0xff); e[30] = UInt8(size >> 16 & 0xff); e[31] = UInt8(size >> 24 & 0xff)
        return e
    }
    static func longNameEntries(_ name: String, checksum: UInt8) -> [UInt8] {
        var units = Array(name.utf16)
        let count = (units.count + 12) / 13
        units.append(0); while units.count < count * 13 { units.append(0xFFFF) }
        let positions = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
        var out = [UInt8]()
        for sequence in stride(from: count, through: 1, by: -1) {
            var e = [UInt8](repeating: 0, count: 32)
            e[0] = UInt8(sequence) | (sequence == count ? 0x40 : 0)
            for (i, position) in positions.enumerated() {
                let unit = units[(sequence - 1) * 13 + i]
                e[position] = UInt8(unit & 0xff); e[position + 1] = UInt8(unit >> 8)
            }
            e[11] = 0x0F; e[13] = checksum
            out += e
        }
        return out
    }
}
