import Foundation
import Darwin

/// `~/.vmctl/ssh_config`: one `Host <vm>.vm` block per VM, so plain `ssh` and `git` reach a VM by name.
/// vmctl owns this file and the per-VM known_hosts files beside it. It never reads or writes anything
/// in `~/.ssh`; the user includes this file from `~/.ssh/config` themselves.
public enum SSHConfig {
    public static func host(_ name: String) -> String { name + ".vm" }
    static func begin(_ name: String) -> String { "# BEGIN vmctl \(name)" }
    static func end(_ name: String) -> String { "# END vmctl \(name)" }
    static let beginPrefix = "# BEGIN vmctl "
    public static let header = """
    # Managed by vmctl. Each VM's block is replaced or removed by vmctl; edits inside a block are lost.
    # Include it at the top of ~/.ssh/config, before any Host block:
    #     Include ~/.vmctl/ssh_config
    """
    public static let includeLine = "Include ~/.vmctl/ssh_config"

    public struct Entry: Equatable {
        public let name: String, user: String, identityFile: String?, knownHostsFile: String, proxyCommand: String
        public init(name: String, user: String, identityFile: String?, knownHostsFile: String, proxyCommand: String) {
            self.name = name; self.user = user; self.identityFile = identityFile
            self.knownHostsFile = knownHostsFile; self.proxyCommand = proxyCommand
        }
    }

    /// `sh -c 'nc "$(vmctl ip <vm>)" 22'`, with vmctl's absolute path so ssh started without the
    /// user's PATH (an IDE's git) still finds it, and VMCTL_HOME when the store is not the default.
    public static func proxyCommand(name: String, vmctl: String, home: String?) throws -> String {
        try validateName(name)
        for value in [vmctl] + (home.map { [$0] } ?? []) where !shellSafe(value) {
            throw Failure("unsafe_path", "Cannot write an ssh ProxyCommand for \(value): quotes, $, `, \\, % and control characters are refused.")
        }
        let env = home.map { "VMCTL_HOME=\"\($0)\" " } ?? ""
        return "sh -c 'nc \"$(\(env)\"\(vmctl)\" ip \(name))\" 22'"
    }
    static func shellSafe(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains { "'\"$`\\%".unicodeScalars.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }
    /// ssh_config argument: double-quoted, with `%` doubled because ssh expands %-tokens in file paths.
    static func argument(_ value: String) throws -> String {
        guard !value.isEmpty, !value.contains("\""),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure("unsafe_path", "Cannot write \(value) into ssh_config: quotes and control characters are refused.")
        }
        return "\"" + value.replacingOccurrences(of: "%", with: "%%") + "\""
    }

    public static func block(_ entry: Entry) throws -> String {
        try validateName(entry.name)
        guard entry.user.range(of: "^[a-z_][a-z0-9_-]{0,31}\\z", options: .regularExpression) != nil else {
            throw Failure("invalid_user", "Guest user names are lowercase letters, digits, - and _.")
        }
        guard !entry.proxyCommand.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure("unsafe_path", "ProxyCommand contains control characters.")
        }
        var lines = [begin(entry.name),
                     "Host \(host(entry.name))",
                     "  User \(entry.user)",
                     "  ProxyCommand \(entry.proxyCommand)",
                     "  UserKnownHostsFile \(try argument(entry.knownHostsFile))",
                     "  StrictHostKeyChecking yes",
                     "  ForwardAgent no",
                     "  IdentitiesOnly yes"]
        if let identity = entry.identityFile { lines.append("  IdentityFile \(try argument(identity))") }
        lines.append(end(entry.name))
        return lines.joined(separator: "\n")
    }

    /// Replaces `name`'s block in place (or appends it), or removes it when `block` is nil. Text outside
    /// vmctl's markers, including other VMs' blocks, is kept byte for byte. A block whose END marker is
    /// missing ends at the next BEGIN marker or the end of the file.
    public static func updating(_ text: String, name: String, block: String?) -> String {
        var output: [String] = [], skipping = false, placed = false
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for line in lines {
            if line == begin(name) {
                skipping = true
                if !placed, let block { output.append(block) }
                placed = true
                continue
            }
            if skipping {
                if line == end(name) { skipping = false; continue }
                if line.hasPrefix(beginPrefix) { skipping = false } else { continue }
            }
            output.append(line)
        }
        if !placed, let block {
            if output.isEmpty { output.append(header) }
            if output.last.map({ !$0.isEmpty }) == true { output.append("") }
            output.append(block)
        }
        return output.isEmpty ? "" : output.joined(separator: "\n") + "\n"
    }

    /// A known_hosts line pinning `name`.vm to one host public key (its comment dropped).
    public static func knownHostsLine(name: String, hostKey: String) throws -> String {
        try validateName(name)
        let key = hostKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try Provisioning.validatePublicKey(key)
        let parts = key.split(separator: " ")
        return "\(host(name)) \(parts[0]) \(parts[1])\n"
    }
}

extension Store {
    public var sshConfig: URL { root.appendingPathComponent("ssh_config") }
    public var knownHostsDirectory: URL { root.appendingPathComponent("known_hosts") }
    public func knownHosts(_ name: String) throws -> URL {
        try validateName(name); return knownHostsDirectory.appendingPathComponent(name)
    }
    /// Rewrites one VM's block in `ssh_config` (nil removes it). Returns true if the file was created.
    @discardableResult
    public func updateSSHConfig(name: String, block: String?) throws -> Bool {
        var info = stat()
        let exists = lstat(sshConfig.path, &info) == 0 // a symlink counts, so Store.read refuses it
        if !exists && block == nil { return false }
        let text = exists ? String(decoding: try Store.read(sshConfig), as: UTF8.self) : ""
        let updated = SSHConfig.updating(text, name: name, block: block)
        if updated != text || !exists { try Store.write(Data(updated.utf8), to: sshConfig) }
        return !exists
    }
    public func writeKnownHosts(name: String, hostKey: String) throws {
        try Store.directory(knownHostsDirectory)
        try Store.write(Data(try SSHConfig.knownHostsLine(name: name, hostKey: hostKey).utf8), to: try knownHosts(name))
    }
    public func removeKnownHosts(name: String) throws {
        let url = try knownHosts(name)
        if unlink(url.path) != 0 && errno != ENOENT { throw systemFailure("unlink known_hosts") }
    }
}
