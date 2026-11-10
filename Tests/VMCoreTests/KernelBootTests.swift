import XCTest
import Foundation
@testable import VMCore

final class KernelBootTests: XCTestCase {
    /// The 64-byte arm64 Image header with only the magic set; the daemon reads nothing else.
    static func imageHeader() -> Data {
        var header = Data(count: KernelBoot.headerSize)
        header.replaceSubrange(56..<60, with: [0x41, 0x52, 0x4D, 0x64])
        return header
    }
    func testAcceptsUncompressedArm64Image() throws {
        XCTAssertNoThrow(try KernelBoot.validate(header: Self.imageHeader()))
    }
    func testRejectsCompressedAndForeignKernels() {
        var gzip = Self.imageHeader(); gzip[0] = 0x1F; gzip[1] = 0x8B
        var zboot = Self.imageHeader(); zboot.replaceSubrange(0..<8, with: [0x4D, 0x5A, 0, 0] + Array("zimg".utf8))
        for (header, hint) in [(gzip, "gunzip"), (zboot, "zboot"), (Data(count: 64), "ARM"), (Self.imageHeader().prefix(32), "ARM")] {
            XCTAssertThrowsError(try KernelBoot.validate(header: header)) { error in
                XCTAssertEqual((error as? Failure)?.code, "invalid_kernel")
                XCTAssertTrue((error as? Failure)?.message.contains(hint) == true, "\(error)")
            }
        }
    }
    func testCommandLine() {
        XCTAssertNoThrow(try KernelBoot.validate(commandLine: KernelBoot.defaultCommandLine))
        XCTAssertNoThrow(try KernelBoot.validate(commandLine: String(repeating: "a", count: 2047)))
        for bad in ["", "   ", "console=hvc0\nroot=/dev/vda", String(repeating: "a", count: 2048)] {
            XCTAssertThrowsError(try KernelBoot.validate(commandLine: bad))
        }
    }
    func testOlderConfigurationsStayEFI() throws {
        let old = #"{"version":1,"name":"lin","cpuCount":4,"memorySize":8589934592,"macAddress":"02:00:00:00:00:01","installed":true,"kind":"linux"}"#
        let config = try JSONDecoder().decode(Configuration.self, from: Data(old.utf8))
        XCTAssertTrue(config.isLinux); XCTAssertFalse(config.bootsKernel)
    }
}
