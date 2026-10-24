import Foundation
import Darwin
import VMCore

func usage() {
    print("""
    Usage: vmctl <create|start|stop|status|ip|logs|console> [name]
           vmctl list
           vmctl rm <name>
           vmctl create [name] --restore /path/to/Apple.ipsw
           vmctl create [name] --linux [--image /path/to/raw-disk.img] [--disk <size>]
           vmctl start [name] [--iso /path/to/installer.iso]
           vmctl start [name] --user <username> [--full-name <name>] [--ssh-key <key-or-file>]
           vmctl stop [name] --force
    create --restore installs a local Apple restore image; it may take a long time.
    create --linux prepares an EFI Linux VM with a blank sparse disk, or a copy of a raw image.
    --disk sets the Linux disk size: 40G, 512M, 1T (bare numbers are GiB). Default 20 GiB, sparse.
    start --iso attaches an installer ISO (Linux only) for this boot; install it from console.
    --user creates a user and enables SSH on first boot only (macOS 27+ host/guest, or Linux cloud-init).
    --ssh-key (Linux only) installs an OpenSSH public key; the account is then key-only with passwordless sudo.
    Without --ssh-key the password is prompted securely on the terminal, never accepted as an argument.
    Default name: mac. stop waits up to 30 seconds for guest shutdown before forcing power-off.
    stop --force powers off immediately; unsaved guest data may be lost.
    logs prints the last ~24 KB of supervisor events. Errors are JSON on stderr.
    console opens a local window for a running VM; closing it keeps the VM running.
    rm deletes a stopped VM's directory (disk, identity, logs); it cannot be undone.
    """)
}
func daemonConnection(_ store: Store) throws -> Int32 {
    do { return try Wire.connect(store.socketPath) }
    catch {
        guard let error = error as? Failure, ["posix.2", "posix.61"].contains(error.code) else { throw error }
    }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    // Resolve argv[0] through the actual executable path, including PATH invocation.
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var bytes = [CChar](repeating: 0, count: Int(size))
    let actual = _NSGetExecutablePath(&bytes, &size) == 0 ? URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath() : executable
    let bin = actual.deletingLastPathComponent()
    let daemon = bin.appendingPathComponent("vmctld")
    guard FileManager.default.isExecutableFile(atPath: daemon.path) else { throw Failure("daemon_missing", "Place signed vmctld beside vmctl.") }
    let logURL = store.root.appendingPathComponent("daemon.log")
    let logFD = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard logFD >= 0 else { throw systemFailure("open daemon log") }
    do { try Store.check(logURL) } catch { close(logFD); throw error }
    let log = FileHandle(fileDescriptor: logFD, closeOnDealloc: true)
    let child = Process()
    child.currentDirectoryURL = store.root
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = log; child.standardError = log
    child.executableURL = daemon
    try child.run()
    // Concurrent callers may launch competing daemons; only the flock winner binds.
    for _ in 0..<100 {
        do { return try Wire.connect(store.socketPath) }
        catch {
            guard let error = error as? Failure, ["posix.2", "posix.61"].contains(error.code) else { throw error }
        }
        usleep(50_000)
    }
    throw Failure("daemon_unavailable", "Daemon did not become ready within 5 seconds. See \(logURL.path).")
}
func readPassword(_ prompt: String) throws -> String {
    var buffer = [CChar](repeating: 0, count: 1024)
    defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress!, $0.count, 0, $0.count) } }
    guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
        throw Failure("password_prompt", "Password entry requires an interactive terminal.")
    }
    return String(cString: buffer)
}
/// Accepts a literal OpenSSH public key line or the path of a `.pub` file (first key line is used).
func readPublicKey(_ value: String) throws -> String {
    let literal = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if Provisioning.publicKeyTypes.contains(where: { literal.hasPrefix($0 + " ") }) {
        try Provisioning.validatePublicKey(literal); return literal
    }
    let url = URL(fileURLWithPath: value).standardizedFileURL
    var info = stat()
    guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 16384 else {
        throw Failure("invalid_ssh_key", "Pass an OpenSSH public key line or the path of a small .pub file.")
    }
    let lines = String(decoding: try Data(contentsOf: url), as: UTF8.self).split(whereSeparator: \.isNewline)
    guard let line = lines.map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else {
        throw Failure("invalid_ssh_key", "No public key line found in \(url.path).")
    }
    try Provisioning.validatePublicKey(line)
    return line
}
func absolute(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
/// Binary units: 20G, 20GiB, 512M, 1T; a bare number is GiB. The daemon enforces the allowed range.
func parseSize(_ text: String) throws -> UInt64 {
    let lowered = text.lowercased()
    let units: [(String, UInt64)] = [("tib", 1 << 40), ("tb", 1 << 40), ("t", 1 << 40), ("gib", 1 << 30), ("gb", 1 << 30), ("g", 1 << 30),
                                     ("mib", 1 << 20), ("mb", 1 << 20), ("m", 1 << 20)]
    var digits = Substring(lowered), unit: UInt64 = 1 << 30
    if let match = units.first(where: { lowered.hasSuffix($0.0) }) { digits = lowered.dropLast(match.0.count); unit = match.1 }
    guard let count = UInt64(digits), count > 0, count <= UInt64.max / unit else {
        throw Failure("usage", "--disk takes a size such as 20G, 512M or 1T; a bare number means GiB.")
    }
    return count * unit
}
umask(0o077)

signal(SIGPIPE, SIG_IGN)
do {
    var args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args == ["--help"] || args == ["-h"] { usage(); exit(0) }
    let command = args.removeFirst()
    guard ["create", "start", "stop", "status", "ip", "logs", "list", "console", "rm"].contains(command) else { throw Failure("usage", "Unknown command. Run vmctl --help.") }
    if command == "list", !args.isEmpty { throw Failure("usage", "Usage: vmctl list (no arguments).") }
    var name = "mac"
    if let first = args.first, !first.hasPrefix("--") { name = args.removeFirst() }
    else if command == "rm" { throw Failure("usage", "Usage: vmctl rm <name>. The name is never defaulted for removal.") }
    try validateName(name)
    var restore: String?, kind: String?, image: String?, installer: String?, diskSize: UInt64?
    var provisioning: Provisioning?
    var forceStop = false
    switch command {
    case "create":
        let createUsage = Failure("usage", "Use vmctl create [name] --restore /path/to/Apple.ipsw, or create [name] --linux [--image /path/to/raw.img] [--disk <size>].")
        if args.count == 2, args[0] == "--restore" { restore = absolute(args[1]) }
        else if args.first == "--linux" {
            kind = "linux"; args.removeFirst()
            while !args.isEmpty {
                let flag = args.removeFirst()
                guard !args.isEmpty else { throw createUsage }
                let value = args.removeFirst()
                switch flag {
                case "--image" where image == nil: image = absolute(value)
                case "--disk" where diskSize == nil: diskSize = try parseSize(value)
                default: throw createUsage
                }
            }
        } else { throw createUsage }
    case "stop":
        if args == ["--force"] { forceStop = true } else if !args.isEmpty { throw Failure("usage", "Use vmctl stop [name] [--force].") }
    case "start":
        var username: String?, fullName: String?, sshKey: String?
        while !args.isEmpty {
            let flag = args.removeFirst()
            guard !args.isEmpty else { throw Failure("usage", "Missing value for \(flag).") }
            let value = args.removeFirst()
            switch flag {
            case "--user" where username == nil: username = value
            case "--full-name" where fullName == nil: fullName = value
            case "--ssh-key" where sshKey == nil: sshKey = try readPublicKey(value)
            case "--iso" where installer == nil: installer = absolute(value)
            default: throw Failure("usage", "Use start [name] [--iso <path>] [--user <username> [--full-name <name>] [--ssh-key <key>]]. Passwords must be entered at the prompt.")
            }
        }
        if let username {
            // Validate the account before prompting so a bad name fails fast. Key-only accounts take no password.
            try Provisioning(username: username, fullName: fullName ?? username, password: sshKey == nil ? "validation-placeholder" : nil, sshPublicKey: sshKey).validate()
            var password: String?
            if sshKey == nil {
                password = try readPassword("New guest password: ")
                guard password == (try readPassword("Confirm guest password: ")) else { throw Failure("password_mismatch", "Passwords did not match.") }
            }
            provisioning = Provisioning(username: username, fullName: fullName ?? username, password: password, sshPublicKey: sshKey)
            try provisioning!.validate()
        } else if fullName != nil || sshKey != nil { throw Failure("usage", "--full-name and --ssh-key require --user.") }
    default:
        if !args.isEmpty { throw Failure("usage", "Unexpected arguments.") }
    }

    let store = try Store()
    let fd = try daemonConnection(store); defer { close(fd) }
    Wire.timeout(fd, seconds: command == "create" ? 86400 : 120)
    try Wire.send(Request(command: forceStop ? "force-stop" : (provisioning == nil ? command : "provision"), name: name,
                          restore: restore, provisioning: provisioning, kind: kind, image: image, installer: installer, diskSize: diskSize), to: fd)
    let response = try Wire.receive(Reply.self, from: fd)
    let upgrade = Failure("daemon_upgrade_required", "The running daemon is an older version. Stop your active VM, quit vmctld in Activity Monitor, then retry with the updated daemon.")
    if let error = response.error {
        let newer = provisioning != nil || forceStop || ["list", "console", "rm"].contains(command) || kind != nil || installer != nil
        if newer, error.code == "invalid_command" || (kind != nil && error.code == "restore_required") { throw upgrade }
        throw error
    }
    if let diskSize, response.value == "created" {
        // A daemon without --disk support ignores the field and silently builds the default size.
        var info = stat()
        if stat(try store.vm(name).appendingPathComponent("disk.img").path, &info) == 0, info.st_size != off_t(diskSize) {
            throw Failure(upgrade.code, "VM \(name) was created with the old daemon's default disk size. \(upgrade.message) Remove ~/.vmctl/vms/\(name) first.")
        }
    }

    if let value = response.value, !value.isEmpty { print(value) }
} catch {
    let reply = Reply(error: Failure.wrapping(error))
    if let data = try? JSONEncoder().encode(reply) { FileHandle.standardError.write(data); FileHandle.standardError.write(Data([10])) }
    exit(1)
}
