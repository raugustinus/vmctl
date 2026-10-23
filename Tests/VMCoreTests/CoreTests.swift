import XCTest
import Foundation
import Darwin
@testable import VMCore

final class CoreTests: XCTestCase {
    func testNameTraversalRejected() throws {
        for name in ["../mac", "/tmp/mac", "", ".", "mac/x", "Mac", "mac\n", String(repeating: "a", count: 33)] {
            XCTAssertThrowsError(try validateName(name), name)
        }
        for name in ["mac", "dev-2", String(repeating: "a", count: 32)] { XCTAssertNoThrow(try validateName(name)) }
    }
    func testPrivateStorageAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = try store.vm("mac"); try Store.directory(vm)
        let file = vm.appendingPathComponent("config.json")
        try Store.write(Data("{}".utf8), to: file)
        XCTAssertEqual(try Store.read(file), Data("{}".utf8))
        chmod(file.path, 0o644)
        XCTAssertThrowsError(try Store.read(file))
        chmod(file.path, 0o600)
        let alias = vm.appendingPathComponent("alias")
        XCTAssertEqual(symlink(file.path, alias.path), 0)
        XCTAssertThrowsError(try Store.read(alias))
        let hardlink = vm.appendingPathComponent("hardlink")
        XCTAssertEqual(link(file.path, hardlink.path), 0)
        XCTAssertThrowsError(try Store.read(file))
    }
    func testBoundedWireAndAuthentication() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { fds.forEach { close($0) } }
        try Wire.authenticate(fds[0])
        try Wire.send(Request(command: "status", name: "mac"), to: fds[0])
        let request = try Wire.receive(Request.self, from: fds[1])
        XCTAssertEqual(request.command, "status")
        try Wire.send(Reply(value: "running"), to: fds[1])
        XCTAssertEqual(try Wire.receive(Reply.self, from: fds[0]).value, "running")
        try Wire.send(Request(command: "status", name: "mac"), to: fds[0])
        XCTAssertThrowsError(try Wire.receive(Request.self, from: fds[1], limit: 4))
    }
    func testSocketPathLimit() {
        XCTAssertThrowsError(try Wire.address(String(repeating: "x", count: 200)) { _, _ in })
    }
}
