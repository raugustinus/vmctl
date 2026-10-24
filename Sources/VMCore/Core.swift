import Foundation
import Darwin

public struct Failure: Error, Codable, CustomStringConvertible {
    public let code: String
    public let message: String
    public var description: String { "\(code): \(message)" }
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public static func wrapping(_ error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        let e = error as NSError
        return Failure("\(e.domain).\(e.code)", e.localizedDescription)
    }
}
public struct Provisioning: Codable {
    public let username: String
    public let fullName: String
    /// Required for macOS guests. Optional for Linux guests, which may be key-only.
    public let password: String?
    /// Linux guests only: one OpenSSH public key line installed through cloud-init.
    public let sshPublicKey: String?
    public init(username: String, fullName: String, password: String?, sshPublicKey: String? = nil) {
        self.username = username; self.fullName = fullName; self.password = password; self.sshPublicKey = sshPublicKey
    }
    public static let publicKeyTypes: Set<String> = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
                                                     "ssh-rsa", "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com"]
    public func validate() throws {
        guard username.range(of: "^[a-z][a-z0-9_]{0,30}\\z", options: .regularExpression) != nil,
              !["root", "daemon", "nobody"].contains(username),
              !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fullName.utf8.count <= 128, !fullName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure("invalid_provisioning", "Use a lowercase account name (letters, digits, underscores) and a full name up to 128 bytes without control characters.")
        }
        guard password != nil || sshPublicKey != nil else { throw Failure("invalid_provisioning", "Provide a password or an SSH public key.") }
        if let password {
            guard !password.isEmpty, password.utf8.count <= 256,
                  !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw Failure("invalid_provisioning", "Use a nonempty password up to 256 bytes without control characters.")
            }
        }
        if let sshPublicKey { try Self.validatePublicKey(sshPublicKey) }
    }
    /// Accepts one `type base64 [comment]` line whose wire blob names the same key type.
    public static func validatePublicKey(_ line: String) throws {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        let invalid = Failure("invalid_ssh_key", "Expected one OpenSSH public key line: <type> <base64> [comment].")
        guard (2...3).contains(parts.count), line.utf8.count <= 8192,
              !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              publicKeyTypes.contains(String(parts[0])),
              let blob = Data(base64Encoded: String(parts[1])), blob.count > 4 else { throw invalid }
        let length = blob.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= 64, blob.count >= 4 + length,
              String(decoding: blob.subdata(in: 4..<4 + length), as: UTF8.self) == parts[0] else { throw invalid }
    }
}
public struct Request: Codable {
    public let command: String
    public let name: String
    public let provisioning: Provisioning?
    public let restore: String?
    /// create: "linux" for an EFI generic-platform VM; nil means a macOS restore image.
    public let kind: String?
    /// create --linux: absolute path of a raw disk image copied into the new VM's disk.
    public let image: String?
    /// start: absolute path of an installer ISO attached read-only for this boot only.
    public let installer: String?
    /// create --linux: disk size in bytes; nil means the daemon default (64 GiB).
    public let diskSize: UInt64?
    public init(command: String, name: String, restore: String? = nil, provisioning: Provisioning? = nil,
                kind: String? = nil, image: String? = nil, installer: String? = nil, diskSize: UInt64? = nil) {
        self.command = command; self.name = name; self.restore = restore; self.provisioning = provisioning
        self.kind = kind; self.image = image; self.installer = installer; self.diskSize = diskSize
    }
}
public struct Reply: Codable {
    public var value: String?
    public var error: Failure?
    public init(value: String? = nil, error: Failure? = nil) { self.value = value; self.error = error }
}
public struct Configuration: Codable {
    public var version = 1
    public let name: String
    public let cpuCount: Int
    public let memorySize: UInt64
    public let macAddress: String
    public var guestMajorVersion: Int?
    public var firstBootAvailable: Bool?
    public var installed: Bool
    /// "linux" for EFI generic-platform guests. Absent in configurations written before Linux support: macOS.
    public var kind: String?
    public var isLinux: Bool { kind == "linux" }
    public init(name: String, cpuCount: Int, memorySize: UInt64, macAddress: String, installed: Bool) {
        self.name = name; self.cpuCount = cpuCount; self.memorySize = memorySize
        self.macAddress = macAddress; self.installed = installed
    }
}
public func validateProvisioningEligibility(_ config: Configuration) throws {
    guard config.installed, config.version == 1 else {
        throw Failure("unsupported_guest", "Provisioning requires a VM fully created by this version of vmctl.")
    }
    if !config.isLinux {
        guard let major = config.guestMajorVersion, major >= 27 else {
            throw Failure("unsupported_guest", "Provisioning requires a macOS 27+ VM freshly installed by this version of vmctl.")
        }
    }
    guard config.firstBootAvailable == true else {
        throw Failure("first_boot_required", "User provisioning is only available before the first boot. Create a fresh VM with a different name.")
    }
}
public func validateName
(_ name: String) throws {
    guard name.range(of: "^[a-z][a-z0-9-]{0,31}\\z", options: .regularExpression) != nil else {
        throw Failure("invalid_name", "Use 1–32 lowercase letters, digits or hyphens, beginning with a letter.")
    }
}
public func systemFailure(_ operation: String) -> Failure {
    Failure("posix.\(errno)", "\(operation): \(String(cString: strerror(errno)))")
}
public struct Store {
    public let root: URL
    public var socketPath: String { root.appendingPathComponent("control.sock").path }
    public init(root: URL? = nil) throws {
        let override = ProcessInfo.processInfo.environment["VMCTL_HOME"]
        if let override, !override.hasPrefix("/") { throw Failure("invalid_path", "VMCTL_HOME must be absolute.") }
        self.root = root ?? override.map { URL(fileURLWithPath: $0).standardizedFileURL } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vmctl")
        try Self.directory(self.root)
        try Self.directory(self.root.appendingPathComponent("vms"))
    }
    public static func directory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw systemFailure("mkdir") }
        try check(url, directory: true)
    }
    public static func check(_ url: URL, directory: Bool = false) throws {
        var s = stat()
        guard lstat(url.path, &s) == 0 else { throw systemFailure("stat \(url.lastPathComponent)") }
        guard s.st_uid == getuid(), s.st_mode & 0o077 == 0,
              s.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), directory || s.st_nlink == 1 else {
            throw Failure("unsafe_path", "Expected a private, user-owned \(directory ? "directory" : "regular file") at \(url.path); symlinks and hard-linked files are rejected.")
        }
    }
    public func vm(_ name: String) throws -> URL {
        try validateName(name)
        return root.appendingPathComponent("vms").appendingPathComponent(name)
    }
    public func existing(_ name: String) throws -> URL {
        let url = try vm(name); try Self.check(url, directory: true); return url
    }
    public static func write(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try check(url) }
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw systemFailure("chmod") }
    }
    public static func read(_ url: URL) throws -> Data { try check(url); return try Data(contentsOf: url) }
}

// One newline-delimited JSON request/reply per connection, with bounded input.
public enum Wire {
    public static func socket() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemFailure("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }
    public static func address<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: a.sun_path) else { throw Failure("path_too_long", "Unix socket path exceeds system limit.") }
        a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: bytes) }
        return try withUnsafePointer(to: &a) { p in
            try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    public static func authenticate(_ fd: Int32) throws {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw Failure("unauthorized", "Socket peer is not the current user.") }
    }
    public static func connect(_ path: String) throws -> Int32 {
        let fd = try socket()
        do {
            try address(path) { a, n in guard Darwin.connect(fd, a, n) == 0 else { throw systemFailure("connect") } }
            try authenticate(fd); return fd
        } catch { close(fd); throw error }
    }
    public static func receive<T: Decodable>(_ type: T.Type, from fd: Int32, limit: Int = 65536) throws -> T {
        var data = Data(); var byte: UInt8 = 0
        while data.count < limit {
            let n = Darwin.read(fd, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            guard n == 1 else { throw Failure("connection_closed", "Incomplete response or socket timeout.") }
            if byte == 10 { return try JSONDecoder().decode(type, from: data) }
            data.append(byte)
        }
        throw Failure("message_too_large", "Message exceeds \(limit) bytes.")
    }
    public static func send<T: Encodable>(_ value: T, to fd: Int32) throws {
        var data = try JSONEncoder().encode(value); data.append(10)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw systemFailure("write socket") }; offset += n
            }
        }
    }
    public static func timeout(_ fd: Int32, seconds: Int) {
        var t = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout.size(ofValue: t)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, socklen_t(MemoryLayout.size(ofValue: t)))
    }
}
