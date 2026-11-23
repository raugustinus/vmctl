import Foundation
import Darwin
import VMCore

func usage() {
    print("""
    Usage: vmctl <create|start|stop|status|ip|logs|console> [name]
           vmctl list
           vmctl rm <name>
           vmctl create [name] --restore /path/to/Apple.ipsw
           vmctl create [name] --linux [--image /path/to/raw-disk.img] [--disk <size>] [--cpus <n>] [--memory <size>]
                                [--kernel /path/to/Image [--initrd /path/to/initrd] [--cmdline "<args>"]]
                                [--share /path/to/project[:ro]]
           vmctl start [name] [--iso /path/to/installer.iso]
           vmctl start [name] --user <username> [--full-name <name>] [--ssh-key <key-or-file>] [--dns <ip>]
           vmctl logs [name] [--console [--follow]]
           vmctl stop [name] --force
           vmctl ssh-config [name] [--user <user>] [--host-key <key-or-file>] [--identity <private-key>]
           vmctl mount <name> [<guest-directory> [<mount-point>]]
           vmctl umount <name> [<mount-point>] [--force]
           vmctl help [ssh-config]
    create --restore installs a local Apple restore image; it may take a long time.
    create --linux prepares an EFI Linux VM with a blank sparse disk, or a copy of a raw image.
    --disk sets the Linux disk size: 40G, 512M, 1T (bare numbers are GiB). Default 20 GiB, sparse.
    --cpus and --memory size a Linux VM, e.g. --cpus 1 --memory 512M (bare numbers are GiB). Default 4 CPUs, 8 GiB.
    --kernel boots an uncompressed arm64 Image directly: no EFI, display or console window.
    Default --cmdline: "\(KernelBoot.defaultCommandLine)".
    --share attaches a host directory over virtiofs at every boot (:ro for read-only). With start --user it is
    mounted at ~<user>/<directory name> in the guest; the guest can change everything in it, nothing outside.
    start --iso attaches an installer ISO (Linux only) for this boot; install it from console.
    --user creates a user and enables SSH on first boot only (macOS 27+ host/guest, or Linux cloud-init).
    --ssh-key (Linux only) installs an OpenSSH public key; the account is then key-only with passwordless sudo.
    A Linux VM started with --user becomes <name>.vm in ~/.vmctl/ssh_config, with a pinned host key;
    see vmctl help ssh-config.
    mount puts a directory of a running Linux guest on this Mac, read-write, over NFS: the reverse of
    --share. The files stay on the guest's disk and the guest sees nothing of the Mac. Default mount point:
    ~/vm/<name>/<directory name>. The guest (started with --user) is set up over SSH the first time: an NFS
    export of that directory to this Mac's address only, with files written from here owned by that account.
    mount <name> alone lists that VM's mounts. They are unmounted by stop and rm and mounted again by start.
    umount unmounts one or all and forgets them; --force also when files are still open.
    --dns (Linux only, with --user) makes the guest use that DNS server instead of the NAT gateway's.
    vmd answers <name>.vm with a running VM's address on 127.0.0.1:\(NameService.port) (UDP); point a resolver's
    vm zone at it, e.g. dnsmasq: server=/vm/127.0.0.1#\(NameService.port). See the README.
    Without --ssh-key the password is prompted securely on the terminal, never accepted as an argument.
    Default name: mac. stop waits up to 30 seconds for guest shutdown before forcing power-off.
    stop --force powers off immediately; unsaved guest data may be lost.
    logs prints the last ~24 KB of supervisor events. Errors are JSON on stderr.
    logs --console prints the last ~24 KB of a Linux guest's virtio console (hvc0): for VMs provisioned
    with --user, kernel messages and journal warnings and errors. It keeps working when the guest's disk
    does not. --follow keeps printing new output. Control characters are shown as ^X. Kept in
    ~/.vmctl/vms/<name>/logs/: console.log, console.log.1, and console.start.log, the start of the run.
    console opens a local window for a running VM; closing it keeps the VM running.
    rm deletes a stopped VM's directory (disk, identity, logs); it cannot be undone.
    """)
}
/// Prints the last ~24 KB of a Linux VM's console log, then with `follow` keeps printing what the
/// guest writes, across rotations. Read directly from the store; the daemon is not involved.
func showConsoleLog(_ vmDirectory: URL, follow: Bool) throws -> Never {
    let url = ConsoleLog.url(in: vmDirectory)
    let tail: off_t = 24_000
    var fd: Int32 = -1, inode: ino_t = 0, offset: off_t = 0
    func reopen(fromEnd: Bool) -> Bool {
        if fd >= 0 { close(fd); fd = -1 }
        var info = stat()
        guard lstat(url.path, &info) == 0, (try? Store.check(url)) != nil else { return false }
        fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0, fstat(fd, &info) == 0 else { return false }
        inode = info.st_ino
        offset = fromEnd && info.st_size > tail ? info.st_size - tail : 0
        return true
    }
    func drain(skipPartialLine: Bool) {
        var buffer = [UInt8](repeating: 0, count: 65536), data = Data()
        while true {
            let count = pread(fd, &buffer, buffer.count, offset)
            if count <= 0 { break }
            data.append(buffer, count: count); offset += off_t(count)
        }
        if skipPartialLine, let newline = data.firstIndex(of: 0x0A) { data = data[(newline + 1)...] }
        if !data.isEmpty { FileHandle.standardOutput.write(Data(ConsoleLog.printable(data).utf8)) }
    }
    func followLoop() -> Never {
        while true {
            drain(skipPartialLine: false)
            var info = stat()
            // Rotated: the old file is finished above; continue at the start of the new one.
            if lstat(url.path, &info) == 0, info.st_ino != inode, reopen(fromEnd: false) { continue }
            usleep(250_000)
        }
    }
    guard reopen(fromEnd: true) else {
        var info = stat()
        if lstat(url.path, &info) == 0 { try Store.check(url) } // reports why it was refused
        if !follow { throw Failure("not_found", "No console log yet. It is written while a Linux VM runs.") }
        while !reopen(fromEnd: false) { usleep(500_000) }
        followLoop()
    }
    drain(skipPartialLine: offset > 0)
    if follow { followLoop() }
    exit(0)
}
func alignColumns(_ text: String) -> String {
    let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    var widths: [Int] = []
    for row in rows { for (i, cell) in row.enumerated() { if i >= widths.count { widths.append(0) }; widths[i] = max(widths[i], cell.count) } }
    return rows.map { row in
        row.enumerated().map { i, cell in i == row.count - 1 ? cell : cell.padding(toLength: widths[i] + 2, withPad: " ", startingAt: 0) }.joined()
    }.joined(separator: "\n")
}
func sshConfigHelp() {
    print("""
    vmctl ssh-config: reach VMs by name with plain ssh and git.

    vmctl keeps one block per VM in ~/.vmctl/ssh_config, written when a Linux VM is first started
    with --user, removed by vmctl rm:

        Host <vm>.vm
          User <the --user account>
          ProxyCommand sh -c 'nc "$(vmctl ip <vm>)" 22'
          UserKnownHostsFile ~/.vmctl/known_hosts/<vm>
          StrictHostKeyChecking yes
          ForwardAgent no
          IdentitiesOnly yes
          IdentityFile <the private key beside the --ssh-key .pub file>

    The guest's host key is generated on this Mac at provisioning and installed by cloud-init, so
    known_hosts is pinned before the first connection; nothing is trusted on first use.

    vmctl never reads or edits ~/.ssh/config. Add this line yourself, at the TOP of ~/.ssh/config,
    before any Host block (ssh uses the first value it finds for each option, so an earlier
    `Host *` block would override vmctl's settings):

        \(SSHConfig.includeLine)

    Then, for example:

        ssh <vm>.vm
        git remote add vm <vm>.vm:proj && git push vm main

    vmctl ssh-config [<vm>]
        Rewrites the block for one VM (or for every VM, without a name) and prints it.
    vmctl ssh-config <vm> --user <user> --host-key <key-or-file> [--identity <private-key-path>]
        For VMs provisioned before this feature, or macOS guests: vmctl did not generate their host
        key, so supply it. Fetch it over a connection you already trust, for example:
            ssh dev@"$(vmctl ip <vm>)" cat /etc/ssh/ssh_host_ed25519_key.pub > /tmp/<vm>.hostkey
            vmctl ssh-config <vm> --user dev --host-key /tmp/<vm>.hostkey --identity ~/.ssh/id_ed25519
    """)
}
/// Whether ~/.ssh/config already includes vmctl's file for this VM, judged from `ssh -G`, so ssh
/// resolves its own configuration and vmctl never opens ~/.ssh/config.
func sshReachability(_ name: String, store: Store) -> String {
    let host = SSHConfig.host(name)
    let notice = """
    \(host) is not reachable by name yet. Add this line at the top of ~/.ssh/config, before any Host blocks:
        \(SSHConfig.includeLine)
    See `vmctl help ssh-config`.
    """
    let ssh = Process(), pipe = Pipe()
    ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    ssh.arguments = ["-G", host]
    ssh.standardInput = FileHandle.nullDevice; ssh.standardOutput = pipe; ssh.standardError = FileHandle.nullDevice
    guard (try? ssh.run()) != nil else { return notice }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    ssh.waitUntilExit()
    var options: [String: String] = [:]
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1)
        if parts.count == 2, options[String(parts[0])] == nil { options[String(parts[0])] = String(parts[1]) }
    }
    guard let knownHosts = try? store.knownHosts(name).path,
          options["proxycommand"]?.contains(" ip \(name))") == true,
          options["userknownhostsfile"]?.contains(knownHosts) == true else { return notice }
    var result = "Reachable as \(host) — e.g. git remote add vm \(host):proj"
    if options["forwardagent"] == "yes" {
        result += "\nWarning: ssh resolves ForwardAgent yes for \(host), so an earlier block in ~/.ssh/config (such as Host *) overrides vmctl's. Move the Include line above it."
    }
    return result
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
    let daemon = bin.appendingPathComponent("vmd")
    guard FileManager.default.isExecutableFile(atPath: daemon.path) else { throw Failure("daemon_missing", "Place signed vmd beside vmctl.") }
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
func parseSize(_ text: String, flag: String = "--disk") throws -> UInt64 {
    let lowered = text.lowercased()
    let units: [(String, UInt64)] = [("tib", 1 << 40), ("tb", 1 << 40), ("t", 1 << 40), ("gib", 1 << 30), ("gb", 1 << 30), ("g", 1 << 30),
                                     ("mib", 1 << 20), ("mb", 1 << 20), ("m", 1 << 20)]
    var digits = Substring(lowered), unit: UInt64 = 1 << 30
    if let match = units.first(where: { lowered.hasSuffix($0.0) }) { digits = lowered.dropLast(match.0.count); unit = match.1 }
    guard let count = UInt64(digits), count > 0, count <= UInt64.max / unit else {
        throw Failure("usage", "\(flag) takes a size such as 20G, 512M or 1T; a bare number means GiB.")
    }
    return count * unit
}
/// Runs a program to its end with stdin from `input` (or /dev/null) and returns what it printed.
func run(_ executable: String, _ arguments: [String], input: String? = nil) -> (status: Int32, output: String, errors: String) {
    let process = Process(), out = Pipe(), err = Pipe(), stdin = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardOutput = out; process.standardError = err
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
    guard (try? process.run()) != nil else { return (127, "", "cannot run \(executable)") }
    if let input { stdin.fileHandleForWriting.write(Data(input.utf8)); stdin.fileHandleForWriting.closeFile() }
    let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, output, errors.trimmingCharacters(in: .whitespacesAndNewlines))
}
/// One request to the daemon, for commands that need its answer as a step of their own work.
func daemonValue(_ store: Store, command: String, name: String) throws -> String {
    let fd = try daemonConnection(store); defer { close(fd) }
    Wire.timeout(fd, seconds: 30)
    try Wire.send(Request(command: command, name: name), to: fd)
    let reply = try Wire.receive(Reply.self, from: fd)
    if let error = reply.error { throw error }
    return reply.value ?? ""
}
/// What is mounted at `path`, if `path` is itself a mount point: the file system type and its source.
func mountedAt(_ path: String) -> (type: String, source: String)? {
    var info = statfs()
    guard statfs(path, &info) == 0 else { return nil }
    func text<T>(_ tuple: T) -> String { withUnsafeBytes(of: tuple) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) } }
    guard text(info.f_mntonname) == URL(fileURLWithPath: path).standardizedFileURL.path else { return nil }
    return (text(info.f_fstypename), text(info.f_mntfromname))
}
/// Runs a script in the guest as root, over SSH with vmctl's own ssh_config: the pinned host key
/// and the --user account, whatever ~/.ssh/config says.
func runInGuest(_ store: Store, _ name: String, script: String) throws {
    let result = run("/usr/bin/ssh", ["-T", "-F", store.sshConfig.path, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                                      SSHConfig.host(name), GuestMount.remoteCommand], input: script)
    guard result.status == 0 else {
        let reason = result.errors.isEmpty ? "ssh exited with status \(result.status)" : result.errors
        throw Failure("guest_setup_failed", "Could not set up the export in the guest: \(reason)")
    }
}
func mountGuestDirectory(_ record: GuestMount.Record, address: String) throws {
    if let mounted = mountedAt(record.mountPoint) {
        guard mounted.type == "nfs", mounted.source.hasSuffix(":" + record.guestPath) else {
            throw Failure("mount_point_in_use", "\(record.mountPoint) has \(mounted.source) mounted on it.")
        }
        return
    }
    try FileManager.default.createDirectory(atPath: record.mountPoint, withIntermediateDirectories: true)
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: record.mountPoint)) ?? []
    guard contents.filter({ $0 != ".DS_Store" }).isEmpty else {
        throw Failure("mount_point_in_use", "\(record.mountPoint) is not empty. Mount on an empty directory.")
    }
    let result = run("/sbin/mount_nfs", try GuestMount.mountArguments(address: address, guestPath: record.guestPath, mountPoint: record.mountPoint))
    guard result.status == 0 else { throw Failure("mount_failed", result.errors.isEmpty ? "mount_nfs exited with status \(result.status)." : result.errors) }
}
/// Unmounts; with `force` also when files are open or the guest no longer answers. True when
/// nothing is mounted there afterwards.
func unmountGuestDirectory(_ record: GuestMount.Record, force: Bool) -> (done: Bool, reason: String) {
    guard mountedAt(record.mountPoint) != nil else { return (true, "") }
    var result = run("/sbin/umount", [record.mountPoint])
    if result.status != 0, force { result = run("/sbin/umount", ["-f", record.mountPoint]) }
    return (result.status == 0, result.errors)
}
/// The address of a running VM once it has one and answers on the NFS port, within `seconds`.
func waitForNFS(_ store: Store, _ name: String, seconds: Int) -> String? {
    for _ in 0..<seconds {
        if let address = try? daemonValue(store, command: "ip", name: name), !address.isEmpty,
           run("/usr/bin/nc", ["-z", "-G", "1", address, "2049"]).status == 0 { return address }
        sleep(1)
    }
    return nil
}
func warn(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

/// `vmctl mount` and `vmctl umount`: done here, with ssh, mount_nfs and umount; the daemon only says
/// where the VM is.
func mountCommand(_ store: Store, _ name: String, _ arguments: [String]) throws {
    let directory = try store.existing(name)
    var records = try GuestMount.records(in: directory)
    if arguments.isEmpty {
        if records.isEmpty { print("No mounts. vmctl mount \(name) <guest-directory> [<mount-point>]") }
        for record in records {
            print("\(record.guestPath)\t\(record.mountPoint)\t\(mountedAt(record.mountPoint) == nil ? "not mounted" : "mounted")")
        }
        return
    }
    guard arguments.count <= 2, !arguments.contains(where: { $0.hasPrefix("--") }) else {
        throw Failure("usage", "Use vmctl mount <name> [<guest-directory> [<mount-point>]].")
    }
    let saved = try JSONDecoder().decode(Configuration.self, from: Store.read(directory.appendingPathComponent("config.json")))
    guard saved.isLinux, saved.sshUser != nil else {
        throw Failure("mount_unsupported", "mount needs a Linux VM started with --user: vmctl sets the export up over SSH as that account.")
    }
    let guestPath = try GuestMount.validate(guestPath: arguments[0])
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let mountPoint = arguments.count == 2 ? absolute(arguments[1]) : GuestMount.defaultMountPoint(home: home, name: name, guestPath: guestPath)
    try GuestMount.validate(mountPoint: mountPoint, home: home, store: store.root.path)
    let record = GuestMount.Record(guestPath: guestPath, mountPoint: mountPoint)
    records = try GuestMount.adding(record, to: records)

    let address = try daemonValue(store, command: "ip", name: name)
    try runInGuest(store, name, script: try GuestMount.exportScript(guestPath: guestPath))
    try mountGuestDirectory(record, address: address)
    try GuestMount.save(records, in: directory)
    print("\(SSHConfig.host(name)):\(guestPath) is mounted on \(mountPoint)")
    print("It is unmounted by vmctl stop and mounted again by vmctl start.")
    if FileManager.default.fileExists(atPath: mountPoint + "/.git") {
        print("git refuses a repository whose files belong to another user until you allow it:\n    git config --global --add safe.directory \(mountPoint)")
    }
}
func umountCommand(_ store: Store, _ name: String, _ arguments: [String]) throws {
    var arguments = arguments
    let force = arguments.last == "--force"
    if force { arguments.removeLast() }
    guard arguments.count <= 1, !arguments.contains(where: { $0.hasPrefix("--") }) else {
        throw Failure("usage", "Use vmctl umount <name> [<mount-point>] [--force].")
    }
    let directory = try store.existing(name)
    let records = try GuestMount.records(in: directory)
    let wanted = arguments.first.map { absolute($0) }
    let chosen = records.filter { wanted == nil || $0.mountPoint == wanted }
    guard !chosen.isEmpty else {
        throw Failure("not_mounted", wanted.map { "\($0) is not a mount of \(name). See vmctl mount \(name)." } ?? "\(name) has no mounts.")
    }
    var remaining = records
    for record in chosen {
        let result = unmountGuestDirectory(record, force: force)
        guard result.done else {
            try GuestMount.save(remaining, in: directory)
            throw Failure("unmount_failed", "\(record.mountPoint): \(result.reason). Close what has files open there, or add --force.")
        }
        remaining.removeAll { $0 == record }
        // The export goes too, when the guest can be reached; a stopped guest keeps a harmless file.
        if (try? daemonValue(store, command: "ip", name: name)) != nil,
           let script = try? GuestMount.unexportScript(guestPath: record.guestPath) { try? runInGuest(store, name, script: script) }
        print("Unmounted \(record.mountPoint)")
    }
    try GuestMount.save(remaining, in: directory)
}
/// Before a VM stops or is removed: its directories leave this Mac first. A mount whose server is
/// gone makes every program that looks at it wait, so this is forced; files still open there get
/// an error, as they would from the guest going away.
func unmountBeforeStop(_ store: Store, _ name: String) {
    guard let directory = try? store.existing(name), let records = try? GuestMount.records(in: directory) else { return }
    for record in records where mountedAt(record.mountPoint) != nil {
        let result = unmountGuestDirectory(record, force: true)
        if !result.done { warn("Could not unmount \(record.mountPoint): \(result.reason)") }
    }
}
/// After a VM started: its recorded directories come back. Never an error of start itself.
func mountAfterStart(_ store: Store, _ name: String) {
    guard let directory = try? store.existing(name), let records = try? GuestMount.records(in: directory), !records.isEmpty else { return }
    guard let address = waitForNFS(store, name, seconds: 120) else {
        warn("\(name) did not answer on the NFS port within two minutes; its directories are not mounted. Try: vmctl mount \(name) <guest-directory> <mount-point>")
        return
    }
    for record in records {
        do {
            // The guest may have a new address, and the export names this Mac's: write it again.
            try runInGuest(store, name, script: try GuestMount.exportScript(guestPath: record.guestPath))
            try mountGuestDirectory(record, address: address)
            print("Mounted \(SSHConfig.host(name)):\(record.guestPath) on \(record.mountPoint)")
        } catch { warn("Could not mount \(record.guestPath) on \(record.mountPoint): \(Failure.wrapping(error).message)") }
    }
}

umask(0o077)

signal(SIGPIPE, SIG_IGN)
do {
    var args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args == ["--help"] || args == ["-h"] { usage(); exit(0) }
    let command = args.removeFirst()
    if command == "help" {
        switch args {
        case []: usage()
        case ["ssh-config"]: sshConfigHelp()
        default: throw Failure("usage", "Use vmctl help [ssh-config].")
        }
        exit(0)
    }
    guard ["create", "start", "stop", "status", "ip", "logs", "list", "console", "rm", "ssh-config", "mount", "umount"].contains(command) else { throw Failure("usage", "Unknown command. Run vmctl --help.") }
    if command == "list", !args.isEmpty { throw Failure("usage", "Usage: vmctl list (no arguments).") }
    var name = command == "ssh-config" ? "" : "mac" // ssh-config without a name covers every VM.
    if let first = args.first, !first.hasPrefix("--") { name = args.removeFirst() }
    else if command == "rm" { throw Failure("usage", "Usage: vmctl rm <name>. The name is never defaulted for removal.") }
    else if command == "mount" || command == "umount" { throw Failure("usage", "Usage: vmctl \(command) <name> ... The name is never defaulted for mounts.") }
    if !name.isEmpty { try validateName(name) }
    if command == "mount" { try mountCommand(try Store(), name, args); exit(0) }
    if command == "umount" { try umountCommand(try Store(), name, args); exit(0) }
    var restore: String?, kind: String?, image: String?, installer: String?, diskSize: UInt64?, cpuCount: Int?, memorySize: UInt64?
    var kernel: String?, initrd: String?, kernelCommandLine: String?, share: String?, shareReadOnly: Bool?
    var provisioning: Provisioning?
    var sshIdentityFile: String?, sshUser: String?, hostKey: String?
    var forceStop = false
    switch command {
    case "create":
        let createUsage = Failure("usage", "Use vmctl create [name] --restore /path/to/Apple.ipsw, or create [name] --linux [--image /path/to/raw.img] [--disk <size>] [--cpus <n>] [--memory <size>] [--kernel <Image> [--initrd <path>] [--cmdline <args>]] [--share <dir>[:ro]].")
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
                case "--cpus" where cpuCount == nil:
                    guard let count = Int(value), count > 0 else { throw Failure("usage", "--cpus takes a positive whole number.") }
                    cpuCount = count
                case "--memory" where memorySize == nil: memorySize = try parseSize(value, flag: "--memory")
                case "--kernel" where kernel == nil: kernel = absolute(value)
                case "--initrd" where initrd == nil: initrd = absolute(value)
                case "--cmdline" where kernelCommandLine == nil: kernelCommandLine = value
                case "--share" where share == nil:
                    let readOnly = value.hasSuffix(":ro")
                    share = absolute(readOnly ? String(value.dropLast(3)) : value)
                    if readOnly { shareReadOnly = true }
                default: throw createUsage
                }
            }
            if kernel == nil, initrd != nil || kernelCommandLine != nil { throw Failure("usage", "--initrd and --cmdline require --kernel.") }
            if let kernelCommandLine { try KernelBoot.validate(commandLine: kernelCommandLine) }
        } else { throw createUsage }
    case "ssh-config":
        while !args.isEmpty {
            let flag = args.removeFirst()
            guard !args.isEmpty else { throw Failure("usage", "Missing value for \(flag).") }
            let value = args.removeFirst()
            switch flag {
            case "--user" where sshUser == nil: sshUser = value
            case "--identity" where sshIdentityFile == nil: sshIdentityFile = absolute(value)
            case "--host-key" where hostKey == nil: hostKey = try readPublicKey(value)
            default: throw Failure("usage", "Use vmctl ssh-config [name] [--user <user>] [--identity <private-key-path>] [--host-key <key-or-file>].")
            }
        }
    case "logs" where args.first == "--console":
        args.removeFirst()
        let follow = args == ["--follow"] || args == ["-f"]
        guard args.isEmpty || follow else { throw Failure("usage", "Use vmctl logs [name] [--console [--follow]].") }
        try showConsoleLog(try Store().existing(name), follow: follow)
        exit(0)
    case "stop":
        if args == ["--force"] { forceStop = true } else if !args.isEmpty { throw Failure("usage", "Use vmctl stop [name] [--force].") }
    case "start":
        var username: String?, fullName: String?, sshKey: String?, dns: String?
        while !args.isEmpty {
            let flag = args.removeFirst()
            guard !args.isEmpty else { throw Failure("usage", "Missing value for \(flag).") }
            let value = args.removeFirst()
            switch flag {
            case "--user" where username == nil: username = value
            case "--full-name" where fullName == nil: fullName = value
            case "--ssh-key" where sshKey == nil:
                sshKey = try readPublicKey(value)
                // A key given as foo.pub names its private half, foo, for IdentityFile. The path is
                // derived, never opened: vmctl reads nothing in ~/.ssh beyond the .pub it was given.
                if value.hasSuffix(".pub"), !Provisioning.publicKeyTypes.contains(where: { value.hasPrefix($0 + " ") }) {
                    sshIdentityFile = String(absolute(value).dropLast(4))
                }
            case "--dns" where dns == nil: dns = value
            case "--iso" where installer == nil: installer = absolute(value)
            default: throw Failure("usage", "Use start [name] [--iso <path>] [--user <username> [--full-name <name>] [--ssh-key <key>] [--dns <ip>]]. Passwords must be entered at the prompt.")
            }
        }
        if let username {
            // Validate the account before prompting so a bad name fails fast. Key-only accounts take no password.
            try Provisioning(username: username, fullName: fullName ?? username, password: sshKey == nil ? "validation-placeholder" : nil, sshPublicKey: sshKey, dns: dns).validate()
            var password: String?
            if sshKey == nil {
                password = try readPassword("New guest password: ")
                guard password == (try readPassword("Confirm guest password: ")) else { throw Failure("password_mismatch", "Passwords did not match.") }
            }
            // Linux guests generate the host's locale, so the LC_* variables ssh sends from this Mac are valid
            // there. macOS provisioning ignores it.
            provisioning = Provisioning(username: username, fullName: fullName ?? username, password: password, sshPublicKey: sshKey,
                                        locale: Provisioning.hostLocale(ProcessInfo.processInfo.environment), dns: dns)
            try provisioning!.validate()
        } else if fullName != nil || sshKey != nil || dns != nil { throw Failure("usage", "--full-name, --ssh-key and --dns require --user.") }
    default:
        if !args.isEmpty { throw Failure("usage", "Unexpected arguments.") }
    }

    let store = try Store()
    if command == "stop" || command == "rm" { unmountBeforeStop(store, name) }
    let fd = try daemonConnection(store); defer { close(fd) }
    Wire.timeout(fd, seconds: command == "create" ? 86400 : 120)
    try Wire.send(Request(command: forceStop ? "force-stop" : (provisioning == nil ? command : "provision"), name: name,
                          restore: restore, provisioning: provisioning, kind: kind, image: image, installer: installer, diskSize: diskSize,
                          cpuCount: cpuCount, memorySize: memorySize,
                          kernel: kernel, initrd: initrd, kernelCommandLine: kernelCommandLine,
                          share: share, shareReadOnly: shareReadOnly,
                          sshIdentityFile: sshIdentityFile, sshUser: sshUser, hostKey: hostKey), to: fd)
    let response = try Wire.receive(Reply.self, from: fd)
    let upgrade = Failure("daemon_upgrade_required", "The running daemon is an older version. Stop your running VMs, quit the daemon (vmd, or vmctld in older builds) in Activity Monitor, then retry with the updated daemon.")
    if let error = response.error {
        let newer = provisioning != nil || forceStop || ["list", "console", "rm", "ssh-config"].contains(command) || kind != nil || installer != nil
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
    if cpuCount != nil || memorySize != nil || kernel != nil || share != nil, response.value == "created" {
        // Likewise for --cpus/--memory/--kernel/--share: an older daemon drops the fields and builds a default EFI VM.
        let saved = try JSONDecoder().decode(Configuration.self, from: Store.read(try store.vm(name).appendingPathComponent("config.json")))
        if cpuCount.map({ $0 != saved.cpuCount }) == true || memorySize.map({ $0 != saved.memorySize }) == true
            || (kernel != nil && !saved.bootsKernel) || (share != nil && saved.share == nil) {
            throw Failure(upgrade.code, "VM \(name) was created without the requested CPU, memory, kernel or share settings. \(upgrade.message) Remove ~/.vmctl/vms/\(name) first.")
        }
    }

    if let value = response.value, !value.isEmpty {
        // Tab-separated for scripts and completion; padded columns on a terminal, where a name
        // longer than one tab stop would otherwise push its row out of line.
        print(command == "list" && isatty(STDOUT_FILENO) == 1 ? alignColumns(value) : value)
    }
    if provisioning != nil {
        let saved = try JSONDecoder().decode(Configuration.self, from: Store.read(try store.vm(name).appendingPathComponent("config.json")))
        if saved.isLinux {
            // A daemon without ssh_config support provisions without pinning a host key.
            guard FileManager.default.fileExists(atPath: try store.knownHosts(name).path) else {
                throw Failure(upgrade.code, "VM \(name) was provisioned without an ssh_config entry. \(upgrade.message)")
            }
            print(sshReachability(name, store: store))
        }
    } else if command == "ssh-config", !name.isEmpty {
        print(sshReachability(name, store: store))
    }
    if command == "start" { mountAfterStart(store, name) }
} catch {
    let reply = Reply(error: Failure.wrapping(error))
    if let data = try? JSONEncoder().encode(reply) { FileHandle.standardError.write(data); FileHandle.standardError.write(Data([10])) }
    exit(1)
}
