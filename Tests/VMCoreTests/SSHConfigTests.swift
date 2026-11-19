import XCTest
import Foundation
@testable import VMCore

final class SSHConfigTests: XCTestCase {
    func entry(_ name: String, user: String = "dev", identity: String? = "/Users/me/.ssh/id_ed25519") -> SSHConfig.Entry {
        SSHConfig.Entry(name: name, user: user, identityFile: identity, knownHostsFile: "/Users/me/.vmctl/known_hosts/\(name)",
                        proxyCommand: try! SSHConfig.proxyCommand(name: name, vmctl: "/Users/me/.local/bin/vmctl", home: nil))
    }

    func testBlockRendering() throws {
        XCTAssertEqual(try SSHConfig.block(entry("proj")), """
        # BEGIN vmctl proj
        Host proj.vm
          User dev
          ProxyCommand sh -c 'nc "$("/Users/me/.local/bin/vmctl" ip proj)" 22'
          UserKnownHostsFile "/Users/me/.vmctl/known_hosts/proj"
          StrictHostKeyChecking yes
          ForwardAgent no
          IdentitiesOnly yes
          IdentityFile "/Users/me/.ssh/id_ed25519"
        # END vmctl proj
        """)
        XCTAssertFalse(try SSHConfig.block(entry("proj", identity: nil)).contains("IdentityFile"))
        XCTAssertEqual(try SSHConfig.proxyCommand(name: "a", vmctl: "/opt/vmctl", home: "/tmp/h"),
                       #"sh -c 'nc "$(VMCTL_HOME="/tmp/h" "/opt/vmctl" ip a)" 22'"#)
        // ssh expands %-tokens in file paths; quotes and newlines could break out of the line.
        XCTAssertTrue(try SSHConfig.block(entry("proj", identity: "/Users/me/100%/key")).contains(#"IdentityFile "/Users/me/100%%/key""#))
        XCTAssertThrowsError(try SSHConfig.block(entry("proj", identity: "/x\"y")))
        XCTAssertThrowsError(try SSHConfig.block(entry("proj", identity: "/x\nHost *")))
        XCTAssertThrowsError(try SSHConfig.block(entry("proj", user: "dev\nProxyCommand evil")))
        for bad in ["/it's/vmctl", "/a$(b)/vmctl", "/a`b`/vmctl", "/a\\b", "/50%/vmctl", "/a\nb"] {
            XCTAssertThrowsError(try SSHConfig.proxyCommand(name: "a", vmctl: bad, home: nil), bad)
        }
        XCTAssertThrowsError(try SSHConfig.proxyCommand(name: "../a", vmctl: "/opt/vmctl", home: nil))
        XCTAssertEqual(try SSHConfig.knownHostsLine(name: "proj", hostKey: CloudInitTests.key.split(separator: " ")[0...1].joined(separator: " ") + " root@proj\n"),
                       "proj.vm " + CloudInitTests.key.split(separator: " ")[0...1].joined(separator: " ") + "\n")
        XCTAssertThrowsError(try SSHConfig.knownHostsLine(name: "proj", hostKey: "ssh-ed25519 bogus"))
    }

    func testCreateReplaceRemoveKeepsUnrelatedText() throws {
        let a = try SSHConfig.block(entry("alpha")), b = try SSHConfig.block(entry("beta"))
        // Create: a header, then the block.
        var text = SSHConfig.updating("", name: "alpha", block: a)
        XCTAssertEqual(text, SSHConfig.header + "\n\n" + a + "\n")
        text = SSHConfig.updating(text, name: "beta", block: b)
        XCTAssertEqual(text, SSHConfig.header + "\n\n" + a + "\n\n" + b + "\n")
        // Unrelated text a user added, before, between and after the blocks, survives every update.
        let manual = "# my note\nHost other\n  User someone\n"
        text = manual + "\n" + a + "\n# between\n" + b + "\nHost tail\n  Port 2222\n"
        let a2 = try SSHConfig.block(entry("alpha", user: "ops"))
        let replaced = SSHConfig.updating(text, name: "alpha", block: a2)
        XCTAssertEqual(replaced, manual + "\n" + a2 + "\n# between\n" + b + "\nHost tail\n  Port 2222\n") // replaced in place
        XCTAssertEqual(SSHConfig.updating(replaced, name: "alpha", block: a2), replaced) // idempotent
        let removed = SSHConfig.updating(replaced, name: "alpha", block: nil)
        XCTAssertEqual(removed, manual + "\n" + "# between\n" + b + "\nHost tail\n  Port 2222\n")
        XCTAssertEqual(SSHConfig.updating(removed, name: "alpha", block: nil), removed) // removing a missing block is a no-op
        // A name that is a prefix of another (al / alpha) never matches the other's markers.
        let al = try SSHConfig.block(entry("al"))
        XCTAssertEqual(SSHConfig.updating(text, name: "al", block: nil), text)
        XCTAssertTrue(SSHConfig.updating(text, name: "al", block: al).contains(a))
        // Duplicate blocks collapse to one; a block missing its END marker stops at the next BEGIN.
        let duplicated = a + "\n" + a + "\n"
        XCTAssertEqual(SSHConfig.updating(duplicated, name: "alpha", block: a2), a2 + "\n")
        let truncated = "# BEGIN vmctl alpha\nHost alpha.vm\n  User dev\n" + b + "\n"
        XCTAssertEqual(SSHConfig.updating(truncated, name: "alpha", block: nil), b + "\n")
    }

    func testFilesArePrivateAndAtomic() throws {
        let root = URL(fileURLWithPath: "/tmp/vmctl-ssh-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)
        XCTAssertFalse(try store.updateSSHConfig(name: "alpha", block: nil)) // nothing to remove, nothing created
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sshConfig.path))
        XCTAssertTrue(try store.updateSSHConfig(name: "alpha", block: try SSHConfig.block(entry("alpha"))))
        XCTAssertFalse(try store.updateSSHConfig(name: "beta", block: try SSHConfig.block(entry("beta"))))
        try store.writeKnownHosts(name: "alpha", hostKey: CloudInitTests.key)
        for (url, mode) in [(store.sshConfig, 0o600), (try store.knownHosts("alpha"), 0o600), (store.knownHostsDirectory, 0o700), (root, 0o700)] {
            var info = stat(); XCTAssertEqual(lstat(url.path, &info), 0)
            XCTAssertEqual(Int(info.st_mode & 0o777), mode, url.path)
        }
        // No temporary files are left beside the targets.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.knownHostsDirectory.path), ["alpha"])
        // A symlinked ssh_config is refused rather than followed.
        try FileManager.default.removeItem(at: store.sshConfig)
        try FileManager.default.createSymbolicLink(atPath: store.sshConfig.path, withDestinationPath: "/tmp/elsewhere")
        XCTAssertThrowsError(try store.updateSSHConfig(name: "alpha", block: try SSHConfig.block(entry("alpha"))))
        try store.removeKnownHosts(name: "alpha"); try store.removeKnownHosts(name: "alpha") // missing is fine
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.knownHosts("alpha").path))
    }
}
