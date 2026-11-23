import Foundation
import Darwin
import VMCore

/// UDP listener for NameService on 127.0.0.1. Loopback only: guests reach it through a host
/// resolver (dnsmasq) that forwards the `vm` zone here, never directly.
final class NameServer {
    private let fd: Int32
    private let source: DispatchSourceRead

    /// Fails softly: VMs work without it, so vmd logs the reason and runs on.
    init?(port: UInt16 = NameService.port, lookup: @escaping (String) -> String?) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { Self.warn("socket"); return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { Self.warn("bind 127.0.0.1:\(port)"); close(fd); return nil }
        self.fd = fd
        // Main queue: lookup reads Supervisor state, which belongs to it.
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 1500)
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            while true {
                let count = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &peerLength) }
                }
                guard count > 0 else { return } // EAGAIN: drained
                guard let reply = NameService.response(to: Array(buffer[0..<count]), lookup: lookup) else { continue }
                _ = withUnsafePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, reply, reply.count, 0, $0, peerLength) }
                }
                peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            }
        }
        source.resume()
    }
    deinit { source.cancel(); close(fd) }

    private static func warn(_ operation: String) {
        fputs("vmd: .\(NameService.zone) name service disabled: \(operation): \(String(cString: strerror(errno)))\n", stderr)
    }
}
