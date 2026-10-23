import XCTest
import Foundation
import Darwin
@testable import VMCore

final class DaemonTests: XCTestCase {
    func testIndependentClientsAndExclusiveSupervisor() throws {
        guard let bin = ProcessInfo.processInfo.environment["VMCTL_TEST_BIN"] else {
            throw XCTSkip("Set VMCTL_TEST_BIN to the signed bin directory for daemon integration tests.")
        }
        let root = URL(fileURLWithPath: "/tmp/vmctl-test-\(UUID().uuidString.prefix(8))")
        let store = try Store(root: root)
        let dir = try store.vm("mac"); try Store.directory(dir)
        // If status opens the image, this FIFO blocks. No valid config exists either.
        XCTAssertEqual(mkfifo(dir.appendingPathComponent("disk.img").path, 0o600), 0)
        var environment = ProcessInfo.processInfo.environment; environment["VMCTL_HOME"] = root.path
        let daemon = Process(); daemon.executableURL = URL(fileURLWithPath: bin).appendingPathComponent("vmctld")
        daemon.environment = environment; daemon.standardOutput = FileHandle.nullDevice
        let errors = Pipe(); daemon.standardError = errors
        try daemon.run()
        defer {
            if daemon.isRunning { daemon.terminate(); daemon.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
        var ready = false
        for _ in 0..<100 {
            if let fd = try? Wire.connect(store.socketPath) { close(fd); ready = true; break }
            if !daemon.isRunning { break }; usleep(50_000)
        }
        if !ready {
            if daemon.isRunning { daemon.terminate(); daemon.waitUntilExit() }
            XCTFail("Daemon failed: \(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
            return
        }
        func client(_ args: [String]) throws -> (Int32, String) {
            let process = Process(); process.executableURL = URL(fileURLWithPath: bin).appendingPathComponent("vmctl")
            process.arguments = args; process.environment = environment
            let output = Pipe(); process.standardOutput = output; process.standardError = output
            try process.run(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        for _ in 0..<3 {
            let result = try client(["status", "mac"])
            XCTAssertEqual(result.0, 0); XCTAssertEqual(result.1, "stopped\n")
            XCTAssertTrue(daemon.isRunning)
        }
        XCTAssertEqual(try client(["stop", "mac"]).1, "stopped\n")
        XCTAssertEqual(try client(["stop", "mac", "--force"]).1, "stopped\n")
        XCTAssertEqual(try client(["stop", "mac", "--force", "extra"]).0, 1)
        XCTAssertEqual(try client(["usb", "on", "mac"]).0, 1)
        XCTAssertEqual(try client(["start", "mac"]).0, 1)
        XCTAssertEqual(try client(["status", "mac"]).1, "stopped\n")
        XCTAssertEqual(try client(["status", "../escape"]).0, 1)
        XCTAssertEqual(try client(["ip", "mac"]).0, 1)
        let consoleResult = try client(["console", "mac"])
        XCTAssertEqual(consoleResult.0, 1)
        XCTAssertTrue(consoleResult.1.contains("not_running"))
        XCTAssertEqual(try client(["console", "mac", "extra"]).0, 1)
        XCTAssertTrue(daemon.isRunning)
        try Store.directory(try store.vm("dev"))
        XCTAssertEqual(symlink(dir.path, root.appendingPathComponent("vms/alias").path), 0)
        XCTAssertEqual(try client(["list"]).1, "NAME\tSTATE\ndev\tstopped\nmac\tstopped\n")
        XCTAssertEqual(try client(["list", "mac"]).0, 1)
        var booted = Configuration(name: "mac", cpuCount: 4, memorySize: 8_589_934_592, macAddress: "02:00:00:00:00:01", installed: true)
        booted.guestMajorVersion = 27; booted.firstBootAvailable = false
        try Store.write(JSONEncoder().encode(booted), to: dir.appendingPathComponent("config.json"))
        let provisionFD = try Wire.connect(store.socketPath)
        defer { close(provisionFD) }
        try Wire.send(Request(command: "provision", name: "mac", provisioning: Provisioning(username: "dev", fullName: "Developer", password: "test-only-secret")), to: provisionFD)
        let refusal = try Wire.receive(Reply.self, from: provisionFD)
        XCTAssertEqual(refusal.error?.code, "first_boot_required")
        XCTAssertFalse(String(decoding: try Store.read(dir.appendingPathComponent("config.json")), as: UTF8.self).contains("test-only-secret"))
        let second = Process(); second.executableURL = daemon.executableURL; second.environment = environment
        second.standardOutput = FileHandle.nullDevice; second.standardError = FileHandle.nullDevice
        try second.run(); second.waitUntilExit()
        XCTAssertNotEqual(second.terminationStatus, 0)
        let fd = try Wire.connect(store.socketPath); defer { close(fd) }
        try Wire.send(Request(command: "not-a-command", name: "mac"), to: fd)
        XCTAssertEqual(try Wire.receive(Reply.self, from: fd).error?.code, "invalid_command")
        var st = stat(); XCTAssertEqual(lstat(store.socketPath, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        daemon.terminate(); daemon.waitUntilExit()
        XCTAssertEqual(daemon.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.socketPath))
        // A crashed daemon leaves a socket/PID behind. The next client must
        // recover via the lock, auto-start a daemon, and survive client exit.
        let stale = try Wire.socket()
        try Wire.address(store.socketPath) { address, length in
            XCTAssertEqual(Darwin.bind(stale, address, length), 0)
        }
        close(stale)
        try Store.write(Data("999999\n".utf8), to: root.appendingPathComponent("daemon.pid"))
        XCTAssertEqual(try client(["status", "mac"]).1, "stopped\n")
        let pidText = String(decoding: try Store.read(root.appendingPathComponent("daemon.pid")), as: UTF8.self)
        let spawnedPID = try XCTUnwrap(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { _ = kill(spawnedPID, SIGTERM) }
        XCTAssertNotEqual(spawnedPID, 999999)
        XCTAssertEqual(try client(["status", "mac"]).1, "stopped\n")
        XCTAssertEqual(kill(spawnedPID, SIGTERM), 0)
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: store.socketPath) { break }
            usleep(20_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.socketPath))
    }

    /// Linux VMs need no guest image to exercise the EFI lifecycle: create, boot to firmware, stop.
    func testLinuxLifecycleWithoutGuestImage() throws {
        guard let bin = ProcessInfo.processInfo.environment["VMCTL_TEST_BIN"] else {
            throw XCTSkip("Set VMCTL_TEST_BIN to the signed bin directory for daemon integration tests.")
        }
        let root = URL(fileURLWithPath: "/tmp/vmctl-test-\(UUID().uuidString.prefix(8))")
        let store = try Store(root: root)
        var environment = ProcessInfo.processInfo.environment; environment["VMCTL_HOME"] = root.path
        let daemon = Process(); daemon.executableURL = URL(fileURLWithPath: bin).appendingPathComponent("vmctld")
        daemon.environment = environment; daemon.standardOutput = FileHandle.nullDevice; daemon.standardError = FileHandle.nullDevice
        try daemon.run()
        defer {
            if daemon.isRunning { daemon.terminate(); daemon.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
        var ready = false
        for _ in 0..<100 {
            if let fd = try? Wire.connect(store.socketPath) { close(fd); ready = true; break }
            if !daemon.isRunning { break }; usleep(50_000)
        }
        XCTAssertTrue(ready, "daemon did not start")
        func client(_ args: [String]) throws -> (Int32, String) {
            let process = Process(); process.executableURL = URL(fileURLWithPath: bin).appendingPathComponent("vmctl")
            process.arguments = args; process.environment = environment
            let output = Pipe(); process.standardOutput = output; process.standardError = output
            try process.run(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let key = CloudInitTests.key
        XCTAssertEqual(try client(["create", "lin"]).0, 1)
        XCTAssertEqual(try client(["create", "lin", "--linux", "--image"]).0, 1)
        XCTAssertEqual(try client(["create", "lin", "--linux", "--image", "relative.img"]).0, 1)
        let created = try client(["create", "lin", "--linux"])
        if created.1.contains("unsupported_host") { throw XCTSkip("Virtualization is unavailable in this environment.") }
        XCTAssertEqual(created.0, 0, created.1); XCTAssertEqual(created.1, "created\n")
        let dir = try store.existing("lin")
        for file in ["config.json", "machine-identifier", "efi-variable-store", "disk.img"] {
            XCTAssertNoThrow(try Store.check(dir.appendingPathComponent(file)), file)
        }
        var config = try JSONDecoder().decode(Configuration.self, from: Store.read(dir.appendingPathComponent("config.json")))
        XCTAssertTrue(config.isLinux); XCTAssertTrue(config.installed); XCTAssertEqual(config.firstBootAvailable, true)
        XCTAssertEqual(try client(["create", "lin", "--linux"]).0, 1) // never overwrite
        XCTAssertEqual(try client(["list"]).1, "NAME\tSTATE\nlin\tstopped\n")
        XCTAssertEqual(try client(["start", "lin", "--iso", "/nonexistent/installer.iso"]).0, 1)
        let wrongArch = root.appendingPathComponent("debian-13.7.0-amd64-netinst.iso")
        try Data(count: 4096).write(to: wrongArch)
        let rejected = try client(["start", "lin", "--iso", wrongArch.path])
        XCTAssertEqual(rejected.0, 1); XCTAssertTrue(rejected.1.contains("arm64"), rejected.1)
        XCTAssertEqual(try client(["create", "lin2", "--linux", "--image", wrongArch.path]).0, 1)
        XCTAssertEqual(try client(["start", "lin", "--ssh-key", key]).0, 1) // requires --user
        XCTAssertEqual(try client(["start", "lin", "--user", "dev", "--ssh-key", "ssh-ed25519 bogus"]).0, 1)
        XCTAssertEqual(try client(["start", "lin", "--user", "root", "--ssh-key", key]).0, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cloud-init.img").path))
        let iso = root.appendingPathComponent("installer.iso")
        try Data(count: 1 << 20).write(to: iso)
        let keyFile = root.appendingPathComponent("id.pub")
        try Data("# comment\n\n\(key)\n".utf8).write(to: keyFile)
        let started = try client(["start", "lin", "--iso", iso.path, "--user", "dev", "--full-name", "Developer", "--ssh-key", keyFile.path])
        XCTAssertEqual(started.0, 0, started.1); XCTAssertEqual(started.1, "running\n")
        XCTAssertNoThrow(try Store.check(dir.appendingPathComponent("cloud-init.img")))
        XCTAssertEqual(try client(["status", "lin"]).1, "running\n")
        XCTAssertEqual(try client(["start", "lin"]).1, "running\n")
        XCTAssertEqual(try client(["list"]).1, "NAME\tSTATE\nlin\trunning\n")
        XCTAssertEqual(try client(["stop", "lin", "--force"]).1, "stopped\n")
        XCTAssertEqual(try client(["status", "lin"]).1, "stopped\n")
        config = try JSONDecoder().decode(Configuration.self, from: Store.read(dir.appendingPathComponent("config.json")))
        XCTAssertEqual(config.firstBootAvailable, false)
        let retry = try client(["start", "lin", "--user", "dev", "--ssh-key", key])
        XCTAssertEqual(retry.0, 1); XCTAssertTrue(retry.1.contains("first_boot_required"), retry.1)
        XCTAssertEqual(try client(["start", "lin"]).1, "running\n") // plain boot from disk, no installer
        XCTAssertEqual(try client(["stop", "lin", "--force"]).1, "stopped\n")
        let logs = try client(["logs", "lin"]).1
        XCTAssertTrue(logs.contains("linux_vm_created") && logs.contains("starting_with_provisioning") && logs.contains("forced_shutdown"), logs)
        daemon.terminate(); daemon.waitUntilExit()
        XCTAssertEqual(daemon.terminationStatus, 0)
    }
}
