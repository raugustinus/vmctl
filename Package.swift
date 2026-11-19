// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "vmctl", platforms: [.macOS(.v13)], products: [
    .executable(name: "vmctl", targets: ["vmctl"]),
    .executable(name: "vmd", targets: ["vmd"])
], targets: [
    .target(name: "VMCore"),
    .executableTarget(name: "vmctl", dependencies: ["VMCore"]),
    .executableTarget(name: "vmd", dependencies: ["VMCore"], linkerSettings: [.linkedFramework("Virtualization"), .linkedFramework("AppKit"), .linkedFramework("Security")]),
    .testTarget(name: "VMCoreTests", dependencies: ["VMCore"])
])
