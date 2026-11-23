import XCTest
import Foundation
@testable import VMCore

final class GuestMountTests: XCTestCase {
    func testGuestPath() throws {
        XCTAssertEqual(try GuestMount.validate(guestPath: "/home/dev/src/insights"), "/home/dev/src/insights")
        XCTAssertEqual(try GuestMount.validate(guestPath: "/home//dev/proj_1.2-x/"), "/home/dev/proj_1.2-x")
        // Anything that would need quoting in a shell script, an exports line or a mount argument.
        for bad in ["", "home/dev", "/", "//", "/home/dev/../../etc", "/home/./dev", "/home/my project", "/home/dev'x", "/home/$(id)",
                    "/home/dev;reboot", "/home/dev\n/etc", "/home/dev(rw)", "/home/dév", "/home/*", "/" + String(repeating: "a", count: 1024)] {
            XCTAssertThrowsError(try GuestMount.validate(guestPath: bad), bad)
        }
    }

    func testExportScript() throws {
        let script = try GuestMount.exportScript(guestPath: "/home/dev/src/insights")
        // To the calling address only, every access as the account, from an unprivileged port.
        XCTAssertTrue(script.contains(#"printf '%s %s(rw,sync,no_subtree_check,all_squash,anonuid=%s,anongid=%s,insecure)\n' "$dir" "$client" "$uid" "$gid""#))
        XCTAssertTrue(script.contains("> '/etc/exports.d/vmctl-home-dev-src-insights.exports'"))
        XCTAssertTrue(script.contains("dir='/home/dev/src/insights'"))
        XCTAssertTrue(script.contains("exportfs -ra"))
        // An address that is not one is refused in the guest too, before it reaches the exports file.
        XCTAssertTrue(script.contains("*[!0-9a-fA-F.:]*"))
        XCTAssertThrowsError(try GuestMount.exportScript(guestPath: "/home/dev'; rm -rf /"))
        XCTAssertEqual(GuestMount.exportsFile(guestPath: "/srv/a"), "/etc/exports.d/vmctl-srv-a.exports")
        XCTAssertNotEqual(GuestMount.exportsFile(guestPath: "/srv/a"), GuestMount.exportsFile(guestPath: "/srv/b"))
        let undo = try GuestMount.unexportScript(guestPath: "/srv/a")
        XCTAssertTrue(undo.contains("rm -f '/etc/exports.d/vmctl-srv-a.exports'"))
        // The address and the ids come from the guest's own session, not from this Mac.
        XCTAssertEqual(GuestMount.remoteCommand, #"sudo -n sh -s -- "${SSH_CONNECTION%% *}" "$(id -u)" "$(id -g)""#)
    }

    /// The script is a POSIX shell script: it must at least parse, and refuse a bad address and a
    /// missing directory before it writes anything.
    func testExportScriptRunsUnderSh() throws {
        let script = try GuestMount.exportScript(guestPath: "/nonexistent/vmctl-test")
        func run(_ arguments: [String]) throws -> (Int32, String) {
            let sh = Process(), input = Pipe(), errors = Pipe()
            sh.executableURL = URL(fileURLWithPath: "/bin/sh")
            sh.arguments = ["-s", "--"] + arguments
            sh.standardInput = input; sh.standardOutput = FileHandle.nullDevice; sh.standardError = errors
            try sh.run()
            input.fileHandleForWriting.write(Data(script.utf8)); input.fileHandleForWriting.closeFile()
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            sh.waitUntilExit()
            return (sh.terminationStatus, text)
        }
        let missing = try run(["192.168.64.1", "1000", "1000"])
        XCTAssertEqual(missing.0, 3, missing.1)
        XCTAssertTrue(missing.1.contains("is not a directory in the guest"))
        // With a directory that exists, a bad client address stops it.
        let here = try GuestMount.exportScript(guestPath: "/tmp")
        let sh = Process(), input = Pipe()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh"); sh.arguments = ["-s", "--", "192.168.64.1(rw) *", "1000", "1000"]
        sh.standardInput = input; sh.standardOutput = FileHandle.nullDevice; sh.standardError = FileHandle.nullDevice
        try sh.run()
        input.fileHandleForWriting.write(Data(here.utf8)); input.fileHandleForWriting.closeFile()
        sh.waitUntilExit()
        XCTAssertEqual(sh.terminationStatus, 4)
    }

    func testMountArguments() throws {
        XCTAssertEqual(try GuestMount.mountArguments(address: "192.168.64.55", guestPath: "/home/dev/p", mountPoint: "/Users/me/vm/proj/p"),
                       ["-o", "vers=3,tcp,rw,noresvport,soft,intr,locallocks,nodev,nosuid", "192.168.64.55:/home/dev/p", "/Users/me/vm/proj/p"])
        XCTAssertEqual(try GuestMount.mountArguments(address: "fd00::5", guestPath: "/srv/a", mountPoint: "/m")[2], "[fd00::5]:/srv/a")
        XCTAssertThrowsError(try GuestMount.mountArguments(address: "proj.vm -o evil", guestPath: "/srv/a", mountPoint: "/m"))
        XCTAssertThrowsError(try GuestMount.mountArguments(address: "192.168.64.55", guestPath: "/srv/a b", mountPoint: "/m"))
        XCTAssertEqual(GuestMount.defaultMountPoint(home: "/Users/me", name: "proj", guestPath: "/home/dev/src/insights"), "/Users/me/vm/proj/insights")
    }

    func testMountPoint() throws {
        let home = "/Users/me", store = "/Users/me/.vmctl"
        for good in ["/Users/me/vm/proj/p", "/Users/me/eon/insights-vm", "/Volumes/work/p"] {
            XCTAssertNoThrow(try GuestMount.validate(mountPoint: good, home: home, store: store), good)
        }
        for bad in ["/", "/Users/me", "/Users/me/", "/Users/me/.vmctl", "/Users/me/.vmctl/vms/proj/x", "relative/p", "/Users/me/a\nb", "/Users/me/x/../../me"] {
            XCTAssertThrowsError(try GuestMount.validate(mountPoint: bad, home: home, store: store), bad)
        }
    }

    func testRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = try store.vm("proj"); try Store.directory(vm)
        XCTAssertEqual(try GuestMount.records(in: vm), [])

        let a = GuestMount.Record(guestPath: "/home/dev/a", mountPoint: "/Users/me/vm/proj/a")
        let b = GuestMount.Record(guestPath: "/home/dev/b", mountPoint: "/Users/me/vm/proj/b")
        var records = try GuestMount.adding(a, to: [])
        records = try GuestMount.adding(b, to: records)
        XCTAssertEqual(try GuestMount.adding(a, to: records), records, "the same mount again changes nothing")
        // One mount point, one guest directory.
        XCTAssertThrowsError(try GuestMount.adding(GuestMount.Record(guestPath: "/home/dev/c", mountPoint: a.mountPoint), to: records))

        try GuestMount.save(records, in: vm)
        XCTAssertEqual(try GuestMount.records(in: vm), [a, b])
        var info = stat()
        XCTAssertEqual(stat(vm.appendingPathComponent(GuestMount.recordsFile).path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        try GuestMount.save([], in: vm)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vm.appendingPathComponent(GuestMount.recordsFile).path))
        XCTAssertEqual(try GuestMount.records(in: vm), [])
    }
}
