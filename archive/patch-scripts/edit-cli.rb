p='outputs/vmctl/Sources/vmctl/main.swift'; s=File.read(p)
s=s.sub('           vmctl create [name] --restore /path/to/Apple.ipsw', "           vmctl create [name] --restore /path/to/Apple.ipsw\n           vmctl start [name] --user <username> [--full-name <name>]\n    --user creates a user and enables SSH on first boot only (macOS 27+ host/guest).\n    Password is prompted securely on the terminal, never accepted as an argument.")
s=s.sub('umask(0o077)', <<'SWIFT')
func readPassword(_ prompt: String) throws -> String {
    var buffer = [CChar](repeating: 0, count: 1024)
    defer { buffer.withUnsafeMutableBytes { explicit_bzero($0.baseAddress!, $0.count) } }
    guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
        throw Failure("password_prompt", "Password entry requires an interactive terminal.")
    }
    return String(cString: buffer)
}
umask(0o077)
SWIFT
s=s.sub('    var restore: String?', "    var restore: String?\n    var provisioning: Provisioning?")
s=s.sub('    } else if !args.isEmpty { throw Failure("usage", "Unexpected arguments.") }', <<'SWIFT')
    } else if command == "start", !args.isEmpty {
        var username: String?; var fullName: String?
        while !args.isEmpty {
            let flag = args.removeFirst()
            guard !args.isEmpty else { throw Failure("usage", "Missing option value.") }
            let value = args.removeFirst()
            switch flag {
            case "--user" where username == nil: username = value
            case "--full-name" where fullName == nil: fullName = value
            default: throw Failure("usage", "Use start [name] --user <username> [--full-name <name>]. Passwords must be entered at the prompt.")
            }
        }
        guard let username else { throw Failure("usage", "--full-name requires --user.") }
        try Provisioning(username: username, fullName: fullName ?? username, password: "validation-placeholder").validate()
        let password = try readPassword("New guest password: ")
        guard password == (try readPassword("Confirm guest password: ")) else { throw Failure("password_mismatch", "Passwords did not match.") }
        provisioning = Provisioning(username: username, fullName: fullName ?? username, password: password)
        try provisioning!.validate()
    } else if !args.isEmpty { throw Failure("usage", "Unexpected arguments.") }
SWIFT
s=s.sub('Request(command: command, name: name, restore: restore)', 'Request(command: provisioning == nil ? command : "provision", name: name, restore: restore, provisioning: provisioning)')
s=s.sub('    if let error = response.error { throw error }', <<'SWIFT')
    if let error = response.error {
        if provisioning != nil, error.code == "invalid_command" {
            throw Failure("daemon_upgrade_required", "The running daemon is an older version. Stop your VM, quit vmctld in Activity Monitor, then retry. A fresh VM must also be created with the new daemon.")
        }
        throw error
    }
SWIFT
File.write(p,s)
