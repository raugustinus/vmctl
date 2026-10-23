p='outputs/vmctl/Sources/VMCore/Core.swift'
s=File.read(p).sub('public struct Request: Codable {', <<'SWIFT')
public struct Provisioning: Codable {
    public let username: String
    public let fullName: String
    public let password: String
    public init(username: String, fullName: String, password: String) {
        self.username = username; self.fullName = fullName; self.password = password
    }
    public func validate() throws {
        guard username.range(of: "^[a-z][a-z0-9_]{0,30}\\z", options: .regularExpression) != nil,
              !["root", "daemon", "nobody"].contains(username),
              !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fullName.utf8.count <= 128, !fullName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !password.isEmpty, password.utf8.count <= 256,
              !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure("invalid_provisioning", "Use a lowercase account name (letters, digits, underscores), a full name up to 128 bytes, and a nonempty password up to 256 bytes; control characters are prohibited.")
        }
    }
}
public struct Request: Codable {
SWIFT
s=s.sub('    public let restore: String?', "    public let provisioning: Provisioning?\n    public let restore: String?")
s=s.sub('restore: String? = nil) {', 'restore: String? = nil, provisioning: Provisioning? = nil) {')
s=s.sub('self.command = command; self.name = name; self.restore = restore', 'self.command = command; self.name = name; self.restore = restore; self.provisioning = provisioning')
s=s.sub('    public var installed: Bool', "    public var guestMajorVersion: Int?\n    public var firstBootAvailable: Bool?\n    public var installed: Bool")
s=s.sub('public func validateName', <<'SWIFT')
public func validateProvisioningEligibility(_ config: Configuration) throws {
    guard config.installed, config.version == 1,
          let major = config.guestMajorVersion, major >= 27 else {
        throw Failure("unsupported_guest", "Provisioning requires a macOS 27+ VM freshly installed by this version of vmctl.")
    }
    guard config.firstBootAvailable == true else {
        throw Failure("first_boot_required", "User provisioning is only available before the first boot. Create a fresh VM with a different name.")
    }
}
public func validateName
SWIFT
File.write(p,s)
p='outputs/vmctl/Sources/vmctld/Supervisor.swift'; s=File.read(p)
a=s.index('            case "start":'); b=s.index('            case "stop":',a)
s[a...b]=<<'SWIFT'
            case "start", "provision":
                let provisioning = request.command == "provision"
                if !provisioning, activeName == request.name && phase == "running" { reply(Reply(value: "running")); return }
                guard machine == nil, phase != "installing" else { throw Failure("busy", "VM \(activeName ?? "") is \(phase).") }
                let configURL = try store.existing(request.name).appendingPathComponent("config.json")
                var saved = try JSONDecoder().decode(Configuration.self, from: Store.read(configURL))
                let options = VZMacOSVirtualMachineStartOptions()
                if provisioning {
                    guard let credentials = request.provisioning else { throw Failure("invalid_provisioning", "Missing account details.") }
                    try credentials.validate()
                    try validateProvisioningEligibility(saved)
                    if #available(macOS 27.0, *) {
                        let setup = VZMacGuestProvisioningOptions()
                        setup.username = credentials.username; setup.fullName = credentials.fullName
                        setup.password = credentials.password
                        setup.enablesRemoteLogin = true; setup.logsInAutomatically = false
                        do { try options.setGuestProvisioning(setup) }
                        catch { throw Failure("invalid_provisioning", "Apple rejected the provisioning settings. Check the account name and password requirements.") }
                    } else { throw Failure("unsupported_host", "User provisioning requires macOS 27 or later on the host.") }
                }
                guard VZVirtualMachine.isSupported else { throw Failure("unsupported_host", "Virtualization is unavailable on this host.") }
                let vm = VZVirtualMachine(configuration: try configuration(request.name))
                // Consume before start: crashes/failures may have booted the guest. Never guess or retry provisioning.
                saved.firstBootAvailable = false
                try Store.write(JSONEncoder().encode(saved), to: configURL)
                machine = vm; vm.delegate = self; activeName = request.name; phase = "starting"; lastFailure = nil
                log(request.name, provisioning ? "starting_with_provisioning" : "starting")
                let name = request.name // The completion does not retain the credential-bearing request.
                vm.start(options: options) { error in
                    if let error {
                        let safeError: Error = provisioning ? Failure("provisioning_start_failed", "VM start with provisioning failed. Restore a fresh VM before retrying provisioning.") : error
                        self.fail(safeError); reply(Reply(error: Failure.wrapping(safeError)))
                    } else {
                        self.phase = "running"; self.log(name, "running"); reply(Reply(value: "running"))
                    }
                }
SWIFT
s=s.sub('                    try Store.write(JSONEncoder().encode(saved)', "                    saved.guestMajorVersion = image.operatingSystemVersion.majorVersion\n                    saved.firstBootAvailable = true\n                    try Store.write(JSONEncoder().encode(saved)")
File.write(p,s)
