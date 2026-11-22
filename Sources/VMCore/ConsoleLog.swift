import Foundation
import Darwin

/// Guest console output (virtio console, `hvc0`) kept on the host in `logs/console.log`.
///
/// The guest decides how much it writes, so the host caps it: once the file would pass `limit`,
/// a new file starts. The first full file of a run becomes `console.start.log`, so a flood of
/// output cannot rotate away how the run began (often the first error). Later ones become
/// `console.log.1`. At most about three times `limit` is kept per VM. Output lands here even when
/// the guest's own disk has failed.
public final class ConsoleLog {
    public static let defaultLimit: off_t = 8 << 20
    public let url: URL
    let limit: off_t
    var fd: Int32 = -1
    var size: off_t = 0
    var rotations = 0

    public static func url(in vmDirectory: URL) -> URL {
        vmDirectory.appendingPathComponent("logs").appendingPathComponent("console.log")
    }
    public static func previous(_ url: URL) -> URL { URL(fileURLWithPath: url.path + ".1") }
    public static func start(_ url: URL) -> URL { url.deletingLastPathComponent().appendingPathComponent("console.start.log") }

    public init(url: URL, limit: off_t = ConsoleLog.defaultLimit) throws {
        self.url = url; self.limit = limit
        try open()
    }
    deinit { if fd >= 0 { close(fd) } }

    func open() throws {
        var info = stat()
        if lstat(url.path, &info) == 0 { try Store.check(url) }
        fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw systemFailure("open \(url.lastPathComponent)") }
        guard fstat(fd, &info) == 0 else { throw systemFailure("stat \(url.lastPathComponent)") }
        size = info.st_size
    }

    /// Appends guest output. Errors are dropped: a full host disk must not stop the guest.
    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        if size > 0, size + off_t(data.count) > limit { rotate() }
        guard fd >= 0 else { return }
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 { if errno == EINTR { continue }; return }
                offset += written; size += off_t(written)
            }
        }
    }

    func rotate() {
        if fd >= 0 { close(fd); fd = -1 }
        _ = rename(url.path, (rotations == 0 ? Self.start(url) : Self.previous(url)).path)
        rotations += 1
        try? open()
    }

    /// Guest output made safe for a terminal. Colour codes (SGR) are dropped; carriage returns are
    /// dropped; every other control character is shown as ^X, so the guest cannot move the cursor,
    /// retitle the window or send any other escape sequence to the terminal that reads the log.
    public static func printable(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;:]*m", with: "", options: .regularExpression)
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x09: out.append(scalar)
            case 0x0D: continue
            case 0x00..<0x20: out.append("^"); out.append(Unicode.Scalar(scalar.value + 0x40)!)
            case 0x7F: out.append(contentsOf: "^?".unicodeScalars)
            case 0x80..<0xA0: out.append(contentsOf: String(format: "\\u%04X", scalar.value).unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }
}
