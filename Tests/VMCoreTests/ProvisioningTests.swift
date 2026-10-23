import XCTest
import Foundation
@testable import VMCore

final class ProvisioningTests: XCTestCase {
    func testValidationAndWireRoundTrip() throws {
        let account = Provisioning(username: "dev", fullName: "Developer", password: "test-only-secret")
        try account.validate()
        let request = Request(command: "provision", name: "mac", provisioning: account)
        let decoded = try JSONDecoder().decode(Request.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.provisioning?.password, account.password)
        XCTAssertNil(decoded.provisioning?.sshPublicKey); XCTAssertNil(decoded.kind); XCTAssertNil(decoded.installer)
        for username in ["root", "../dev", "dev\n", "", "Dev", "a b"] {
            XCTAssertThrowsError(try Provisioning(username: username, fullName: "Developer", password: "secret").validate())
        }
        XCTAssertThrowsError(try Provisioning(username: "dev", fullName: "Developer", password: "").validate())
        XCTAssertThrowsError(try Provisioning(username: "dev", fullName: "Developer", password: String(repeating: "x", count: 257)).validate())
        XCTAssertThrowsError(try Provisioning(username: "dev", fullName: "a\nb", password: "secret").validate())
        XCTAssertThrowsError(try Provisioning(username: "dev", fullName: "Developer", password: nil, sshPublicKey: nil).validate())
        // Requests written before Linux support still decode.
        let legacy = Data(#"{"command":"provision","name":"mac","provisioning":{"username":"dev","fullName":"Developer","password":"secret"}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Request.self, from: legacy).provisioning?.username, "dev")
    }
    func testPublicKeyValidation() throws {
        let key = CloudInitTests.key
        try Provisioning(username: "dev", fullName: "Developer", password: nil, sshPublicKey: key).validate()
        try Provisioning.validatePublicKey("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJJZYARy5Bs72WqSK9IQguYtidDHjXbrMbD5wKnDSfBS")
        for bad in ["", "ssh-ed25519", "ssh-ed25519 notbase64!", "ssh-rsa AAAAC3NzaC1lZDI1NTE5AAAAIJJZYARy5Bs72WqSK9IQguYtidDHjXbrMbD5wKnDSfBS",
                    "ssh-dss AAAAB3NzaC1kc3MAAACBAJ", key + "\n", key + " one two", "-----BEGIN OPENSSH PRIVATE KEY-----"] {
            XCTAssertThrowsError(try Provisioning.validatePublicKey(bad), bad)
        }
    }
    func testFirstBootAndVersionGatesAndNoPersistedCredentials() throws {
        var saved = Configuration(name: "mac", cpuCount: 4, memorySize: 8_589_934_592, macAddress: "02:00:00:00:00:01", installed: true)
        XCTAssertThrowsError(try validateProvisioningEligibility(saved))
        saved.guestMajorVersion = 26; saved.firstBootAvailable = true
        XCTAssertThrowsError(try validateProvisioningEligibility(saved))
        saved.guestMajorVersion = 27
        XCTAssertNoThrow(try validateProvisioningEligibility(saved))
        saved.firstBootAvailable = false
        XCTAssertThrowsError(try validateProvisioningEligibility(saved))
        let data = try JSONEncoder().encode(saved)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["password"]); XCTAssertNil(json["provisioning"]); XCTAssertNil(json["kind"])
        var legacy = json; legacy.removeValue(forKey: "firstBootAvailable"); legacy.removeValue(forKey: "guestMajorVersion")
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(decoded.installed); XCTAssertFalse(decoded.isLinux)
        XCTAssertThrowsError(try validateProvisioningEligibility(decoded))
        // Linux guests need no guest version, only an unconsumed first boot.
        var linux = Configuration(name: "lin", cpuCount: 4, memorySize: 8_589_934_592, macAddress: "02:00:00:00:00:02", installed: true)
        linux.kind = "linux"
        XCTAssertThrowsError(try validateProvisioningEligibility(linux))
        linux.firstBootAvailable = true
        XCTAssertNoThrow(try validateProvisioningEligibility(linux))
        linux.installed = false
        XCTAssertThrowsError(try validateProvisioningEligibility(linux))
    }
}
