import Foundation
import Virtualization
import AppKit
import VMCore
import Darwin

#if !arch(arm64)
#error("vmctld requires Apple Silicon")
#endif

// All mutable supervisor and VZ state belongs to DispatchQueue.main.
final class Supervisor: NSObject, VZVirtualMachineDelegate {
    static let diskSize: off_t = 64 * 1024 * 1024 * 1024
    let store: Store
    var machine: VZVirtualMachine?
    var installer: VZMacOSInstaller?
    var activeName: String?
    var phase = "stopped"
    var stopReplies: [(Reply) -> Void] = []
    let shutdownWatch = ShutdownWatch()
    var forceStopPending = false
    var lastFailure: Failure?
    let console = Console()
    init(store: Store) { self.store = store }

    func log(_ name: String, _ event: String, _ error: Error? = nil) {
        do {
            let dir = try store.existing(name).appendingPathComponent("logs")
            try Store.directory(dir)
            let url = dir.appendingPathComponent("daemon.jsonl")
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw systemFailure("open log") }; defer { close(fd) }
            try Store.check(url)
            var row = ["time": ISO8601DateFormatter().string(from: Date()), "event": event, "vm": name, "pid": String(getpid())]
            if let error { row["error"] = Failure.wrapping(error).description }
            var data = try JSONEncoder().encode(row); data.append(10)
            _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        } catch { fputs("Logging failed: \(error)\n", stderr) }
    }
    func saved(_ name: String) throws -> (URL, Configuration) {
        let dir = try store.existing(name)
        return (dir, try JSONDecoder().decode(Configuration.self, from: Store.read(dir.appendingPathComponent("config.json"))))
    }
    /// Validates a local regular file given by absolute path. Symlinks are rejected.
    static func localFile(_ path: String?, _ code: String, _ what: String) throws -> URL? {
        guard let path else { return nil }
        guard path.hasPrefix("/") else { throw Failure(code, "\(what) path must be absolute.") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure(code, "\(what) must be a local regular file, not a symlink.") }
        // Apple Silicon boots only arm64 guests. Catch the common wrong download by name instead of a silent firmware halt.
        let lowered = url.lastPathComponent.lowercased()
        guard !["amd64", "x86_64", "x86-64", "i386", "i686"].contains(where: { lowered.contains($0) }) else {
            throw Failure(code, "\(what) looks like an x86 build (\(url.lastPathComponent)). Apple Silicon VMs need arm64/aarch64 images.")
        }
        return url
    }
    func configuration(_ name: String, allowIncomplete: Bool = false, installer: URL? = nil) throws -> VZVirtualMachineConfiguration {
        let (dir, saved) = try saved(name)
        guard saved.version == 1, saved.name == name, saved.installed || allowIncomplete else {
            throw Failure("incomplete_vm", "Installation is incomplete or config version/name is invalid.")
        }
        guard let mac = VZMACAddress(string: saved.macAddress) else { throw Failure("invalid_identity", "Invalid persisted MAC address.") }
        let disk = dir.appendingPathComponent("disk.img")
        try Store.check(disk)
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = saved.cpuCount; config.memorySize = saved.memorySize
        var storage: [VZStorageDeviceConfiguration] = [VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false))]
        if saved.isLinux {
            guard let identity = VZGenericMachineIdentifier(dataRepresentation: try Store.read(dir.appendingPathComponent("machine-identifier"))) else {
                throw Failure("invalid_identity", "Invalid persisted machine identifier.")
            }
            let platform = VZGenericPlatformConfiguration()
            platform.machineIdentifier = identity
            config.platform = platform
            let variables = dir.appendingPathComponent("efi-variable-store")
            try Store.check(variables)
            let loader = VZEFIBootLoader()
            loader.variableStore = VZEFIVariableStore(url: variables)
            config.bootLoader = loader
            // A cloud-init seed written by provisioning stays attached; cloud-init keys off its instance-id.
            let seed = dir.appendingPathComponent("cloud-init.img")
            var info = stat()
            if lstat(seed.path, &info) == 0 {
                try Store.check(seed)
                storage.append(VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: seed, readOnly: true)))
            }
            if let installer {
                storage.append(VZUSBMassStorageDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: installer, readOnly: true)))
            }
            config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: Int(Console.initialSize.width), heightInPixels: Int(Console.initialSize.height))]
            config.graphicsDevices = [graphics]
        } else {
            guard installer == nil else { throw Failure("unsupported_option", "--iso applies to Linux VMs only.") }
            guard let hardware = VZMacHardwareModel(dataRepresentation: try Store.read(dir.appendingPathComponent("hardware-model"))), hardware.isSupported,
                  let identity = VZMacMachineIdentifier(dataRepresentation: try Store.read(dir.appendingPathComponent("machine-identifier"))) else {
                throw Failure("invalid_identity", "Unsupported hardware model or invalid persisted identity.")
            }
            let auxiliary = dir.appendingPathComponent("auxiliary-storage")
            try Store.check(auxiliary)
            let platform = VZMacPlatformConfiguration()
            platform.hardwareModel = hardware; platform.machineIdentifier = identity
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: auxiliary)
            config.platform = platform; config.bootLoader = VZMacOSBootLoader()
            let graphics = VZMacGraphicsDeviceConfiguration()
            if Console.hasDesktopSession, let screen = NSScreen.main {
                graphics.displays = [VZMacGraphicsDisplayConfiguration(for: screen, sizeInPoints: Console.initialSize)]
            } else {
                // HiDPI starting mode when there is no host display to match.
                graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 2048, heightInPixels: 1536, pixelsPerInch: 160)]
            }
            config.graphicsDevices = [graphics]
        }
        config.storageDevices = storage
        let network = VZVirtioNetworkDeviceConfiguration()
        network.macAddress = mac; network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]
        // The optional console attaches to this same VM and its input devices.
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        try config.validate()
        return config
    }
    func handle(_ request: Request, reply: @escaping (Reply) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            try validateName(request.name)
            // Reconcile live framework state, never disk or network reachability.
            if (phase == "running" || phase == "stopping"), machine?.state == .stopped {
                finishStop()
            }
            switch request.command {
            case "console":
                guard activeName == request.name, phase == "running", let vm = machine else {
                    throw Failure("not_running", "Start this VM before opening its console.")
                }
                try console.show(vm, name: request.name)
                log(request.name, "console_opened")
                reply(Reply(value: "console opened"))
            case "list":
                let directory = store.root.appendingPathComponent("vms")
                try Store.check(directory, directory: true)
                let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
                var rows = ["NAME\tSTATE"]
                for name in names {
                    // Ignore unrelated entries and unsafe directories without following links.
                    guard (try? store.existing(name)) != nil else { continue }
                    rows.append("\(name)\t\(activeName == name ? phase : "stopped")")
                }
                reply(Reply(value: rows.joined(separator: "\n")))
            case "start", "provision":
                let provisioning = request.command == "provision"
                if !provisioning, activeName == request.name && phase == "running" { reply(Reply(value: "running")); return }
                guard machine == nil, phase != "installing" else { throw Failure("busy", "VM \(activeName ?? "") is \(phase).") }
                let (dir, loaded) = try saved(request.name)
                var saved = loaded
                let configURL = dir.appendingPathComponent("config.json")
                let installer = try Self.localFile(request.installer, "invalid_installer", "Installer image")
                guard installer == nil || saved.isLinux else { throw Failure("unsupported_option", "--iso applies to Linux VMs only.") }
                let options = VZMacOSVirtualMachineStartOptions()
                if provisioning {
                    guard let credentials = request.provisioning else { throw Failure("invalid_provisioning", "Missing account details.") }
                    try credentials.validate()
                    try validateProvisioningEligibility(saved)
                    if saved.isLinux {
                        // Only the password hash and the public key reach the seed.
                        try Store.write(try CloudInit.seedImage(credentials, hostname: request.name), to: dir.appendingPathComponent("cloud-init.img"))
                    } else {
                        guard credentials.sshPublicKey == nil, let password = credentials.password else {
                            throw Failure("invalid_provisioning", "macOS guests are provisioned with a password only; --ssh-key applies to Linux VMs.")
                        }
                        if #available(macOS 27.0, *) {
                            let setup = VZMacGuestProvisioningOptions()
                            setup.username = credentials.username; setup.fullName = credentials.fullName
                            setup.password = password
                            setup.enablesRemoteLogin = true; setup.logsInAutomatically = false
                            do { try options.setGuestProvisioning(setup) }
                            catch { throw Failure("invalid_provisioning", "Apple rejected the provisioning settings. Check the account name and password requirements.") }
                        } else { throw Failure("unsupported_host", "User provisioning requires macOS 27 or later on the host.") }
                    }
                }
                guard VZVirtualMachine.isSupported else { throw Failure("unsupported_host", "Virtualization is unavailable on this host.") }
                let vm = VZVirtualMachine(configuration: try configuration(request.name, installer: installer))
                // Consume before start: crashes/failures may have booted the guest. Never guess or retry provisioning.
                saved.firstBootAvailable = false
                try Store.write(JSONEncoder().encode(saved), to: configURL)
                machine = vm; vm.delegate = self; activeName = request.name; phase = "starting"; lastFailure = nil
                log(request.name, provisioning ? "starting_with_provisioning" : "starting")
                let name = request.name // The completion does not retain the credential-bearing request.
                let completion: (Error?) -> Void = { error in
                    if let error {
                        let safeError: Error = provisioning ? Failure("provisioning_start_failed", "VM start with provisioning failed. Restore a fresh VM before retrying provisioning.") : error
                        self.fail(safeError); reply(Reply(error: Failure.wrapping(safeError)))
                    } else {
                        self.phase = "running"; self.log(name, "running"); reply(Reply(value: "running"))
                    }
                }
                if saved.isLinux {
                    vm.start { result in if case .failure(let error) = result { completion(error) } else { completion(nil) } }
                } else { vm.start(options: options, completionHandler: completion) }
            case "stop", "force-stop":
                _ = try store.existing(request.name)
                if activeName != request.name || machine == nil { reply(Reply(value: "stopped")); return }
                guard phase == "running" || phase == "stopping" else { throw Failure("busy", "Cannot stop while \(phase).") }
                stopReplies.append(reply)
                if request.command == "force-stop" {
                    phase = "stopping"
                    forceStop()
                    return
                }
                if phase == "stopping" { return }
                phase = "stopping"; log(request.name, "shutdown_requested")
                if let vm = machine, vm.canRequestStop {
                    do {
                        try vm.requestStop()
                        shutdownWatch.start(on: .main, isStopped: { [weak vm] in
                            vm?.state == .stopped
                        }, stopped: { [weak self, weak vm] in
                            guard let self, let vm, self.machine === vm else { return }
                            self.finishStop()
                        }, timedOut: { [weak self, weak vm] in
                            guard let self, let vm, self.machine === vm else { return }
                            self.forceStop()
                        })
                    } catch { log(request.name, "graceful_shutdown_unavailable", error); forceStop() }
                } else { forceStop() }
            case "status":
                // No disk/config/image reads. The private VM directory only establishes existence.
                _ = try store.existing(request.name)
                reply(Reply(value: activeName == request.name ? phase : "stopped"))
            case "create":
                switch request.kind {
                case nil: try create(request, reply: reply)
                case "linux": try createLinux(request, reply: reply)
                default: throw Failure("invalid_kind", "Unknown VM kind.")
                }
            case "logs":
                let dir = try store.existing(request.name).appendingPathComponent("logs")
                try Store.check(dir, directory: true)
                let file = dir.appendingPathComponent("daemon.jsonl")
                if !FileManager.default.fileExists(atPath: file.path) { reply(Reply(value: "")); return }
                try Store.check(file)
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                let size = try handle.seekToEnd(); let offset = size > 24000 ? size - 24000 : 0
                try handle.seek(toOffset: offset)
                var text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
                if offset > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
                reply(Reply(value: text.trimmingCharacters(in: .newlines)))
            case "ip":
                guard activeName == request.name, phase == "running" else { throw Failure("not_running", "VM is not running.") }
                let (_, config) = try saved(request.name)
                guard let ip = Self.leaseIP(mac: config.macAddress) else { throw Failure("ip_unknown", "No unexpired NAT lease is readable for this VM. Guest networking may not be ready.") }
                reply(Reply(value: ip))
            default: throw Failure("invalid_command", "Unknown command.")
            }
        } catch { reply(Reply(error: Failure.wrapping(error))) }
    }
    func forceStop() {
        shutdownWatch.cancel()
        guard !forceStopPending else { return }
        guard let vm = machine else { finishStop(); return }
        if vm.state == .stopped { finishStop(); return }
        guard vm.canStop else { finishStop(error: Failure("cannot_stop", "Framework cannot stop the VM in its current state; retry status/stop.")); return }
        if let name = activeName { log(name, "forced_shutdown") }
        forceStopPending = true
        vm.stop { error in
            guard self.machine === vm else { return }
            self.finishStop(error: error)
        }
    }
    func finishStop(error: Error? = nil) {
        shutdownWatch.cancel()
        forceStopPending = false
        if let error {
            phase = machine?.state == .running ? "running" : "error"
            if let name = activeName { log(name, "stop_failed", error) }
        } else {
            console.close()
            phase = "stopped"; machine = nil
            if let name = activeName { log(name, "stopped") }
        }
        let pending = stopReplies; stopReplies.removeAll()
        pending.forEach { $0(Reply(value: error == nil ? "stopped" : nil, error: error.map(Failure.wrapping))) }
    }
    func fail(_ error: Error) {
        console.close()
        lastFailure = Failure.wrapping(error)
        if let name = activeName { log(name, "vm_failed", error) }
        finishStop(error: error); machine = nil; phase = "error"
    }
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        guard virtualMachine === machine, phase != "installing" else { return }
        // Not requested by us: the guest shut down, or the firmware halted with nothing bootable.
        if phase == "running", let name = activeName { log(name, "guest_powered_off") }
        finishStop()
    }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        guard virtualMachine === machine, phase != "installing" else { return }; fail(error)
    }
    /// Exclusive creation of the VM directory; never overwrites an existing identity or disk.
    func reserveDirectory(_ request: Request) throws -> URL {
        guard VZVirtualMachine.isSupported else { throw Failure("unsupported_host", "Virtualization is unavailable on this host.") }
        guard machine == nil, phase != "installing" else { throw Failure("busy", "Stop the active VM before installing.") }
        let dir = try store.vm(request.name)
        guard mkdir(dir.path, 0o700) == 0 else { throw systemFailure("create VM directory (must not already exist)") }
        try Store.directory(dir.appendingPathComponent("logs"))
        return dir
    }
    static func createDisk(at url: URL, copying image: URL?) throws {
        if let image {
            // Same-volume APFS copies are clones; otherwise this is a full copy on a background queue.
            try FileManager.default.copyItem(at: image, to: url)
            guard chmod(url.path, 0o600) == 0 else { throw systemFailure("chmod disk") }
        }
        let disk = open(url.path, O_RDWR | (image == nil ? O_CREAT | O_EXCL : 0) | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard disk >= 0 else { throw systemFailure("create disk") }
        defer { close(disk) }
        var info = stat()
        guard fstat(disk, &info) == 0 else { throw systemFailure("stat disk") }
        guard info.st_size <= diskSize else { throw Failure("image_too_large", "Disk images larger than 64 GiB are not supported.") }
        guard info.st_size == diskSize || ftruncate(disk, diskSize) == 0 else { throw systemFailure("size disk") }
    }
    func createLinux(_ request: Request, reply: @escaping (Reply) -> Void) throws {
        let image = try Self.localFile(request.image, "invalid_image", "Disk image")
        if let image {
            let handle = try FileHandle(forReadingFrom: image)
            let magic = try handle.read(upToCount: 4) ?? Data(); try handle.close()
            guard magic != Data([0x51, 0x46, 0x49, 0xFB]) else { throw Failure("invalid_image", "qcow2 images are not supported; supply a raw disk image.") }
            var info = stat()
            guard stat(image.path, &info) == 0, info.st_size <= Self.diskSize else { throw Failure("image_too_large", "Disk images larger than 64 GiB are not supported.") }
        }
        let dir = try reserveDirectory(request)
        activeName = request.name; phase = "installing"; log(request.name, "preparing_linux_vm")
        var saved: Configuration
        do {
            try Store.write(VZGenericMachineIdentifier().dataRepresentation, to: dir.appendingPathComponent("machine-identifier"))
            let variables = dir.appendingPathComponent("efi-variable-store")
            _ = try VZEFIVariableStore(creatingVariableStoreAt: variables, options: [])
            guard chmod(variables.path, 0o600) == 0 else { throw systemFailure("chmod variable store") }
            try Store.check(variables)
            let cpus = min(max(4, VZVirtualMachineConfiguration.minimumAllowedCPUCount), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
            let memory = min(max(8 * 1024 * 1024 * 1024, VZVirtualMachineConfiguration.minimumAllowedMemorySize), VZVirtualMachineConfiguration.maximumAllowedMemorySize)
            saved = Configuration(name: request.name, cpuCount: cpus, memorySize: memory, macAddress: VZMACAddress.randomLocallyAdministered().string, installed: false)
            saved.kind = "linux"; saved.firstBootAvailable = true
            try Store.write(JSONEncoder().encode(saved), to: dir.appendingPathComponent("config.json"))
        } catch { fail(error); throw error }
        let disk = dir.appendingPathComponent("disk.img")
        DispatchQueue.global().async {
            let prepared = Result { try Self.createDisk(at: disk, copying: image) }
            DispatchQueue.main.async {
                do {
                    try prepared.get()
                    _ = try self.configuration(request.name, allowIncomplete: true)
                    saved.installed = true
                    try Store.write(JSONEncoder().encode(saved), to: dir.appendingPathComponent("config.json"))
                    self.machine = nil; self.phase = "stopped"
                    self.log(request.name, "linux_vm_created")
                    reply(Reply(value: "created"))
                } catch { self.fail(error); reply(Reply(error: Failure.wrapping(error))) }
            }
        }
    }
    func create(_ request: Request, reply: @escaping (Reply) -> Void) throws {
        guard request.image == nil, request.installer == nil else { throw Failure("unsupported_option", "--image and --iso apply to Linux VMs only.") }
        guard let path = request.restore, path.hasPrefix("/") else { throw Failure("restore_required", "Use create [name] --restore /absolute/path/to/Apple.ipsw.") }
        let imageURL = URL(fileURLWithPath: path).standardizedFileURL
        var info = stat()
        guard lstat(imageURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure("invalid_restore", "Restore image must be a local regular file, not a symlink.") }
        let dir = try reserveDirectory(request)
        activeName = request.name; phase = "installing"; log(request.name, "loading_restore_image")
        VZMacOSRestoreImage.load(from: imageURL) { result in
            DispatchQueue.main.async {
                do {
                    let image = try result.get()
                    guard let requirements = image.mostFeaturefulSupportedConfiguration else { throw Failure("unsupported_restore", "Restore image is not supported on this host.") }
                    let hardware = requirements.hardwareModel
                    let identity = VZMacMachineIdentifier()
                    try Store.write(hardware.dataRepresentation, to: dir.appendingPathComponent("hardware-model"))
                    try Store.write(identity.dataRepresentation, to: dir.appendingPathComponent("machine-identifier"))
                    _ = try VZMacAuxiliaryStorage(creatingStorageAt: dir.appendingPathComponent("auxiliary-storage"), hardwareModel: hardware, options: [])
                    try Self.createDisk(at: dir.appendingPathComponent("disk.img"), copying: nil)
                    var saved = Configuration(name: request.name, cpuCount: max(4, requirements.minimumSupportedCPUCount), memorySize: max(8 * 1024 * 1024 * 1024, requirements.minimumSupportedMemorySize), macAddress: VZMACAddress.randomLocallyAdministered().string, installed: false)
                    saved.guestMajorVersion = image.operatingSystemVersion.majorVersion
                    saved.firstBootAvailable = true
                    try Store.write(JSONEncoder().encode(saved), to: dir.appendingPathComponent("config.json"))
                    let vm = VZVirtualMachine(configuration: try self.configuration(request.name, allowIncomplete: true))
                    self.machine = vm; vm.delegate = self
                    let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: imageURL)
                    self.installer = installer; self.log(request.name, "installation_started")
                    installer.install { result in
                        do {
                            try result.get(); saved.installed = true
                            try Store.write(JSONEncoder().encode(saved), to: dir.appendingPathComponent("config.json"))
                            self.installer = nil; self.machine = nil; self.phase = "stopped"
                            self.log(request.name, "installation_completed")
                            reply(Reply(value: "installed"))
                        } catch {
                            self.installer = nil; self.fail(error); reply(Reply(error: Failure.wrapping(error)))
                        }
                    }
                } catch { self.fail(error); reply(Reply(error: Failure.wrapping(error))) }
            }
        }
    }
    static func leaseIP(mac: String) -> String? {
        // macOS's bootpd lease database is an implementation detail, not a VZ API.
        guard let leases = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { return nil }
        func normalized(_ s: String) -> String { s.split(separator: ":").map { String(Int($0, radix: 16) ?? -1) }.joined(separator: ":") }
        for block in leases.components(separatedBy: "{").reversed() {
            var fields: [String: String] = [:]
            for line in block.components(separatedBy: .newlines) {
                let pair = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { fields[pair[0]] = pair[1] }
            }
            guard let hw = fields["hw_address"]?.split(separator: ",").last,
                  normalized(String(hw)) == normalized(mac), let ip = fields["ip_address"],
                  let expiry = fields["lease"], let timestamp = UInt64(expiry.replacingOccurrences(of: "0x", with: ""), radix: expiry.hasPrefix("0x") ? 16 : 10),
                  Double(timestamp) > Date().timeIntervalSince1970 else { continue }
            var address = in_addr()
            if inet_pton(AF_INET, ip, &address) == 1 { return ip }
        }
        return nil
    }
}
